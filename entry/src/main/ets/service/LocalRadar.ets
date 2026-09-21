/**
 * 灯塔 Lighthouse · 本地雷达引擎（离线兜底）
 * 目标路径：entry/src/main/ets/service/LocalRadar.ets
 * ------------------------------------------------------------------
 * 存在的理由：答辩现场的网络是不可控的。如果 WiFi 挂了、评委问「断网能用吗」、
 * 或者 API 余额被耗尽，雷达图**不能空着**。这个引擎让产品在任何情况下都有输出。
 *
 * ⚠ 诚实声明（这一点会在 UI 上如实告诉用户，也是答辩的加分点）：
 *   本引擎是**关键词启发式**，不是语义理解。它只能回答「这场面试聊到了哪些维度、
 *   聊得顺不顺」，无法像云端模型那样做归因（例如「你答不上间隙锁，是因为
 *   对 RR 隔离级别的理解停留在定义层面」）。
 *   所以它的分数更保守、evidence 更机械。UI 上必须标注来源，不能让用户误以为是 AI 结论。
 *
 * 设计约束：输出的六维结构必须与云端结果**完全一致**（同 key、同顺序、同字段），
 * 这样雷达图绘制和「云端/本地对比」逻辑可以完全复用。
 */

import { RadarDef, RadarDimension, ReviewAnalysis } from '../common/AiTypes';

interface DimRule {
  key: string;
  /** 命中即认为这场面试「聊到了」这个维度 */
  words: string[];
  /** 该维度没聊到时的补强建议 */
  advice: string;
}

/** 维度关键词表。词都小写，匹配前会把原文也转小写 */
const RULES: DimRule[] = [
  {
    key: 'java_core',
    words: ['java', '并发', '多线程', '线程池', '线程', 'jvm', 'gc', '垃圾回收', '集合',
            'hashmap', 'concurrenthashmap', '锁', 'synchronized', 'volatile', 'aqs', 'cas',
            '内存模型', '反射', '泛型', 'string', '字符串', '异常', 'gc 调优'],
    advice: '按 JVM → 并发 → 集合 的顺序过一遍，重点是 synchronized 锁升级与 AQS 的等待队列'
  },
  {
    key: 'database',
    words: ['mysql', '数据库', 'sql', '索引', '事务', '隔离级别', 'mvcc', 'innodb', 'b+树',
            'b+ 树', '慢查询', 'explain', '执行计划', '主从', '分库', '分表', 'redis',
            '缓存', '行锁', '表锁', '间隙锁', '死锁', '回表', '最左前缀'],
    advice: '围绕「一条慢 SQL 的完整排查链路」串知识点：执行计划 → 索引选择 → 锁与隔离级别'
  },
  {
    key: 'framework',
    words: ['spring', 'springboot', 'spring boot', 'mybatis', 'aop', 'ioc', 'bean',
            'mvc', '拦截器', '过滤器', '事务传播', '依赖注入', 'starter', 'springcloud',
            'spring cloud', '自动装配', '循环依赖', '三级缓存'],
    advice: '主攻 Spring 事务失效场景与循环依赖的三级缓存，这两块是应届生追问重灾区'
  },
  {
    key: 'cs_basic',
    words: ['网络', 'tcp', 'http', 'https', 'udp', '三次握手', '四次挥手', 'dns',
            '操作系统', '进程', '虚拟内存', '页面置换', '死锁', '调度', 'linux',
            '内存管理', 'io 模型', 'io多路复用', 'epoll', 'select'],
    advice: '把 TCP 三次握手 / 四次挥手 + HTTP 与 HTTPS 的差异讲成一条线，别背散点'
  },
  {
    key: 'algo',
    words: ['算法', '手写', '手撕', '代码题', '编程题', '笔试题', 'leetcode', '链表',
            '二叉树', '树', '动态规划', 'dp', '排序', '快排', '二分', '哈希', '栈',
            '队列', '时间复杂度', '空间复杂度', '递归', '回溯', '贪心'],
    advice: '固定刷「高频 100」并按题型归类；面试手写要能边写边说复杂度'
  },
  {
    key: 'project',
    words: ['项目', '简历', '实习', '负责', '架构', '优化过', '重构', '难点', '亮点',
            '长盈通', '编码规则', '多租户', '压力测试', '压测', '上线', '部署',
            '团队', '分工', '为什么这么做'],
    advice: '把项目讲成「问题 → 我的方案 → 量化结果」三段，并预演三层追问'
  }
];

/** 负向信号：答不上来 / 卡住 */
const NEG_WORDS: string[] = [
  '不会', '不知道', '没答上来', '答不上', '卡住', '忘了', '想不起来', '没学过',
  '没做过', '不了解', '不熟', '说错了', '答错', '含糊', '蒙', '瞎猜', '跳过',
  '不太清楚', '说不清楚', '没讲清楚', '不满意', '答得一塌糊涂'
];

/** 正向信号：答得下来 / 有实例 */
const POS_WORDS: string[] = [
  '答上来了', '答出来了', '比较熟', '很熟', '熟练', '掌握', '清楚', '了解一些',
  '做过', '用过', '写过', '实现过', '复现', '优化过', '独立负责', '自己做的',
  '项目里', '实习中', '举了个例子', '延伸',
  // 以下几条是实测补的：原回忆里「这题还行」「我说了…」「写出来了」明明是好信号，
  // 缺了它们会让整份复盘的分数被负面词压平，雷达退化成正六边形。
  '还行', '比较顺', '答得还行', '说清楚了', '写出来了', '自己写的', '独立完成', '答得不错'
];

export class LocalRadar {
  static readonly ENGINE_NAME: string = '本地引擎';

  /** 入口：把一段口语化回忆转成六维结构 */
  static analyze(narration: string): ReviewAnalysis {
    const lower: string = narration.toLowerCase();
    const sentences: string[] = LocalRadar.splitSentences(lower);

    const dims: RadarDimension[] = [];
    for (let i: number = 0; i < RULES.length; i++) {
      dims.push(LocalRadar.judge(RULES[i], sentences));
    }

    // 最弱项 = 已涉及但得分最低的；若一个都没涉及，就提示「本次信息不足」
    let weakest: RadarDimension | undefined = undefined;
    for (let i: number = 0; i < dims.length; i++) {
      const d: RadarDimension = dims[i];
      if (d.score <= 0) {
        continue;
      }
      if (weakest === undefined || d.score < weakest.score) {
        weakest = d;
      }
    }

    const actions: string[] = LocalRadar.buildActions(dims);

    const summary: string = weakest !== undefined
      ? `本次共涉及 ${LocalRadar.coveredCount(dims)} 个维度，最薄弱的是「${weakest.label}」`
      : '回忆里没有出现可识别的技术维度，建议把面试问题记得更具体些';

    const analysis: ReviewAnalysis = {
      summary: summary,
      dimensions: dims,
      topWeakness: weakest !== undefined ? weakest.label : '信息不足，无法定位',
      nextActions: actions
    };
    return analysis;
  }

  /* ---------------- 内部 ---------------- */

  private static coveredCount(dims: RadarDimension[]): number {
    let n: number = 0;
    for (let i: number = 0; i < dims.length; i++) {
      if (dims[i].score > 0) {
        n++;
      }
    }
    return n;
  }

  /** 按中文标点与换行切句。切不开也没关系，整段当一句处理。 */
  private static splitSentences(text: string): string[] {
    const out: string[] = [];
    let buf: string = '';
    for (let i: number = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      if (ch === '。' || ch === '！' || ch === '？' || ch === '；'
        || ch === '\n' || ch === '!' || ch === '?' || ch === ';' || ch === '.') {
        if (buf.trim().length > 0) {
          out.push(buf.trim());
        }
        buf = '';
      } else {
        buf = buf + ch;
      }
    }
    if (buf.trim().length > 0) {
      out.push(buf.trim());
    }
    return out;
  }

  private static hitCount(sentence: string, words: string[]): number {
    let n: number = 0;
    for (let i: number = 0; i < words.length; i++) {
      if (sentence.indexOf(words[i]) >= 0) {
        n++;
      }
    }
    return n;
  }

  private static anyHit(sentence: string, words: string[]): boolean {
    for (let i: number = 0; i < words.length; i++) {
      if (sentence.indexOf(words[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 单维度判分。规则刻意保守 —— 本地引擎宁可打低也不虚高，
   * 因为「虚高的分数」比「没有分数」更误导人。
   */
  private static judge(rule: DimRule, sentences: string[]): RadarDimension {
    const hits: string[] = [];
    const hitIdx: number[] = [];
    let wordHits: number = 0;

    for (let i: number = 0; i < sentences.length; i++) {
      const s: string = sentences[i];
      const n: number = LocalRadar.hitCount(s, rule.words);
      if (n > 0) {
        hits.push(s);
        hitIdx.push(i);
        wordHits = wordHits + n;
      }
    }

    if (hits.length === 0) {
      const absent: RadarDimension = {
        key: rule.key,
        label: RadarDef.labelOf(rule.key),
        score: 0,
        evidence: '本次面试未涉及',
        advice: rule.advice
      };
      return absent;
    }

    // 情绪信号分「自身」和「邻域」两级，这是实测调出来的：
    //   · 只看自身句 —— 「…我答了复制算法的效率考虑；但 CMS 和 G1 的区别没答上来」
    //     分号把否定切到下一句，算法维度会虚高到 58（实测数据）。
    //   · 前后各扩一句 —— 负面词密度一高就扩散到全部维度，
    //     六个维度齐刷刷 32 分，雷达退化成正六边形，等于没用（也实测过）。
    //   · 所以取中间：自身否定最重，邻句否定只降一档。
    let selfNeg: boolean = false;
    let selfPos: boolean = false;
    for (let k: number = 0; k < hits.length; k++) {
      // 顺序要紧：含「不太清楚」的句子也含「清楚」，
      // 必须先判否定，否则同一句会被算成正向。
      if (LocalRadar.anyHit(hits[k], NEG_WORDS)) {
        selfNeg = true;
      } else if (LocalRadar.anyHit(hits[k], POS_WORDS)) {
        selfPos = true;
      }
    }

    let nearNeg: boolean = false;
    let nearPos: boolean = false;
    if (!selfNeg && !selfPos) {
      for (let k: number = 0; k < hitIdx.length; k++) {
        const i: number = hitIdx[k];
        const lo: number = i > 0 ? i - 1 : 0;
        const hi: number = i < sentences.length - 1 ? i + 1 : i;
        for (let j: number = lo; j <= hi; j++) {
          if (j === i) {
            continue;
          }
          if (LocalRadar.anyHit(sentences[j], NEG_WORDS)) {
            nearNeg = true;
          } else if (LocalRadar.anyHit(sentences[j], POS_WORDS)) {
            nearPos = true;
          }
        }
      }
    }

    let score: number = 58;               // 提到了，但看不出深浅
    if (selfPos) {
      score = 74;                          // 明确答上来了
    } else if (selfNeg) {
      score = 32;                          // 这一项当场卡住
    } else if (nearNeg) {
      score = 46;                          // 附近有卡壳，但不确定是不是这一项
    } else if (nearPos) {
      score = 66;
    }
    // 同一个维度被反复聊到，说明确实展开过，给一点加成
    if (!selfNeg && wordHits >= 3 && score < 95) {
      score = score + 5;
    }

    // 证据句尽量取信息量最大的那条（命中词最多）
    let best: string = hits[0];
    let bestN: number = LocalRadar.hitCount(hits[0], rule.words);
    for (let i: number = 1; i < hits.length; i++) {
      const n: number = LocalRadar.hitCount(hits[i], rule.words);
      if (n > bestN) {
        best = hits[i];
        bestN = n;
      }
    }
    let evidence: string = best;
    if (evidence.length > 46) {
      evidence = evidence.substring(0, 46) + '…';
    }

    const dim: RadarDimension = {
      key: rule.key,
      label: RadarDef.labelOf(rule.key),
      score: score,
      evidence: evidence,
      advice: selfNeg ? '这一项被追问时卡住了，' + rule.advice : rule.advice
    };
    return dim;
  }

  /** 取最弱的 3 个已涉及维度，各给一条动作 */
  private static buildActions(dims: RadarDimension[]): string[] {
    const involved: RadarDimension[] = [];
    for (let i: number = 0; i < dims.length; i++) {
      if (dims[i].score > 0) {
        involved.push(dims[i]);
      }
    }
    // 简单插入排序，数据量只有 6，不值得引入更多复杂度
    for (let i: number = 1; i < involved.length; i++) {
      const cur: RadarDimension = involved[i];
      let j: number = i - 1;
      while (j >= 0 && involved[j].score > cur.score) {
        involved[j + 1] = involved[j];
        j--;
      }
      involved[j + 1] = cur;
    }

    const out: string[] = [];
    const take: number = involved.length < 3 ? involved.length : 3;
    for (let i: number = 0; i < take; i++) {
      out.push(involved[i].advice);
    }
    if (out.length === 0) {
      out.push('先在复盘里写清被问了哪些技术点，本地引擎才能给出维度判断');
    }
    return out;
  }
}
