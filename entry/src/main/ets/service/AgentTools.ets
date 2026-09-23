/**
 * 灯塔 Lighthouse · 端侧智能体的「工具箱」
 * 目标路径：entry/src/main/ets/service/AgentTools.ets
 * ------------------------------------------------------------------
 * 智能体不是聊天机器人，差别就在这一层：**它真的能动你的数据**。
 *
 * 为什么工具要单独封装，而不是让模型直接写查询：
 *   ① **安全边界**：模型只能从固定清单里挑工具、填参数，拿不到任意读写能力。
 *      这跟"让模型在你的库上跑 SQL"是两回事 —— 后者一旦被诱导就没救。
 *   ② **可解释**：每次调用都有 ToolResult（工具名 + 看到了什么），
 *      UI 上原样展示就是"这一结论是怎么来的"，评委也能一眼看懂闭环。
 *   ③ **离线可用**：工具本身不联网，所以**断网时整条链路照跑**，
 *      出问题的只可能是"说得不够漂亮"，不会变成"什么都做不了"。
 *
 * 一条铁律：任何工具在拿不到数据时必须明确返回 ok=false + "查不到"，
 * **绝不允许为了凑答案编造事实**。下游的汇总模板会把这个结论原样转述给用户。
 */

import { common } from '@kit.AbilityKit';
import { Application, EventNode, ReviewRecord, getStatusMeta, getEventTypeMeta } from '../common/Types';
import { JdAnalysis, JdSkillItem, RadarDimension, RadarEnvelope, parseRadarEnvelope } from '../common/AiTypes';
import { ApplicationRepo } from '../repository/ApplicationRepo';
import { EventRepo } from '../repository/EventRepo';
import { ReviewRepo } from '../repository/ReviewRepo';
import { JdAnalyzer, JdOutcome } from './JdAnalyzer';
import { countdownText, dayDiff, fmtDateTime, fmtSalary, humanDeadline } from '../common/Utils';
import { Log } from '../common/Logger';

/** 单次工具调用的结果 */
export class ToolResult {
  tool: string = '';
  /** 一行摘要，UI 上作为"工具轨迹"直接显示 */
  label: string = '';
  ok: boolean = true;
  /** 给模型看的事实块（UI 的"依据"也用它） */
  fact: string = '';
  lines: string[] = [];

  constructor(tool: string) {
    this.tool = tool;
  }

  static miss(tool: string, why: string): ToolResult {
    const r: ToolResult = new ToolResult(tool);
    r.ok = false;
    r.label = why;
    r.fact = why;
    return r;
  }
}

export interface AgentTool {
  name: string;
  /** 给模型看的用途说明（会出现在系统提示里） */
  desc: string;
  /** 参数说明，逗号分隔；空串表示无需参数 */
  args: string;
  run: (a: Record<string, string>) => Promise<ToolResult>;
}

/* ================================ 小工具 ================================ */

/** 取参数并去空白，缺失返回空串 */
function arg(a: Record<string, string>, key: string): string {
  const v: string | undefined = a[key];
  if (v === undefined) {
    return '';
  }
  return v.trim();
}

/** 从列表里挑出包含关键词的公司名 —— 用于把「网上考拉怎么还不回」里的公司名捞出来 */
function matchCompany(question: string, companies: string[]): string {
  for (let i: number = 0; i < companies.length; i++) {
    const c: string = companies[i];
    if (c.length > 1 && question.indexOf(c) >= 0) {
      return c;
    }
  }
  return '';
}

/* --------------------- 猜「问的是哪家公司」 --------------------- */

/** 这些东西后面跟「的」时，说的不是公司名 */
const NOT_A_COMPANY: string[] = [
  '我', '你', '他', '她', '它', '我们', '你们', '他们', '大家', '自己',
  '这', '那', '哪', '什么', '现在', '最近', '今天', '明天', '后天', '昨天',
  '这个', '那个', '公司', '岗位', '职位', '上面', '底下', '接下来'
];

/** 词里只要带上这些字，就是在讲"我的哪份数据"，不是在点公司名 */
const DATA_WORDS: string[] = ['投递', '简历', '面试', '笔试', '记录', '状态', '进展',
  '情况', '节点', '安排', '复盘', '雷达', '能力', '岗位', '薪资', '流程'];

/** 这些结尾几乎一定是方位/处所（「库里」不是公司） */
const PLACE_TAIL: string = '里上中下边面间头前后外内';

/**
 * 不能打头的功能字。
 *
 * ⚠ 没有它会把动词一起吞进来：「有没有华为的消息」贪婪往前吃得到「有没有华为」。
 *   实测 16 条用例里就这一条翻车。
 *   注意**只在开头削**、且削到剩 2 字就停 —— 削完还不够 2 字说明本来就是虚词。
 */
const FUNC_HEAD: string = '有没不是在想要会能去来给看问说知请帮让就还又也都只才再很太更最挺';

/** 并列连词。「美团和饿了么的进度」贪婪会吃成整段，按这些切一刀 */
const JOIN_WORD: string = '和与跟及、,，';

/** 公司名常见的尾巴，猜出来的词带着它可以剥掉再试 */
const CO_SUFFIX: string[] = ['有限公司', '股份', '集团', '科技', '软件', '网络',
  '信息', '电子', '数据', '研究院', '事务所', '公司'];

function isHan(ch: string): boolean {
  const c: number = ch.charCodeAt(0);
  return c >= 0x4E00 && c <= 0x9FFF;
}

/**
 * 从问句里猜一个「像公司名」的词。
 *
 * ★ 为什么非要猜：用户问「腾讯的面试是什么时候」，如果本地认不出公司名就当作"没提公司"，
 *   助手会把**所有**节点热情地列一遍 —— 数据全是真的，但答非所问，
 *   看起来比编造还蠢。而"查不到就直说查不到"恰恰是这个助手最值钱的性格。
 *   工具层本来就写好了 `库里没有「X」的投递记录` 这条如实回答，
 *   缺的只是有人把「X」认出来递进去。
 *
 * ⚠ 规则的取舍是**宁可漏，不可错**：
 *   - 只认紧跟在「的」前面的词（「腾讯的面试」）—— 中文里点公司名最常见的句式；
 *     其它说法（「腾讯投了吗」）一律当"没提公司"，退回通用回答，**不硬猜**；
 *   - 代词、时间词、以及讲数据的名词全部排除，尤其挡掉以「里/上/下…」结尾的；
 *   - 猜错了的代价也只是多一句「库里没有「XX」的记录」，不会污染任何事实。
 */
function suspectCompany(question: string): string {
  const hits: string[] = [];
  for (let i: number = 0; i < question.length; i++) {
    if (question.charAt(i) !== '的') {
      continue;
    }
    // 从「的」往前吃连续汉字，得到候选人
    let j: number = i - 1;
    while (j >= 0 && isHan(question.charAt(j))) {
      j = j - 1;
    }
    let token: string = question.substring(j + 1, i);
    // 并列提了两家（「美团和饿了么的进度」）时，取离「的」最近的那家 —— 问句的宾语通常是它
    let last: string = '';
    const parts: string[] = [];
    for (let p: number = 0; p < token.length; p++) {
      const ch: string = token.charAt(p);
      if (JOIN_WORD.indexOf(ch) >= 0) {
        parts.push(last);
        last = '';
      } else {
        last = `${last}${ch}`;
      }
    }
    parts.push(last);
    if (parts.length > 1 && last.length >= 2) {
      token = last;
    }
    // 先削掉开头的功能字：「有没有华为」→「华为」。削到剩 2 字就停。
    while (token.length > 2 && FUNC_HEAD.indexOf(token.charAt(0)) >= 0) {
      token = token.substring(1);
    }
    // 公司名常见的尾巴剥一层：「腾讯公司」→「腾讯」
    for (let k: number = 0; k < CO_SUFFIX.length; k++) {
      const sfx: string = CO_SUFFIX[k];
      if (token.length > sfx.length && token.endsWith(sfx)) {
        token = token.substring(0, token.length - sfx.length);
        break;
      }
    }
    if (token.length < 2 || token.length > 8) {
      continue;
    }
    if (NOT_A_COMPANY.indexOf(token) >= 0) {
      continue;
    }
    let generic: boolean = false;
    for (let k: number = 0; k < DATA_WORDS.length; k++) {
      if (token.indexOf(DATA_WORDS[k]) >= 0) {
        generic = true;
        break;
      }
    }
    if (generic) {
      continue;
    }
    if (PLACE_TAIL.indexOf(token.charAt(token.length - 1)) >= 0) {
      continue;
    }
    if ('我你他她它这那哪'.indexOf(token.charAt(0)) >= 0) {
      continue;
    }
    if (FUNC_HEAD.indexOf(token.charAt(0)) >= 0) {
      continue;
    }
    hits.push(token);
  }

  if (hits.length === 0) {
    return '';
  }
  // 取最长的；同长取最靠后的（离问句的宾语最近）
  let best: string = hits[0];
  for (let i: number = 0; i < hits.length; i++) {
    if (hits[i].length >= best.length) {
      best = hits[i];
    }
  }
  return best;
}

async function allCompanies(): Promise<string[]> {
  const list: Application[] = await ApplicationRepo.listAll();
  const out: string[] = [];
  for (let i: number = 0; i < list.length; i++) {
    out.push(list[i].company);
  }
  return out;
}

/** 把投递记录压成一行 */
function appLine(app: Application): string {
  const meta = getStatusMeta(app.status);
  const salary: string = fmtSalary(app.salaryMin, app.salaryMax);
  const city: string = app.city.length > 0 ? ` · ${app.city}` : '';
  return `${app.company} · ${app.position} · ${meta.label}${city} · ${salary}`;
}

/* ================================ 工具实现 ================================ */

/**
 * 工具一：查投递库。
 *
 * 支持按公司名、状态过滤。state 参数可以用中文（"笔试"），也可以是英文 key（written），
 * 因为**本地规则规划器和云端的说法可能不一样**，这里两边都收。
 */
async function toolAppsQuery(a: Record<string, string>): Promise<ToolResult> {
  const company: string = arg(a, 'company');
  const status: string = arg(a, 'status');
  const list: Application[] = await ApplicationRepo.listAll();

  const picked: Application[] = [];
  for (let i: number = 0; i < list.length; i++) {
    const app: Application = list[i];
    if (company.length > 0 && app.company.indexOf(company) < 0 && company.indexOf(app.company) < 0) {
      continue;
    }
    if (status.length > 0) {
      const key: string = statusOf(status);
      if (key.length > 0 && app.status !== key) {
        continue;
      }
    }
    picked.push(app);
  }

  const r: ToolResult = new ToolResult('apps_query');
  if (picked.length === 0) {
    return ToolResult.miss('apps_query',
      company.length > 0 ? `库里没有「${company}」的投递记录` : '库里还没有投递记录');
  }
  for (let i: number = 0; i < picked.length; i++) {
    r.lines.push(appLine(picked[i]));
  }
  r.label = `查投递库 · ${picked.length} 条`;
  r.fact = r.lines.join('\n');
  return r;
}

/** 「笔试」「面试中」「已投递」→ 状态 key；识别不了返回空串（表示不过滤） */
function statusOf(word: string): string {
  const w: string = word.toLowerCase();
  const table: string[][] = [
    ['wish', '想投'], ['applied', '已投递', '投递'], ['screen', '沟通', '筛选', 'hr'],
    ['written', '笔试', '在线笔试'], ['interview', '面试', '一面', '二面', '三面'],
    ['offer', 'offer', '意向'], ['rejected', '结束', '挂了', '感谢信', '淘汰'],
    ['withdrawn', '放弃', '不想去']
  ];
  for (let i: number = 0; i < table.length; i++) {
    for (let j: number = 1; j < table[i].length; j++) {
      if (w.indexOf(table[i][j]) >= 0 || w === table[i][0]) {
        return table[i][0];
      }
    }
  }
  return '';
}

/** 工具二：查待办节点 */
async function toolEventsQuery(a: Record<string, string>): Promise<ToolResult> {
  const company: string = arg(a, 'company');
  const limit: number = arg(a, 'limit').length > 0 ? Number(arg(a, 'limit')) : 10;
  const raw: EventNode[] = await EventRepo.upcoming(30);

  const apps: Application[] = await ApplicationRepo.listAll();
  const companyOf: Record<string, string> = {};
  for (let i: number = 0; i < apps.length; i++) {
    companyOf[`${apps[i].id}`] = apps[i].company;
  }

  const r: ToolResult = new ToolResult('events_query');
  let n: number = 0;
  for (let i: number = 0; i < raw.length && n < limit; i++) {
    const e: EventNode = raw[i];
    const who: string = companyOf[`${e.appId}`] === undefined ? '' : companyOf[`${e.appId}`];
    if (company.length > 0 && who.indexOf(company) < 0 && company.indexOf(who) < 0) {
      continue;
    }
    const meta = getEventTypeMeta(e.type);
    r.lines.push(`${who} ${e.title} · ${meta.label} · ${humanDeadline(e.happenAt)}`);
    n = n + 1;
  }

  if (r.lines.length === 0) {
    return ToolResult.miss('events_query',
      company.length > 0 ? `「${company}」没有待办节点` : '接下来没有待办节点');
  }
  r.label = `查节点日历 · ${r.lines.length} 个`;
  r.fact = r.lines.join('\n');
  return r;
}

/** 工具三：下一个节点 —— 「最近要准备什么」的标准答案 */
async function toolNextNode(): Promise<ToolResult> {
  const list: EventNode[] = await EventRepo.upcoming(1);
  const r: ToolResult = new ToolResult('next_node');
  if (list.length === 0) {
    return ToolResult.miss('next_node', '接下来没有待办节点');
  }
  const e: EventNode = list[0];
  const app: Application | undefined = await ApplicationRepo.getById(e.appId);
  const who: string = app === undefined ? '' : app.company;
  const meta = getEventTypeMeta(e.type);
  const now: number = Date.now();
  r.lines.push(`${who} ${e.title}`);
  r.lines.push(`类型：${meta.label}`);
  r.lines.push(`时间：${fmtDateTime(e.happenAt)}（${humanDeadline(e.happenAt)}）`);
  r.lines.push(`倒计时：${countdownText(e.happenAt, now)}`);
  if (app !== undefined && app.position.length > 0) {
    r.lines.push(`岗位：${app.position}`);
  }
  r.label = '推算下一个节点';
  r.fact = r.lines.join('\n');
  return r;
}

/** 工具四：复盘与能力雷达的汇总 —— 「我哪方面最弱」走的这里 */
async function toolReviewSummary(): Promise<ToolResult> {
  const list: ReviewRecord[] = await ReviewRepo.listAll();
  const r: ToolResult = new ToolResult('review_summary');
  if (list.length === 0) {
    return ToolResult.miss('review_summary', '还没有面试复盘记录');
  }

  // 六维累加，算平均分。⚠ 维度数量不固定：模型可能漏项，所以按 RadardDef 的 key 对齐，
  // 缺的维度不计入该场（而不是当成 0 分拉低）—— 否则"没考到"会被算成"考了 0 分"。
  const sum: Record<string, number> = {};
  const cnt: Record<string, number> = {};
  let analyzed: number = 0;
  let total: number = 0;

  for (let i: number = 0; i < list.length; i++) {
    const env: RadarEnvelope | undefined = parseRadarEnvelope(list[i].radarJson);
    if (env === undefined) {
      continue;
    }
    analyzed = analyzed + 1;
    const dims: RadarDimension[] = env.analysis.dimensions;
    for (let j: number = 0; j < dims.length; j++) {
      const d: RadarDimension = dims[j];
      const s: number = sum[d.key] === undefined ? 0 : sum[d.key];
      const c: number = cnt[d.key] === undefined ? 0 : cnt[d.key];
      sum[d.key] = s + d.score;
      cnt[d.key] = c + 1;
      total = total + d.score;
    }
  }

  if (analyzed === 0) {
    r.label = `复盘 ${list.length} 场，还没有做过能力分析`;
    r.fact = `已有 ${list.length} 场复盘记录，但都还没有生成能力雷达。`;
    r.lines.push(`复盘场次：${list.length}`);
    // ⚠ 这里原来写死了一句「尚未分析：0 场暂无雷达」—— 不管有几场都印 0，
    //   而且"0 场暂无雷达"读起来是病句。用户看到的每一行都是要进演示的视频里的，别糊弄。
    r.lines.push('已生成能力雷达：0 场（去「复盘」页跑一次分析就能出六维图）');
    r.ok = true;
    return r;
  }

  const rows: string[][] = [];
  let worstKey: string = '';
  let worstScore: number = 101;
  let bestKey: string = '';
  let bestScore: number = -1;
  const it: string[] = Object.keys(cnt);
  for (let i: number = 0; i < it.length; i++) {
    const k: string = it[i];
    const avg: number = Math.round(sum[k] / cnt[k]);
    rows.push([k, `${avg}`]);
    if (avg < worstScore) {
      worstScore = avg;
      worstKey = k;
    }
    if (avg > bestScore) {
      bestScore = avg;
      bestKey = k;
    }
  }
  // 按分数从低到高排，弱项在最前 —— 用户要的就是"先补哪一块"
  rows.sort((x: string[], y: string[]): number => Number(x[1]) - Number(y[1]));

  let dimCount: number = 0;
  for (let i: number = 0; i < it.length; i++) {
    dimCount = dimCount + cnt[it[i]];
  }
  const avgAll: number = dimCount > 0 ? Math.round(total / dimCount) : 0;
  r.label = `能力分析 · ${analyzed} 场 / 均分 ${avgAll}`;
  for (let i: number = 0; i < rows.length; i++) {
    r.lines.push(`${labelOfDim(rows[i][0])} ${rows[i][1]} 分`);
  }
  r.lines.unshift(`复盘 ${list.length} 场，已分析 ${analyzed} 场，能力均分 ${avgAll}`);
  r.fact = r.lines.join('\n');
  // 弱项单独塞进 fact 末尾，模型总结时会自然说到它
  if (worstKey.length > 0) {
    r.fact += `\n最弱的一维：${labelOfDim(worstKey)} ${worstScore} 分；最强的一维：${labelOfDim(bestKey)} ${bestScore} 分。`;
  }
  return r;
}

function labelOfDim(key: string): string {
  // 优先用 tool 侧自己的中文名（和 prompt 维度表一致），不在表里就原样返回 key
  const names: Record<string, string> = {
    'java_core': 'Java 基础与并发',
    'database': '数据库与 MySQL',
    'framework': '框架 Spring/MyBatis',
    'cs_basic': '计算机基础',
    'algo': '算法与数据结构',
    'project': '项目表达与追问'
  };
  const v: string | undefined = names[key];
  return v === undefined ? key : v;
}

/**
 * 工具五：JD 匹配分析。
 *
 * ⚠ 优先读**库里已存的分析结果**（JdAnalyzer.loadResult），没有才现算 ——
 *   每次提问都重算一遍既慢又费 token，而且同一份 JD 的两次结论可能不一样，
 *   用户会怀疑"你说的话到底算不算数"。
 */
async function toolJdMatch(a: Record<string, string>): Promise<ToolResult> {
  let company: string = arg(a, 'company');
  const r: ToolResult = new ToolResult('jd_match');

  const apps: Application[] = await ApplicationRepo.listAll();
  let target: Application | undefined;
  for (let i: number = 0; i < apps.length; i++) {
    if (company.length === 0) {
      // 没点名公司时取最近一条有 JD 的 —— 「我适不适合这个岗」通常指最新的那个
      if (apps[i].jdText.length > 20) {
        target = apps[i];
      }
      continue;
    }
    if (apps[i].company.indexOf(company) >= 0 || company.indexOf(apps[i].company) >= 0) {
      target = apps[i];
      break;
    }
  }

  if (target === undefined) {
    return ToolResult.miss('jd_match', company.length > 0
      ? `库里没有「${company}」这条投递`
      : '库里还没有带 JD 的投递记录');
  }
  company = target.company;

  if (target.jdText.trim().length < 30) {
    return ToolResult.miss('jd_match', `「${company}」这条没有录入 JD 原文，没法做技能差距分析`);
  }

  const ctx: common.Context | undefined = TOOL_CTX;
  if (ctx === undefined) {
    // 不太可能发生（UI 打开时就绑过），但真出现了要说清楚原因，而不是在栈里崩一下
    return ToolResult.miss('jd_match', 'JD 分析缺少应用上下文');
  }
  let out: JdOutcome | undefined = await JdAnalyzer.loadResult(target.id);
  if (out === undefined) {
    const profile: string = await JdAnalyzer.loadProfile(ctx);
    out = await JdAnalyzer.analyze(target.jdText, profile);
  }

  const an: JdAnalysis = out.analysis;
  r.lines.push(`${company} · ${target.position}：匹配度 ${an.gapScore} 分（${out.engine}）`);
  const miss: string[] = [];
  const partial: string[] = [];
  for (let i: number = 0; i < an.items.length; i++) {
    const it: JdSkillItem = an.items[i];
    if (it.myStatus === '缺失') {
      miss.push(it.skill);
    } else if (it.myStatus === '部分') {
      partial.push(it.skill);
    }
  }
  if (miss.length > 0) {
    r.lines.push(`尚未覆盖：${miss.join('、')}`);
  }
  if (partial.length > 0) {
    r.lines.push(`只沾到边：${partial.join('、')}`);
  }
  if (an.interviewFocus.length > 0) {
    r.lines.push(`大概率会追问：${an.interviewFocus.slice(0, 3).join('、')}`);
  }
  r.label = `JD 匹配分析 · ${company} ${an.gapScore} 分`;
  r.fact = r.lines.join('\n');
  return r;
}

/**
 * 工具六：倒计时推算 —— 「离 XX 还有多久」。
 *
 * 看起来和 events_query 重复，但用途不同：那个是"列清单"，这个是"算一个数"。
 * 差值是度 LocalDateTime 出来的真值，不是模型估的。
 */
async function toolCountdown(a: Record<string, string>): Promise<ToolResult> {
  const company: string = arg(a, 'company');
  const list: EventNode[] = await EventRepo.upcoming(30);
  const r: ToolResult = new ToolResult('countdown');

  let hit: EventNode | undefined;
  for (let i: number = 0; i < list.length; i++) {
    if (company.length === 0) {
      hit = list[i];
      break;
    }
    const app: Application | undefined = await ApplicationRepo.getById(list[i].appId);
    if (app !== undefined && (app.company.indexOf(company) >= 0 || company.indexOf(app.company) >= 0)) {
      hit = list[i];
      break;
    }
  }

  if (hit === undefined) {
    return ToolResult.miss('countdown', company.length > 0
      ? `没有查到「${company}」的待办节点`
      : '没有待办节点，算不出倒计时');
  }
  const e: EventNode = hit;
  const app: Application | undefined = await ApplicationRepo.getById(e.appId);
  const who: string = app === undefined ? '' : app.company;
  const now: number = Date.now();
  r.lines.push(`${who} ${e.title}：${fmtDateTime(e.happenAt)}`);
  r.lines.push(`距今 ${countdownText(e.happenAt, now)}（自然日差 ${dayDiff(e.happenAt, now)} 天）`);
  r.label = '推算倒计时';
  r.fact = r.lines.join('\n');
  return r;
}

/**
 * 工具层需要 AbilityContext（JD 分析要读偏好库）。
 *
 * ⚠ 不用 @State 传进来：工具是在后台被调用的，UI 可能已经重建了好几轮，
 *   而 context 是进程级的 —— 由调用方在.run 之前塞一次即可。
 */
let TOOL_CTX: common.Context | undefined = undefined;

export function setAgentContext(ctx: common.Context): void {
  TOOL_CTX = ctx;
}

function appCtx(): common.Context | undefined {
  return TOOL_CTX;
}

/* ================================ 注册表 ================================ */

export class AgentTools {
  static all(): AgentTool[] {
    return [
      { name: 'apps_query', desc: '查投递库：有哪些公司、什么岗位、现在什么状态',
        args: 'company（可选，公司名）, status（可选，状态）', run: toolAppsQuery },
      { name: 'events_query', desc: '查关键节点日历：笔试/面试/投递截止都在什么时候',
        args: 'company（可选）, limit（可选，默认 10）', run: toolEventsQuery },
      { name: 'next_node', desc: '推算下一个即将到来的节点，精确到分钟',
        args: '', run: (): Promise<ToolResult> => toolNextNode() },
      { name: 'review_summary', desc: '汇总面试复盘与六维能力雷达：均分、最弱项、最强项',
        args: '', run: (): Promise<ToolResult> => toolReviewSummary() },
      { name: 'jd_match', desc: '把 JD 和我的技能底牌做差距分析：匹配度、缺失技能、预测追问',
        args: 'company（可选，不填取最近一条有 JD 的）', run: toolJdMatch },
      { name: 'countdown', desc: '算某个节点还剩多少时间',
        args: 'company（可选）', run: toolCountdown }
    ];
  }

  /**
   * 执行工具。
   *
   * ⚠ 只对白名单放行，并且**吞掉所有异常转成 miss** ——
   *   一个工具炸了不该让整条回答挂掉（用户看到的应该是"这部分没查到"，
   *   而不是一大段看不懂的错误）。
   */
  static async invoke(name: string, args: Record<string, string>): Promise<ToolResult> {
    const list: AgentTool[] = AgentTools.all();
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].name !== name) {
        continue;
      }
      try {
        return await list[i].run(args);
      } catch (e) {
        const err: Error = e as Error;
        Log.e(`AgentTools.${name} 执行异常：${err.message}`);
        return ToolResult.miss(name, `${name} 执行失败：${err.message}`);
      }
    }
    Log.w(`AgentTools 收到未注册的工具请求：${name}`);
    return ToolResult.miss(name, `没有名为 ${name} 的工具`);
  }

  /** 把问题里提到的公司名捞出来（本地规则规划器要用） */
  /**
   * 问句里提到了哪家公司。
   *
   * 两段式，顺序不能反：
   *   ① 先拿库里的公司名去匹配 —— 用户问的真是自己投过的，就用这个（最准）；
   *   ② 库里没有，再猜一个「像公司名」的词。猜出来的名字会一路传到工具里，
   *      工具查不到就如实回 `库里没有「腾讯」的投递记录`。
   *
   * ⚠ ② 是关键：没有它，用户问「腾讯的面试是什么时候」会被当成"没提公司"，
   *   助手就把**自己所有**的节点列一遍 —— 数据全真，但答非所问。
   */
  static async mentionedCompany(question: string): Promise<string> {
    const known: string = matchCompany(question, await allCompanies());
    if (known.length > 0) {
      return known;
    }
    return suspectCompany(question);
  }
}
