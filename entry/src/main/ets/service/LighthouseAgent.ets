/**
 * 灯塔 Lighthouse · 端侧智能体
 * 目标路径：entry/src/main/ets/service/LighthouseAgent.ets
 * ------------------------------------------------------------------
 * 把「用户的一句话」变成「一次有依据的回答」：
 *
 *      问 → 规划（意图） → 调工具（查/算/分析） → 汇总 → 回答 + 依据
 *
 * ★★ 整个设计里最要紧的一条决定：
 *
 *      **云端只负责"听懂问题"，永远不负责"编造答案"。**
 *
 *   所有回答都由图工具返回的真实结果**在本地合成**，一个字都不会由模型生成。
 *   这么做换来三件事：
 *     ① 不会幻觉。模型在这条链路上的唯一权限是"挑工具"，它就算想编也编不出来；
 *     ② 断网可用。规划本地优先，云端只是"没见过的问法"的补丁；
 *     ③ 可验证。答案是确定性的函数 f(数据)，验收脚本能逐条比对，不是碰运气。
 *
 *   代价是"话说得不如大模型漂亮"。对一个要告诉用户
 *   "你明天几点面试"的产品来说，这个交换非常划算 ——
 *   **宁可朴素地说实话，不要漂亮地说假话**。
 */

import { common } from '@kit.AbilityKit';
import { AgentPlan, AgentPlanResult, AgentPlanner } from './AgentPlanner';
import { AgentTools, ToolResult, setAgentContext } from './AgentTools';
import { DeepSeekClient } from './DeepSeekClient';
import { Log } from '../common/Logger';

/** 界面要展示的一步工具调用 */
export class AgentStepView {
  tool: string = '';
  label: string = '';
  ok: boolean = true;
  why: string = '';
  lines: string[] = [];
}

/** 一次完整的回答 */
export class AgentAnswer {
  question: string = '';
  text: string = '';
  steps: AgentStepView[] = [];
  /** 给 UI 的来源标签，如「本地规划」/「云端规划」 */
  source: string = '';
  /** 来源的补充说明 */
  note: string = '';
  /** false = 没听懂这句话（本地没规则、云端也不可用或没给东西） */
  understood: boolean = true;
}

/** 拿不到答案时给用户的台阶 —— 同时也是"能问什么"的示范 */
export const AGENT_SUGGESTIONS: string[] = [
  '最近要准备什么？',
  '我投了哪些还在流程里？',
  '我哪方面最弱？',
  'JD 匹配怎么样？'
];

export class LighthouseAgent {
  /**
   * 主流程。
   *
   * ⚠ 每一层都可能失败，但**失败必须收敛成一句话**，不能抛给 UI：
   *   用户要的是"这句我没听懂，试试问……"，不是一面红字堆栈。
   */
  static async ask(question: string): Promise<AgentAnswer> {
    const ans: AgentAnswer = new AgentAnswer();
    ans.question = question;

    const trimmed: string = question.trim();
    if (trimmed.length === 0) {
      ans.understood = false;
      ans.text = '先问点什么吧，比如「最近要准备什么」。';
      ans.source = '本地规划';
      ans.note = '空输入';
      return ans;
    }

    // ① 规划：本地优先
    let plan: AgentPlanResult = await AgentPlanner.local(trimmed);
    if (plan.plans.length === 0) {
      const cloud: AgentPlanResult = await AgentPlanner.cloud(trimmed);
      if (cloud.plans.length > 0) {
        plan = cloud;
      } else if (cloud.note.length > 0) {
        // 本地没规则命中，云端也不可用/没给出东西 —— 如实说没听懂
        ans.understood = false;
        ans.source = '本地规划';
        ans.note = cloud.note;
        ans.text = LighthouseAgent.notUnderstood(cloud.note);
        Log.i(`Agent 没听懂：${cloud.note}`);
        return ans;
      } else {
        ans.understood = false;
        ans.source = '本地规划';
        ans.note = '本地规则与云端都没给出计划';
        ans.text = LighthouseAgent.notUnderstood('');
        return ans;
      }
    }

    ans.source = plan.source === 'cloud' ? '云端规划' : '本地规划';
    ans.note = plan.note;

    // ② 执行：串行跑，前一步的结果对后一步没依赖（工具各自查自己的表），
    //    串行纯粹是为了让轨迹顺序稳定 —— UI 上要按同样的顺序讲故事。
    for (let i: number = 0; i < plan.plans.length; i++) {
      const p: AgentPlan = plan.plans[i];
      const r: ToolResult = await AgentTools.invoke(p.tool, p.args);
      const v: AgentStepView = new AgentStepView();
      v.tool = p.tool;
      v.why = p.why;
      v.label = r.label;
      v.ok = r.ok;
      v.lines = r.lines;
      ans.steps.push(v);
    }

    // ③ 汇总：本地合成，不用模型（见文件头的取舍说明）
    ans.text = LighthouseAgent.compose(ans.steps);
    if (ans.text.length === 0) {
      ans.understood = false;
      ans.text = LighthouseAgent.notUnderstood('工具都没查到可用结果');
    }
    Log.i(`Agent 回答完成 source=${ans.source} steps=${ans.steps.length} understood=${ans.understood}`);
    return ans;
  }

  /** 这套家里的所有工具都没命中时的台阶 */
  private static notUnderstood(why: string): string {
    const tail: string = why.length > 0 ? `（${why}）` : '';
    return `这句我还没学会怎么答${tail}。我能做的大概是这几类：查投递进展、算节点倒计时、` +
      '看能力短板、做 JD 匹配。换一句话试试，比如「最近要准备什么」。';
  }

  /**
   * 把工具结果合成自然语言。
   *
   * ⚠ 全部由模板拼装 —— **没有一个字是模型生成的**，也没有一个字是猜的。
   *   查不到就说查不到，这是这个助手最值钱的性格。
   */
  private static compose(steps: AgentStepView[]): string {
    const blocks: string[] = [];
    const gone: string[] = [];

    for (let i: number = 0; i < steps.length; i++) {
      const s: AgentStepView = steps[i];
      if (!s.ok) {
        gone.push(s.label);
        continue;
      }
      if (s.lines.length === 0) {
        continue;
      }
      const head: string = LighthouseAgent.leadOf(s.tool);
      const body: string = s.lines.join('\n');
      blocks.push(`${head}\n${body}`);
    }

    let text: string = blocks.join('\n\n');

    if (gone.length > 0) {
      const tail: string = `\n\n另外这几项没查到：${gone.join('；')}。`;
      text = text.length > 0 ? text + tail : `没查到能回答这句的内容：${gone.join('；')}。`;
    }
    return text;
  }

  /** 每个工具的开场句 —— 决定回答读起来像不像人话 */
  private static leadOf(tool: string): string {
    switch (tool) {
      case 'next_node':
        return '最先要到来的节点：';
      case 'countdown':
        return '倒计时：';
      case 'events_query':
        return '接下来的节点安排：';
      case 'apps_query':
        return '投递库里目前是：';
      case 'review_summary':
        return '你的能力现状：';
      case 'jd_match':
        return '岗位匹配的结果：';
      default:
        return '查到：';
    }
  }

  /** UI 想知道云端到底能不能用（用于在界面上如实标注，而不是假装离线也智能） */
  static cloudAvailable(): boolean {
    return DeepSeekClient.get().isCloudEnabled();
  }

  /** 给工具类塞上下文。UI 建好之后调一次即可。 */
  static bindContext(ctx: common.Context): void {
    setAgentContext(ctx);
  }
}
