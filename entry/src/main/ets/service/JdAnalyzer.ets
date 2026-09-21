/**
 * 灯塔 Lighthouse · JD 岗位匹配分析
 * 目标路径：entry/src/main/ets/service/JdAnalyzer.ets
 * ------------------------------------------------------------------
 * 把一段招聘 JD 拆成「我差在哪、该怎么补」的可执行清单。
 *
 * 与 ReviewAnalyzer 保持同一套契约（这个产品对 AI 的统一承诺）：
 *   analyze() **一定返回结果**，不抛异常、不因断网或没配 key 就什么都不给。
 *   三条路径都会如实标注来源（云端模型 / 本地关键词引擎），绝不把本地初判
 *   说成是模型的结论。
 *
 * ⚠ 一个前置依赖容易被忽略：prompt 里写死了「底牌里没提到的技能，一律记缺失，
 *   不要假设用户会」。所以 profile 为空时，结果会**全是"缺失"**，用户会以为分析错了。
 *   因此这里提供 defaultProfile() —— 宁可给一份可编辑的示例起步，也不要空白底牌。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AiConfig, AiErrorKind, AiResult, ChatMessage, JdAnalysis, JdSkillItem } from '../common/AiTypes';
import { DeepSeekClient } from './DeepSeekClient';
import { PromptLibrary } from './PromptLibrary';
import { KvRepo } from '../repository/KvRepo';
import { Log } from '../common/Logger';

/** 一次 JD 分析的完整交代：结果 + 来源 + 失败原因，UI 全部要展示 */
export interface JdOutcome {
  analysis: JdAnalysis;
  /** true = 云端模型结论；false = 本地关键词引擎 */
  fromCloud: boolean;
  /** 引擎展示名，直接给用户看 */
  engine: string;
  errorKind: AiErrorKind;
  errorMsg: string;
  latencyMs: number;
  tokens: number;
}

/** 落库用的信封：只存"再打开时需要复述的事实"，不存一次性的失败原因 */
interface JdStored {
  analysis: JdAnalysis;
  fromCloud: boolean;
  engine: string;
  latencyMs: number;
  tokens: number;
  analyzedAt: number;
}

/** 本地引擎的一条技能词条：JD 里命中任一别名就算这条被要求 */
interface SkillKeyword {
  name: string;
  aliases: string[];
}

/**
 * Java 后端岗位的高频技能词表。
 * 只用于**本地降级**：云端可用时不会走到这里，所以它不需要多全，
 * 够在没有网络时给出一个"大致差在哪"就够了。
 */
const SKILL_KEYWORDS: SkillKeyword[] = [
  { name: 'Java 基础与并发', aliases: ['java', 'juc', '多线程', '并发', '线程池', '集合', '反射', '泛型', 'io流'] },
  { name: 'JVM 与性能调优', aliases: ['jvm', 'gc', '垃圾回收', '调优', '内存模型', 'oom'] },
  { name: '数据库与 MySQL', aliases: ['mysql', 'sql', '数据库', '索引', '事务', '分库分表', '慢查询'] },
  { name: 'Redis 与缓存', aliases: ['redis', '缓存', '分布式锁', '缓存穿透', '缓存雪崩'] },
  { name: 'Spring 生态', aliases: ['spring', 'springboot', 'spring boot', 'spring cloud', 'ioc', 'aop'] },
  { name: '持久层框架', aliases: ['mybatis', 'mybatis-plus', 'jpa', 'hibernate'] },
  { name: '微服务与 RPC', aliases: ['微服务', 'dubbo', 'grpc', '服务治理', '注册中心', 'nacos', 'feign'] },
  { name: '消息队列', aliases: ['消息队列', 'kafka', 'rocketmq', 'rabbitmq', 'mq'] },
  { name: '计算机网络', aliases: ['tcp', 'http', 'https', '网络协议', 'socket', 'netty'] },
  { name: '操作系统与 Linux', aliases: ['操作系统', 'linux', 'shell', '进程', '内存管理'] },
  { name: '数据结构与算法', aliases: ['算法', '数据结构', 'leetcode', '刷题'] },
  { name: '分布式与高可用', aliases: ['分布式', '高可用', '高并发', '限流', '熔断', '容灾'] },
  { name: '容器与部署', aliases: ['docker', 'kubernetes', 'k8s', '容器', 'ci/cd', 'jenkins'] },
  { name: '工程协作', aliases: ['git', '敏捷', '代码review', '单元测试', 'junit'] }
];

export class JdAnalyzer {
  static readonly ENGINE_LOCAL: string = '本地关键词引擎';

  /* ======================== 技能底牌（偏好库） ======================== */

  /**
   * 默认底牌：一段**具体到能判断**的示例，而不是空串。
   *
   * 为什么给示例而不是留空：prompt 规定"底牌里没提到的技能一律记缺失"，
   * 空底牌会让每一条都判成缺失，用户第一次用就会觉得分析不准。
   * 给一份带强项也带弱项的示例，用户改两个字就能用。
   */
  static defaultProfile(): string {
    return '熟悉 Java 基础、集合与多线程，能写常用的 JUC 工具；\n'
      + '校园项目里用 Spring Boot + MyBatis 做过一个二手交易平台，负责后端接口与 MySQL 表设计；\n'
      + '用过 Redis 做缓存，了解索引与事务的基本原理；\n'
      + '刷过 200 道 LeetCode，计算机网络与操作系统有系统复习；\n'
      + '薄弱：分布式与消息队列只停留在概念层面，JVM 调优没实际做过，没有容器化部署经验。';
  }

  static async loadProfile(ctx: common.Context): Promise<string> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(ctx, AiConfig.STORE_NAME);
      const raw: preferences.ValueType = await store.get(AiConfig.PREF_SKILL_PROFILE, '');
      if (typeof raw === 'string' && raw.trim().length > 0) {
        return raw;
      }
    } catch (e) {
      Log.w('读取技能底牌失败，用默认底牌顶上');
    }
    return JdAnalyzer.defaultProfile();
  }

  static async saveProfile(ctx: common.Context, text: string): Promise<void> {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, AiConfig.STORE_NAME);
    await store.put(AiConfig.PREF_SKILL_PROFILE, text);
    await store.flush();
  }

  /* ====================== 结果持久化（键值表） ====================== */

  /**
   * 结果要落库，不能只活在页面的 @State 里。
   *
   * 为什么：一次分析要 3-5 秒 + 一千多个 token，而这份结论（缺什么、补什么）
   * 是用户接下来几天要反复回来看的。不落库的话，切个 Tab 回来就空了 ——
   * 用户要么重跑一遍白烧 token，要么以为功能坏了。
   * 演示时更尴尬：评委说"再打开看一眼"，结果没了。
   *
   * 用 KvRepo 而不是新开一张表：这是"一条投递 ↔ 一份结论"的单值映射，
   * 键值表刚好，不必为它加列并做 schema 迁移。
   */
  private static resultKey(appId: number): string {
    return `jd_result_${appId}`;
  }

  static async saveResult(appId: number, out: JdOutcome): Promise<void> {
    if (appId <= 0) {
      return;
    }
    const stored: JdStored = {
      analysis: out.analysis,
      fromCloud: out.fromCloud,
      engine: out.engine,
      latencyMs: out.latencyMs,
      tokens: out.tokens,
      analyzedAt: Date.now()
    };
    try {
      await KvRepo.put(JdAnalyzer.resultKey(appId), JSON.stringify(stored));
      Log.i(`JD 结果已存 id=${appId} 项数=${out.analysis.items.length}`);
    } catch (e) {
      const err: Error = e as Error;
      Log.w(`JD 结果落库失败（不影响本次展示）：${err.message}`);
    }
  }

  /** 读回上一次的结论。读不到或格式坏了都返回 undefined，不抛。 */
  static async loadResult(appId: number): Promise<JdOutcome | undefined> {
    if (appId <= 0) {
      return undefined;
    }
    try {
      const raw: string | undefined = await KvRepo.get(JdAnalyzer.resultKey(appId));
      if (raw === undefined || raw.length === 0) {
        return undefined;
      }
      const stored: JdStored = JSON.parse(raw) as JdStored;
      if (stored === undefined || stored.analysis === undefined) {
        return undefined;
      }
      const out: JdOutcome = {
        analysis: stored.analysis,
        fromCloud: stored.fromCloud === true,
        engine: stored.engine !== undefined ? stored.engine : '',
        // 当时为什么降级，对"现在这一屏"没有意义了，不再复述 —— 只保留来源标注
        errorKind: AiErrorKind.NONE,
        errorMsg: '',
        latencyMs: stored.latencyMs !== undefined ? stored.latencyMs : 0,
        tokens: stored.tokens !== undefined ? stored.tokens : 0
      };
      return out;
    } catch (e) {
      Log.w('JD 结果读取失败，按"没有历史结论"处理');
      return undefined;
    }
  }

  /** 这条投递被删掉时顺手清掉结论，避免键值表里留孤儿数据 */
  static async clearResult(appId: number): Promise<void> {
    if (appId <= 0) {
      return;
    }
    try {
      await KvRepo.del(JdAnalyzer.resultKey(appId));
    } catch (e) {
      Log.w('JD 结果清理失败（可忽略）');
    }
  }

  /* ============================== 主入口 ============================== */

  /**
   * 主入口。**保证有返回值**，调用方不需要 try/catch。
   */
  static async analyze(jdText: string, profile: string): Promise<JdOutcome> {
    const client: DeepSeekClient = DeepSeekClient.get();
    const jd: string = jdText.trim();

    if (jd.length < 30) {
      // 太短的输入不该发请求：模型只会编，而且用户多半是粘错了
      const short: JdOutcome = {
        analysis: JdAnalyzer.tooShort(),
        fromCloud: false,
        engine: JdAnalyzer.ENGINE_LOCAL,
        errorKind: AiErrorKind.NONE,
        errorMsg: '',
        latencyMs: 0,
        tokens: 0
      };
      return short;
    }

    if (client.isCloudEnabled()) {
      const messages: ChatMessage[] = PromptLibrary.jdGapAnalysis(jd, profile);
      Log.i(`开始云端 JD 分析，JD ${jd.length} 字 / 底牌 ${profile.length} 字`);
      const r: AiResult<JdAnalysis> = await client.chatJson<JdAnalysis>(messages, 2500);

      if (r.ok && r.data !== undefined) {
        const normalized: JdAnalysis = JdAnalyzer.normalize(r.data);
        Log.i(`云端 JD 分析完成 用时${r.latencyMs}ms 匹配度${normalized.gapScore}`);
        const ok: JdOutcome = {
          analysis: normalized,
          fromCloud: true,
          engine: '云端模型 deepseek-flash',
          errorKind: AiErrorKind.NONE,
          errorMsg: '',
          latencyMs: r.latencyMs !== undefined ? r.latencyMs : 0,
          tokens: r.usage !== undefined ? r.usage.total_tokens : 0
        };
        return ok;
      }

      const why: string = r.error !== undefined ? r.error : '未知原因';
      Log.w(`云端 JD 分析失败（${r.errorKind}：${why}），降级到本地引擎`);
      const fallback: JdOutcome = JdAnalyzer.local(jd, profile);
      fallback.errorKind = r.errorKind;
      fallback.errorMsg = why;
      fallback.latencyMs = r.latencyMs !== undefined ? r.latencyMs : 0;
      return fallback;
    }

    const reason: string = client.isCloudAllowed()
      ? '未配置 API Key，去「我的 → AI 设置」填入即可启用云端分析'
      : '你已关闭云端 AI，全程本地运算';
    Log.i('云端不可用：' + reason);
    const local: JdOutcome = JdAnalyzer.local(jd, profile);
    local.errorKind = client.isCloudAllowed() ? AiErrorKind.NO_KEY : AiErrorKind.OFFLINE;
    local.errorMsg = reason;
    return local;
  }

  /* ============================ 本地兜底 ============================ */

  /**
   * 本地引擎：JD 里出现了哪些技能词 × 底牌里有没有 → 具备/缺失。
   *
   * 它能给的诚实结论只有「差在哪些技能」。**判断不了哪条是"必须"哪条是"加分"**
   * ——那要靠读懂句子，所以 level 一律标「未区分」，而不是硬猜一个假装结构完整。
   * 追问预测同样给不出，留空并由 UI 说明原因，不编。
   */
  private static local(jdText: string, profile: string): JdOutcome {
    const started: number = Date.now();
    const jd: string = jdText.toLowerCase();
    const me: string = profile.toLowerCase();

    const items: JdSkillItem[] = [];
    let owned: number = 0;
    for (let i: number = 0; i < SKILL_KEYWORDS.length; i++) {
      const kw: SkillKeyword = SKILL_KEYWORDS[i];
      if (!JdAnalyzer.hitAny(jd, kw.aliases)) {
        continue;
      }
      const has: boolean = JdAnalyzer.hitAny(me, kw.aliases);
      if (has) {
        owned++;
      }
      items.push({
        skill: kw.name,
        level: '未区分',
        myStatus: has ? '具备' : '缺失',
        note: has ? '底牌里提到过' : '底牌里没有提到，按缺失计'
      });
    }

    const total: number = items.length;
    const score: number = total === 0 ? 0 : Math.round(owned * 100 / total);

    const missing: string[] = [];
    for (let i: number = 0; i < items.length && missing.length < 5; i++) {
      if (items[i].myStatus !== '具备') {
        missing.push(items[i].skill);
      }
    }
    const plan: string[] = [];
    for (let i: number = 0; i < missing.length; i++) {
      plan.push(`复习「${missing[i]}」：先整理高频面试题，再补一个能讲清楚的小例子`);
    }
    if (plan.length === 0 && total > 0) {
      plan.push('JD 要求的技能底牌里都有，重点转向把项目经历讲成能追问三层的版本');
    }

    const verdict: string = total === 0
      ? '这段 JD 里没识别到常见技术词（本地引擎只认关键词，不读语义），建议开启云端 AI 重试。'
      : `识别到 ${total} 项技能要求，其中 ${owned} 项底牌里有。`;

    const analysis: JdAnalysis = {
      jobTitle: '（本地引擎不提取岗位名）',
      items: items,
      gapScore: score,
      interviewFocus: [],
      prepPlan: plan
    };
    Log.i(`本地 JD 分析完成：${verdict}`);

    const out: JdOutcome = {
      analysis: analysis,
      fromCloud: false,
      engine: JdAnalyzer.ENGINE_LOCAL,
      errorKind: AiErrorKind.NONE,
      errorMsg: '',
      latencyMs: Date.now() - started,
      tokens: 0
    };
    return out;
  }

  private static hitAny(haystack: string, needles: string[]): boolean {
    for (let i: number = 0; i < needles.length; i++) {
      if (haystack.includes(needles[i])) {
        return true;
      }
    }
    return false;
  }

  private static tooShort(): JdAnalysis {
    const empty: JdAnalysis = {
      jobTitle: '',
      items: [],
      gapScore: 0,
      interviewFocus: [],
      prepPlan: []
    };
    return empty;
  }

  /**
   * 把云端返回的结果收拢到可渲染的形状。
   *
   * 三个必须挡住的脏数据（模型偶尔会给）：
   *   ① gapScore 越界或不是数字 → 夹到 0-100，否则环形进度会画到框外
   *   ② items 里缺 skill → 丢掉那一条，否则清单里出现空白行
   *   ③ myStatus 是别的词 → 归到「部分」，比归到「具备」保守（宁可让用户多看一眼）
   */
  private static normalize(raw: JdAnalysis): JdAnalysis {
    const items: JdSkillItem[] = [];
    const src: JdSkillItem[] = raw.items !== undefined ? raw.items : [];
    for (let i: number = 0; i < src.length; i++) {
      const it: JdSkillItem = src[i];
      const name: string = it.skill !== undefined ? `${it.skill}`.trim() : '';
      if (name.length === 0) {
        continue;
      }
      let status: string = it.myStatus !== undefined ? `${it.myStatus}`.trim() : '';
      if (status !== '具备' && status !== '部分' && status !== '缺失') {
        status = '部分';
      }
      let level: string = it.level !== undefined ? `${it.level}`.trim() : '';
      if (level !== '必须' && level !== '加分') {
        level = '必须';
      }
      items.push({
        skill: name,
        level: level,
        myStatus: status,
        note: it.note !== undefined ? `${it.note}` : ''
      });
    }

    let score: number = typeof raw.gapScore === 'number' ? raw.gapScore : 0;
    if (!Number.isFinite(score)) {
      score = 0;
    }
    score = Math.max(0, Math.min(100, Math.round(score)));

    const focus: string[] = JdAnalyzer.cleanList(raw.interviewFocus);
    const plan: string[] = JdAnalyzer.cleanList(raw.prepPlan);

    const out: JdAnalysis = {
      jobTitle: raw.jobTitle !== undefined ? `${raw.jobTitle}` : '',
      items: items,
      gapScore: score,
      interviewFocus: focus,
      prepPlan: plan
    };
    return out;
  }

  /** 字符串数组清洗：去空、去重、限长 */
  private static cleanList(raw: string[] | undefined): string[] {
    const out: string[] = [];
    if (raw === undefined) {
      return out;
    }
    for (let i: number = 0; i < raw.length && out.length < 8; i++) {
      const s: string = raw[i] !== undefined ? `${raw[i]}`.trim() : '';
      if (s.length > 0 && !out.includes(s)) {
        out.push(s);
      }
    }
    return out;
  }
}
