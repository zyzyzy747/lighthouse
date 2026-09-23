/**
 * 灯塔 Lighthouse · 意图解析与任务规划
 * 目标路径：entry/src/main/ets/service/AgentPlanner.ets
 * ------------------------------------------------------------------
 * 智能体的"脑"。它把一句人话换成一串**工具调用计划**：
 *
 *      「下一个节点是什么，我该怎么准备」
 *        → [{ next_node }, { review_summary }]
 *
 * 两条路，**顺序很重要**：
 *
 *   ① 本地规则（永远可用，零延迟，离线）
 *   ② 云端模型（本地没命中，且用户允许联网时才走）
 *
 * ⚠ 为什么不是"默认上云"：这是一个求职工具，用户在地铁、在图书馆、在没网的教室里
 *   都会拿出来用。**"联网才能用"的智能体在关键时刻是废物**。本地表跑通 90% 的常规问法，
 *   云端去收拾那 10% 没见过的问法 —— 这才是端優先（on-device first）该有的样子。
 *   而且这一层永远在线，真出问题也只是"说得不够漂亮"，不会变成"什么都说不出来"。
 *
 * ⚠ 而"来回倒手"的成本也要算清楚：云端规划 = 一次网络请求 + 一次 JSON 解析，
 *   失败要能落回本地。所以它只能是锦上添花，绝不能是必经之路。
 */

import { AgentTool, AgentTools } from './AgentTools';
import { AiResult, ChatMessage } from '../common/AiTypes';
import { DeepSeekClient } from './DeepSeekClient';
import { Log } from '../common/Logger';

/** 一个待执行的工具调用 */
export class AgentPlan {
  tool: string = '';
  args: Record<string, string> = {};
  /** 为什么要调它 —— UI 上要能看懂这一步的动机 */
  why: string = '';
}

/** 规划结果：带上来源，UI 据此标注 */
export class AgentPlanResult {
  plans: AgentPlan[] = [];
  /** local = 本地规则命中；cloud = 云端模型规划 */
  source: string = 'local';
  /** 命中/使用了哪条规则或模型结论的简短说明 */
  note: string = '';
}

/** 云端规划的一步 */
interface CloudStep {
  tool: string;
  args: Record<string, string>;
  why: string;
}

/** 云端规划的输出契约（模型只被允许输出这个形状） */
interface CloudPlan {
  // ⚠ `Array<{...}>` 这种"对象字面量当类型"在 ArkTS 里直接编译不过（arkts-no-obj-literals-as-types），
  //   必须先把成员定义成具名 interface。
  steps: CloudStep[];
}

export class AgentPlanner {
  /* ============================ ① 本地规则 ============================ */

  /**
   * 本地规划：关键词打分 + 公司名抽取。
   *
   * 用"打分"而不是"匹配第一条"：一句提问常常同时符合多条规则
   * （"我下个节点是不是快到了，顺便看看我哪方面最弱"），
   * 取第一条会漏掉用户的后半句 —— 而那后半句往往才是他真正在意的。
   */
  static async local(question: string): Promise<AgentPlanResult> {
    const q: string = question.toLowerCase();
    const res: AgentPlanResult = new AgentPlanResult();
    const scored: ScoredRule[] = [];

    for (let i: number = 0; i < LOCAL_RULES.length; i++) {
      const rule: RuleDef = LOCAL_RULES[i];
      let hit: number = 0;
      for (let j: number = 0; j < rule.words.length; j++) {
        if (q.indexOf(rule.words[j]) >= 0) {
          hit = hit + 1;
        }
      }
      if (hit > 0) {
        scored.push(new ScoredRule(hit, rule));
      }
    }

    if (scored.length === 0) {
      res.plans = [];
      res.source = 'local';
      res.note = '本地规则没有命中';
      return res;
    }

    // 命中得多的排前面；同分保持规则表顺序（更具体的规则写在前面）
    scored.sort((a: ScoredRule, b: ScoredRule): number => b.hit - a.hit);
    const company: string = await AgentTools.mentionedCompany(question);

    // ⚠ 一次最多 3 步：再多既拖慢响应，也让界面上的「工具轨迹」长到没人愿意看。
    const maxSteps: number = scored.length > 3 ? 3 : scored.length;
    const plans: AgentPlan[] = [];
    for (let i: number = 0; i < maxSteps; i++) {
      const p: AgentPlan = new AgentPlan();
      p.tool = scored[i].rule.tool;
      p.why = scored[i].rule.why;
      if (company.length > 0) {
        p.args = { 'company': company };
      }
      plans.push(p);
    }

    res.plans = plans;
    res.source = 'local';
    res.note = `命中 ${scored.length} 条规则，取前 ${maxSteps} 条`;
    Log.i(`AgentPlanner 本地规划：${res.note} → ${names(plans)}`);
    return res;
  }

  /* ============================ ② 云端规划 ============================ */

  /**
   * 本地没命中时的兜底：让模型挑工具。
   *
   * ⚠ 三条约束缺一不可：
   *   ① 只把工具清单给它，不给它的输出留自由度 —— 必须输 JSON，且只能填工具名；
   *   ② 拿回来要做**白名单校验**（AgentTools.invoke 里那道），模型说错工具名也只是无效一笔，
   *      不会变成任意函数调用；
   *   ③ 失败、超时、没网 → 一律返回空，**由上层决定是否降级到"我不知道"**。
   *      宁可说"这句我没听懂"，也不能编一串工具出来假装在查。
   */
  static async cloud(question: string): Promise<AgentPlanResult> {
    const res: AgentPlanResult = new AgentPlanResult();
    const client: DeepSeekClient = DeepSeekClient.get();
    if (!client.isCloudEnabled()) {
      res.note = '云端不可用';
      return res;
    }

    const msgs: ChatMessage[] = AgentPlanner.planMessages(question);
    const r: AiResult<string> = await client.chatRaw(msgs, 400, 0.2);
    if (!r.ok) {
      res.note = `云端规划失败：${r.error === undefined ? '未知原因' : r.error}`;
      Log.w(`AgentPlanner 云端规划失败：${res.note}`);
      return res;
    }

    const raw: string = r.raw === undefined ? '' : r.raw;
    const parsed: CloudPlan | undefined = AgentPlanner.parsePlan(raw);
    if (parsed === undefined) {
      res.note = '云端返回无法解析';
      return res;
    }

    const valid: string[] = AgentTools.all().map((t: AgentTool): string => t.name);
    const plans: AgentPlan[] = [];
    for (let i: number = 0; i < parsed.steps.length && plans.length < 3; i++) {
      const s = parsed.steps[i];
      if (valid.indexOf(s.tool) < 0) {
        Log.w(`AgentPlanner 云端给出无效工具名：${s.tool}（已忽略）`);
        continue;
      }
      const p: AgentPlan = new AgentPlan();
      p.tool = s.tool;
      p.args = s.args === undefined ? {} : s.args;
      p.why = s.why === undefined ? '' : s.why;
      plans.push(p);
    }

    res.plans = plans;
    res.source = 'cloud';
    res.note = `云端规划 ${plans.length} 步`;
    Log.i(`AgentPlanner 云端规划：${names(plans)}`);
    return res;
  }

  private static planMessages(question: string): ChatMessage[] {
    const catalog: string[] = [];
    const all: AgentTool[] = AgentTools.all();
    for (let i: number = 0; i < all.length; i++) {
      catalog.push(`- ${all[i].name}：${all[i].desc}｜参数：${all[i].args.length > 0 ? all[i].args : '无'}`);
    }

    const system: string =
      '你是「灯塔」的端侧智能体的任务规划器，服务对象是中国 2027 届秋招、求职方向为 Java 后端的应届生。\n' +
      '你的唯一任务：把用户的一句问话，拆成一组工具调用。\n' +
      '\n' +
      '可用工具：\n' + catalog.join('\n') + '\n' +
      '\n' +
      '规则：\n' +
      '1. 只能使用上面列出的工具名，绝不能自己发明工具或参数名。\n' +
      '2. 只输出一个合法 json 对象，不要 markdown 代码块，不要任何解释文字。\n' +
      '3. 最多 3 步。能一步查完就不要拆两步。\n' +
      '4. 用户提到具体公司时，把公司名填进 args.company。\n' +
      '5. 如果用户的问话不涉及这些工具能回答的范围（比如闲聊、让你写简历全文），' +
      '输出 {"steps":[]} —— 不要硬凑。\n' +
      '6. json 里出现 "json" 字样是接口要求，照做即可。';

    const user: string =
      '【用户问话】\n' + question + '\n\n' +
      '【按以下 json 结构输出】\n' +
      '{"steps":[{"tool":"工具名","args":{"company":"可选"},"why":"为什么调它（15 字内）"}]}';

    const out: ChatMessage[] = [];
    out.push({ role: 'system', content: system });
    out.push({ role: 'user', content: user });
    return out;
  }

  /**
   * 解析云端返回的 JSON。
   *
   * ⚠ 模型偶尔会在 JSON 前后裹 ```json 代码块 —— 先按原样试，失败再剥 fence 重试一次。
   *   这一层必须"宽容但有限度"：能救回常见格式问题，解析不出来就老实返回 undefined。
   */
  private static parsePlan(raw: string): CloudPlan | undefined {
    if (raw.length === 0) {
      return undefined;
    }
    try {
      return JSON.parse(raw) as CloudPlan;
    } catch (e) {
      // 裹了代码块的情况
      const first: number = raw.indexOf('{');
      const last: number = raw.lastIndexOf('}');
      if (first < 0 || last <= first) {
        return undefined;
      }
      try {
        return JSON.parse(raw.substring(first, last + 1)) as CloudPlan;
      } catch (e2) {
        return undefined;
      }
    }
  }
}

/* ================================ 规则表 ================================ */

class RuleDef {
  tool: string = '';
  words: string[] = [];
  why: string = '';

  constructor(tool: string, words: string[], why: string) {
    this.tool = tool;
    this.words = words;
    this.why = why;
  }
}

class ScoredRule {
  hit: number = 0;
  rule: RuleDef = new RuleDef('', [], '');

  constructor(hit: number, rule: RuleDef) {
    this.hit = hit;
    this.rule = rule;
  }
}

/**
 * 本地规则表。
 *
 * ⚠ 顺序有讲究：**越具体的越靠前**。同分时保持表里的先后，
 *   所以"下一个节点"要排在"待办清单"前面 —— 用户问"最近有啥安排"时，
 *   其实最想要的是"最先要做的是哪个"，而不是一份完整清单。
 */
const LOCAL_RULES: RuleDef[] = [
  new RuleDef('next_node', ['下一个', '最近', '最近有', '接下来', '马上', '先看哪个', '先准备', '第一个'],
    '推算最先要到来的那个节点'),
  new RuleDef('countdown', ['还有多久', '倒计时', '还剩多少', '几天后', '什么时候'],
    '算出精确的剩余时间'),
  new RuleDef('jd_match', ['jd', '岗位匹配', '匹配度', '适不适合', '技能差距', '距离这个岗', '还差', '够不够'],
    '做岗位技能差距分析'),
  new RuleDef('review_summary', ['复盘', '雷达', '哪方面', '哪块最弱', '能力', '短板', '总结', '面得怎么样'],
    '汇总能力雷达找短板'),
  new RuleDef('events_query', ['安排', '日程', '节点', '笔试', '面试', '截止', '清单', '列表', '日历'],
    '列出节点日历'),
  new RuleDef('apps_query', ['投递', '投了', '简历', '状态', '公司', 'offer', '进展', '几家', '怎么样了'],
    '查投递库现状')
];

function names(plans: AgentPlan[]): string {
  const out: string[] = [];
  for (let i: number = 0; i < plans.length; i++) {
    out.push(plans[i].tool);
  }
  return out.join(' → ');
}
