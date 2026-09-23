/**
 * 灯塔 Lighthouse · AI 层类型与配置
 * 目标路径：entry/src/main/ets/common/AiTypes.ets
 * ------------------------------------------------------------------
 * 本文件把「与 DeepSeek 通信」的所有契约集中在一处：
 * 请求体、响应体、统一结果、错误分类、模型与端点常量。
 * 业务代码只依赖 AiResult<T>，不直接接触 HTTP 细节。
 */

import { BUILTIN_DEMO_KEY } from './AiSecret';

/* ============================ 1. 端点与模型 ============================ */

export class AiConfig {
  /** DeepSeek 对话补全端点（OpenAI 兼容格式） */
  static readonly ENDPOINT: string = 'https://api.deepseek.com/chat/completions';

  /**
   * 日常模型。注意旧的 `deepseek-chat` / `deepseek-reasoner` 别名已退役，
   * 当前正确名字是 `deepseek-flash`（对应 DeepSeek-V4.1-Flash）。
   * 已核实：https://api-docs.deepseek.com/quick_start/pricing
   */
  static readonly MODEL_FAST: string = 'deepseek-flash';

  /** 强推理模型，仅用于最难的复盘归因；日常不要用，贵数倍 */
  static readonly MODEL_DEEP: string = 'deepseek-v4-pro';

  /** 连接超时 / 读取超时（毫秒）。LLM 生成可能较慢，读取给足 */
  static readonly CONNECT_TIMEOUT: number = 15000;
  static readonly READ_TIMEOUT: number = 60000;

  /**
   * 提前放弃阈值（毫秒）。
   * 演示场景下让用户干等 60 秒是不可接受的 —— 超过这个时间即使请求还没超时，
   * 也要立刻降级到本地引擎，把结果先端上来。README/PPT 里可写成「10 秒熔断」。
   */
  static readonly SOFT_DEADLINE: number = 12000;

  /** 失败重试次数（仅对 5xx / 超时 / JSON 解析失败生效） */
  static readonly MAX_RETRY: number = 1;

  /** 默认输出上限，防止模型话痨拖慢演示节奏并推高成本 */
  static readonly DEFAULT_MAX_TOKENS: number = 1500;

  /**
   * 内置演示密钥 —— 真正的值在 AiSecret.ets，由 tools/inject_key.py 注入。
   * ⚠ 这里只放一个**单独申请、只充少量余额、设了消费限额**的 key，
   *   绝不放主账号 key。hap 包内字节码可被逆向，硬编码密钥一定会泄露。
   *   正式答辩口径是 BYOK（用户自带密钥），见「我的 → AI 设置」。
   */
  static readonly DEMO_KEY: string = BUILTIN_DEMO_KEY;

  /** 偏好数据库（设置页读写） */
  static readonly STORE_NAME: string = 'lighthouse_settings';
  static readonly PREF_API_KEY: string = 'deepseek_api_key';
  static readonly PREF_ALLOW_CLOUD: string = 'allow_cloud_ai';

  /**
   * 技能底牌：一段用户自述"我会什么、哪里弱"的文本，JD 匹配分析的输入之一。
   * ⚠ 没有它，模型无法判断「具备 / 部分 / 缺失」，只能瞎猜 —— prompt 里写死了
   *   「底牌里没提到的技能一律记缺失」，所以底牌为空时结果会全是"缺失"，看着像 bug。
   */
  static readonly PREF_SKILL_PROFILE: string = 'skill_profile';
}

/* ============================ 2. 通信契约 ============================ */

export interface ChatMessage {
  role: string;                    // 'system' | 'user' | 'assistant'
  content: string;
  /** thinking 模式下模型回传的思维链，与 content 同级。我们关掉 thinking，一般不出现 */
  reasoning_content?: string;
}

/**
 * ⚠ 只允许 'json_object'。OpenAI 兼容接口不支持 {type:'text'} —— 传了会 400。
 * 需要纯文本输出时，**整个字段省略**，而不是传 'text'。
 * 这是前序版本踩过的真 bug，别改回去。
 */
export interface ResponseFormat {
  type: string;                    // 'json_object'
}

export interface ThinkingConfig {
  type: string;                    // 'enabled' | 'disabled'
}

export interface ChatRequest {
  model: string;
  messages: ChatMessage[];
  stream: boolean;
  temperature: number;
  max_tokens: number;
  response_format?: ResponseFormat;  // 仅在需要结构化输出时出现
  thinking?: ThinkingConfig;
}

export interface ChatChoice {
  index: number;
  message: ChatMessage;
  finish_reason: string;
}

export interface UsageInfo {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
}

export interface ChatResponse {
  id: string;
  model: string;
  choices: ChatChoice[];
  usage: UsageInfo;
}

/* ============================ 3. 错误分类 ============================ */

/**
 * 错误分类是降级策略的开关：只有 OFFLINE / AUTH / NO_KEY 才必须回落到本地引擎，
 * SERVER / RATE_LIMIT 可以重试后仍失败再降级。
 */
export enum AiErrorKind {
  NONE = 'none',
  NO_KEY = 'no_key',           // 没有可用密钥
  OFFLINE = 'offline',         // 网络不可达 —— 演示断网走这条
  AUTH = 'auth',               // 401/403 密钥无效
  RATE_LIMIT = 'rate_limit',   // 429
  SERVER = 'server',           // 5xx
  PARSE = 'parse',             // 返回内容不是合法 JSON
  TIMEOUT = 'timeout',         // 超过 SOFT_DEADLINE 主动放弃
  UNKNOWN = 'unknown'
}

/** 统一返回包装：业务层只需要看 ok / data / errorKind 三个字段 */
export interface AiResult<T> {
  ok: boolean;
  errorKind: AiErrorKind;
  data?: T;
  error?: string;
  raw?: string;              // 原始文本，便于排查与埋点
  latencyMs?: number;        // 耗时，可写进 PPT 的性能数据
  usage?: UsageInfo;
}

/* ============================ 4. 业务数据结构 ============================ */

/** 能力雷达的一个维度 */
export interface RadarDimension {
  key: string;        // 'java_core' | 'database' | ...
  label: string;      // 'Java 基础与并发'
  score: number;      // 0-100
  evidence: string;   // 面试原话中的证据片段
  advice: string;     // 下一步具体动作
}

/** 面试复盘分析结果 —— 产品的灵魂数据结构 */
export interface ReviewAnalysis {
  summary: string;
  dimensions: RadarDimension[];
  topWeakness: string;
  nextActions: string[];
}

/**
 * 雷达落库信封：把「结果本体」和「来源元数据」一起存下来。
 *
 * 为什么需要它：radar_json 原本只存 ReviewAnalysis 本身，来源信息（云端还是本地、
 * 用时多久、烧了多少 token）只活在页面的 @State 里 —— 一退出应用就没了。结果是
 * 重进应用看历史雷达时，用户无从知道这条结论是云端模型给的还是本地关键词初判的。
 * 「如实标注来源」是这个产品的原则，不能只在刚生成的那一瞬间成立。
 *
 * 兼容：v1 的历史数据里 radar_json 就是 ReviewAnalysis 本身（没有 analysis 字段）。
 *      读到这种就按 v1 处理 —— 来源标注留空，而不是瞎猜一个。
 */
export interface RadarEnvelope {
  v: number;                  // 2 = 当前格式；1 = 历史裸格式
  analysis: ReviewAnalysis;
  fromCloud: boolean;
  engine: string;             // 如 '云端模型 deepseek-flash' / '本地关键词引擎'
  latencyMs: number;
  tokens: number;
  analyzedAt: number;         // 毫秒时间戳
}

/**
 * 解析落库的雷达 JSON。
 *
 * 两种格式：v2 是上面那个信封；v1（历史数据）本体就是 ReviewAnalysis 本身。
 * 分辨方法：有没有 analysis 字段。
 *
 * ⚠ 这一份是**复盘页和「灯塔助手」共用的**：两边各写一遍迟早会分叉
 *   （改了其中之一、另一个还停在旧逻辑），所以抽在这里。
 * ⚠ 解析失败一律返回 undefined（"没有雷达"），绝不让坏数据崩页面 ——
 *   宁可少显示一张图，也不要显示一个错的分析。
 */
export function parseRadarEnvelope(json: string): RadarEnvelope | undefined {
  if (json === undefined || json === null || json.length === 0) {
    return undefined;
  }
  try {
    // ArkTS 严格模式不允许把同一个值当两种接口混用，所以 v1 兼容走
    // 「同一段 JSON 换一个类型视角再解析一次」，而不是复用同一个变量。
    const env: RadarEnvelope = JSON.parse(json) as RadarEnvelope;
    if (env.analysis !== undefined) {
      return env;
    }
    const bare: ReviewAnalysis = JSON.parse(json) as ReviewAnalysis;
    // v1 来源无从考证 —— 留空，绝不编一个
    const legacy: RadarEnvelope = {
      v: 1,
      analysis: bare,
      fromCloud: false,
      engine: '',
      latencyMs: 0,
      tokens: 0,
      analyzedAt: 0
    };
    return legacy;
  } catch (e) {
    return undefined;
  }
}

/** 六维雷达的固定顺序与中文名。云端返回、本地引擎、UI 绘制三方共用这一份定义 */
export class RadarDef {
  static readonly KEYS: string[] =
    ['java_core', 'database', 'framework', 'cs_basic', 'algo', 'project'];
  static readonly LABELS: string[] =
    ['Java 基础与并发', '数据库与 MySQL', '框架 Spring/MyBatis', '计算机基础', '算法与数据结构', '项目表达与追问'];
  /** 雷达图上的短标签，画六边形时用，避免文字互相压住 */
  static readonly SHORT: string[] =
    ['Java', '数据库', '框架', '计基', '算法', '项目'];

  static labelOf(key: string): string {
    for (let i: number = 0; i < RadarDef.KEYS.length; i++) {
      if (RadarDef.KEYS[i] === key) {
        return RadarDef.LABELS[i];
      }
    }
    return key;
  }

  static shortOf(key: string): string {
    for (let i: number = 0; i < RadarDef.KEYS.length; i++) {
      if (RadarDef.KEYS[i] === key) {
        return RadarDef.SHORT[i];
      }
    }
    return key;
  }
}

/** JD 岗位匹配分析结果 */
export interface JdSkillItem {
  skill: string;
  level: string;      // '必须' | '加分'
  myStatus: string;   // '具备' | '部分' | '缺失'
  note: string;
}

export interface JdAnalysis {
  jobTitle: string;
  items: JdSkillItem[];
  gapScore: number;             // 0-100 匹配度
  interviewFocus: string[];     // 预测会被追问的点
  prepPlan: string[];           // 备考动作
}

/** 复盘追问教练的一轮对话 */
export interface DrillTurn {
  question: string;             // 面试官追问
  hint: string;                 // 这道题想考什么
  suggestedAnswer: string;      // 建议的回答结构（不是标准答案）
}
