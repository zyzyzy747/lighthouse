/**
 * 灯塔 Lighthouse · 复盘分析编排
 * 目标路径：entry/src/main/ets/service/ReviewAnalyzer.ets
 * ------------------------------------------------------------------
 * 这是整个 AI 能力的收口点，也是产品对外承诺的唯一入口：
 *
 *   analyze() 一定会返回结果，永远不会抛异常，永远不会让 UI 卡住。
 *
 * 为什么坚持这个契约：求职工具最怕的是"关键时刻用不了"。
 * 用户可能在地铁上、在宣讲会现场、在断网的宿舍里写复盘。
 * 如果这时应用只弹一句「网络错误」，那这个功能就是废的。
 *
 * 三条降级路径（都会被如实告知用户，不假装是 AI 的结论）：
 *   1. 云端可用 → 有结果且能解析   → 云端结论
 *   2. 云端可用 → 超时 / 限流 / 解析失败 → 本地引擎
 *   3. 云端关闭 / 无 key           → 本地引擎（并说明如何开启）
 *
 * 另有一条硬约束：无论走哪条路，返回的 dimensions 都必须是
 * **固定 6 维、固定顺序、同 key**，否则雷达图会缺角、历史对比会错位。
 */

import {
  AiErrorKind, AiResult, ReviewAnalysis, RadarDimension, RadarDef
} from '../common/AiTypes';
import { DeepSeekClient } from './DeepSeekClient';
import { PromptLibrary } from './PromptLibrary';
import { LocalRadar } from './LocalRadar';
import { Log } from '../common/Logger';

/** 一次分析的完整交代：结果 + 来源 + 失败原因，UI 全部要展示 */
export interface AnalyzeOutcome {
  analysis: ReviewAnalysis;
  /** true = 云端模型结论；false = 本地关键词引擎 */
  fromCloud: boolean;
  /** 引擎展示名，直接给用户看 */
  engine: string;
  /** 降级时的原因分类 */
  errorKind: AiErrorKind;
  /** 降级时的可读原因 */
  errorMsg: string;
  latencyMs: number;
  tokens: number;
}

export class ReviewAnalyzer {
  /** 六维平均分，写入 review.score_avg，用于「我的」页统计与历史趋势 */
  static scoreAvgOf(a: ReviewAnalysis): number {
    let sum: number = 0;
    for (let i: number = 0; i < a.dimensions.length; i++) {
      sum = sum + a.dimensions[i].score;
    }
    if (a.dimensions.length === 0) {
      return 0;
    }
    return Math.round(sum / a.dimensions.length);
  }

  /**
   * 主入口。**保证有返回值**，调用方不需要 try/catch。
   */
  static async analyze(narration: string, jobTitle: string, company: string): Promise<AnalyzeOutcome> {
    const client: DeepSeekClient = DeepSeekClient.get();

    if (narration.trim().length < 8) {
      // 太短的输入没必要发请求：模型只会编
      const short: AnalyzeOutcome = {
        analysis: ReviewAnalyzer.tooShort(),
        fromCloud: false,
        engine: '本地引擎',
        errorKind: AiErrorKind.NONE,
        errorMsg: '',
        latencyMs: 0,
        tokens: 0
      };
      return short;
    }

    if (client.isCloudEnabled()) {
      const messages = PromptLibrary.reviewAnalysis(narration, jobTitle, company);
      Log.i('开始云端复盘分析，文本长度=' + narration.length);
      const r: AiResult<ReviewAnalysis> =
        await client.chatJson<ReviewAnalysis>(messages, 2000);

      if (r.ok && r.data !== undefined) {
        const normalized: ReviewAnalysis = ReviewAnalyzer.normalize(r.data);
        Log.i(`云端分析完成 用时${r.latencyMs}ms`);
        const ok: AnalyzeOutcome = {
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

      // 云端失败 —— 明确记录原因，然后把结果给出去
      const why: string = r.error !== undefined ? r.error : '未知原因';
      Log.w(`云端分析失败（${r.errorKind}：${why}），降级到本地引擎`);
      const fallback: AnalyzeOutcome = ReviewAnalyzer.local(narration);
      fallback.errorKind = r.errorKind;
      fallback.errorMsg = why;
      fallback.latencyMs = r.latencyMs !== undefined ? r.latencyMs : 0;
      return fallback;
    }

    const reason: string = client.isCloudAllowed()
      ? '未配置 API Key，去「我的 → AI 设置」填入即可启用云端分析'
      : '你已关闭云端 AI，全程本地运算';
    Log.i('云端不可用：' + reason);
    const local: AnalyzeOutcome = ReviewAnalyzer.local(narration);
    local.errorKind = client.isCloudAllowed() ? AiErrorKind.NO_KEY : AiErrorKind.OFFLINE;
    local.errorMsg = reason;
    return local;
  }

  /** 本地兜底：同步、瞬间完成、永不失败 */
  private static local(narration: string): AnalyzeOutcome {
    const started: number = Date.now();
    const analysis: ReviewAnalysis = LocalRadar.analyze(narration);
    const out: AnalyzeOutcome = {
      analysis: analysis,
      fromCloud: false,
      engine: LocalRadar.ENGINE_NAME,
      errorKind: AiErrorKind.NONE,
      errorMsg: '',
      latencyMs: Date.now() - started,
      tokens: 0
    };
    return out;
  }

  private static tooShort(): ReviewAnalysis {
    const dims: RadarDimension[] = [];
    for (let i: number = 0; i < RadarDef.KEYS.length; i++) {
      const k: string = RadarDef.KEYS[i];
      const d: RadarDimension = {
        key: k,
        label: RadarDef.labelOf(k),
        score: 0,
        evidence: '回忆太短，无法判断',
        advice: '把面试官问的问题原样记下来，再生成雷达'
      };
      dims.push(d);
    }
    const a: ReviewAnalysis = {
      summary: '内容太少，先把这场面试问了什么写清楚',
      dimensions: dims,
      topWeakness: '待补充信息',
      nextActions: ['回忆并写下至少 3 个被问到的问题', '写下当时自己是怎么答的', '写下卡住的地方'],
    };
    return a;
  }

  /**
   * 把模型输出规范成固定 6 维。
   * 模型偶尔会漏维度、改 key、或把分数写成字符串 —— 这里全部兜住。
   * 这是「云端」和「本地」两条路能对接同一套 UI 的前提。
   */
  private static normalize(raw: ReviewAnalysis): ReviewAnalysis {
    const incoming: RadarDimension[] = raw.dimensions !== undefined ? raw.dimensions : [];
    const dims: RadarDimension[] = [];

    for (let i: number = 0; i < RadarDef.KEYS.length; i++) {
      const key: string = RadarDef.KEYS[i];
      let found: RadarDimension | undefined = undefined;
      for (let j: number = 0; j < incoming.length; j++) {
        if (incoming[j].key === key) {
          found = incoming[j];
          break;
        }
      }
      if (found === undefined) {
        const missing: RadarDimension = {
          key: key,
          label: RadarDef.labelOf(key),
          score: 0,
          evidence: '本次面试未涉及',
          advice: '—'
        };
        dims.push(missing);
      } else {
        const fixedScore: number = ReviewAnalyzer.clamp(found.score);
        const ev: string = found.evidence !== undefined && found.evidence.length > 0
          ? found.evidence : '本次面试未涉及';
        const ad: string = found.advice !== undefined && found.advice.length > 0
          ? found.advice : '—';
        const d: RadarDimension = {
          key: key,
          label: RadarDef.labelOf(key),
          score: fixedScore,
          evidence: ev,
          advice: ad
        };
        dims.push(d);
      }
    }

    const summary: string = raw.summary !== undefined && raw.summary.length > 0
      ? raw.summary : '本次分析未给出总结';
    const weakness: string = raw.topWeakness !== undefined && raw.topWeakness.length > 0
      ? raw.topWeakness : '—';
    let actions: string[] = raw.nextActions !== undefined ? raw.nextActions : [];
    if (actions.length === 0) {
      actions = ['（模型未给出具体动作，建议重新生成）'];
    }

    const out: ReviewAnalysis = {
      summary: summary,
      dimensions: dims,
      topWeakness: weakness,
      nextActions: actions
    };
    return out;
  }

  private static clamp(v: number): number {
    if (v === undefined || v === null || isNaN(v)) {
      return 0;
    }
    if (v < 0) {
      return 0;
    }
    if (v > 100) {
      return 100;
    }
    return Math.round(v);
  }
}
