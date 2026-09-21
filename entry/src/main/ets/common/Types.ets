/**
 * 灯塔 Lighthouse · 数据模型
 *
 * 约定：所有业务状态一律用这里的枚举，禁止在 UI 层写字符串字面量。
 * 改枚举值 = 改数据库存量数据，必须同步写迁移。
 */

/** 投递漏斗阶段。顺序即漏斗顺序，不要随意调整 order。 */
export enum AppStatus {
  WISH = 'wish',             // 想投，还没投
  APPLIED = 'applied',       // 已投递
  SCREEN = 'screen',         // HR 沟通 / 简历筛选
  WRITTEN = 'written',       // 笔试
  INTERVIEW = 'interview',   // 面试中
  OFFER = 'offer',           // 拿到 offer
  REJECTED = 'rejected',     // 流程终止（感谢信 / 无声）
  WITHDRAWN = 'withdrawn'    // 自己放弃
}

/** 关键时间节点类型 */
export enum EventType {
  DEADLINE = 'deadline',     // 投递截止
  WRITTEN = 'written',       // 笔试
  INTERVIEW = 'interview',   // 面试
  OTHER = 'other'            // 宣讲会 / 测评 / 其他
}

/** 面试轮次 */
export enum InterviewRound {
  HR = 'hr',
  TECH_1 = 'tech1',
  TECH_2 = 'tech2',
  LEADER = 'leader',
  OTHER = 'other'
}

/**
 * 能力雷达六维。
 * ⚠ 与 service/PromptLibrary 里的打分维度严格一一对应，改这里必须同步改 prompt。
 */
export enum SkillDim {
  ALGO = 'algo',             // 算法与数据结构
  LANG = 'lang',             // 语言与计算机基础
  FRAME = 'frame',           // 框架与中间件
  PROJECT = 'project',       // 项目深度与表达
  DESIGN = 'design',         // 系统设计
  COMM = 'comm'              // 沟通与应变
}

/** 投递记录 */
export interface Application {
  id: number;
  company: string;
  position: string;
  city: string;
  channel: string;          // 投递渠道：官网 / BOSS / 牛客 / 内推 / 其他
  status: string;           // AppStatus
  salaryMin: number;        // 单位：k，0 表示未知
  salaryMax: number;
  jdText: string;           // JD 原文，供 AI 做技能差距分析
  appliedAt: number;        // 投递时间戳（ms），0 表示未投
  updatedAt: number;
  note: string;
}

/** 关键节点（笔试/面试/截止）。todo 页与桌面卡片都消费这张表。 */
export interface EventNode {
  id: number;
  appId: number;
  type: string;             // EventType
  title: string;
  happenAt: number;         // 事件发生时间戳（ms）
  done: boolean;
  note: string;
}

/** 面试复盘 */
export interface ReviewRecord {
  id: number;
  appId: number;
  round: string;            // InterviewRound
  interviewer: string;      // 面试官画像，如「技术面 · 中间件组」
  narration: string;        // 用户自述的复盘原文，是 AI 打分的唯一输入
  radarJson: string;        // 六维得分 JSON，空串表示未分析
  scoreAvg: number;         // 平均分，用于列表排序
  createdAt: number;
}

/** 六维分数（雷达图数据点） */
export interface RadarPoint {
  dim: string;              // SkillDim
  label: string;            // 中文名，直接用于渲染
  score: number;            // 0-10
  evidence: string;         // AI 给出的原话依据，缺省为空
}

/** 状态元数据：标签、配色、漏斗权重 */
export class StatusMeta {
  key: string;
  label: string;
  color: string;
  order: number;
  inFunnel: boolean;        // 是否计入漏斗统计

  constructor(key: string, label: string, color: string, order: number, inFunnel: boolean) {
    this.key = key;
    this.label = label;
    this.color = color;
    this.order = order;
    this.inFunnel = inFunnel;
  }
}

/** 节点类型元数据 */
export class EventTypeMeta {
  key: string;
  label: string;
  color: string;

  constructor(key: string, label: string, color: string) {
    this.key = key;
    this.label = label;
    this.color = color;
  }
}

export const STATUS_LIST: StatusMeta[] = [
  new StatusMeta(AppStatus.WISH, '想投', '#8FA3C0', 0, false),
  new StatusMeta(AppStatus.APPLIED, '已投递', '#4A9EFF', 1, true),
  new StatusMeta(AppStatus.SCREEN, '沟通中', '#5BC8F5', 2, true),
  new StatusMeta(AppStatus.WRITTEN, '笔试', '#A78BFA', 3, true),
  new StatusMeta(AppStatus.INTERVIEW, '面试', '#FFB020', 4, true),
  new StatusMeta(AppStatus.OFFER, 'Offer', '#3DD68C', 5, true),
  new StatusMeta(AppStatus.REJECTED, '已结束', '#FF5C5C', 6, false),
  new StatusMeta(AppStatus.WITHDRAWN, '已放弃', '#5A6B85', 7, false)
];

export const EVENT_TYPE_LIST: EventTypeMeta[] = [
  new EventTypeMeta(EventType.DEADLINE, '投递截止', '#FF5C5C'),
  new EventTypeMeta(EventType.WRITTEN, '笔试', '#A78BFA'),
  new EventTypeMeta(EventType.INTERVIEW, '面试', '#FFB020'),
  new EventTypeMeta(EventType.OTHER, '其他', '#8FA3C0')
];

/** 六维中文名与顺序，UI 与 prompt 共用 */
export const SKILL_LABELS: string[] = ['算法基础', '语言功底', '框架中间件', '项目表达', '系统设计', '沟通应变'];
export const SKILL_KEYS: string[] = [
  SkillDim.ALGO, SkillDim.LANG, SkillDim.FRAME, SkillDim.PROJECT, SkillDim.DESIGN, SkillDim.COMM
];

export function getStatusMeta(key: string): StatusMeta {
  for (let i = 0; i < STATUS_LIST.length; i++) {
    if (STATUS_LIST[i].key === key) {
      return STATUS_LIST[i];
    }
  }
  return STATUS_LIST[1];
}

export function getEventTypeMeta(key: string): EventTypeMeta {
  for (let i = 0; i < EVENT_TYPE_LIST.length; i++) {
    if (EVENT_TYPE_LIST[i].key === key) {
      return EVENT_TYPE_LIST[i];
    }
  }
  return EVENT_TYPE_LIST[3];
}

export function statusOrder(key: string): number {
  return getStatusMeta(key).order;
}

/** 空投递记录，用于表单初始化 */
export function emptyApplication(): Application {
  return {
    id: 0,
    company: '',
    position: '',
    city: '武汉',
    channel: '官网',
    status: AppStatus.APPLIED,
    salaryMin: 0,
    salaryMax: 0,
    jdText: '',
    appliedAt: 0,
    updatedAt: 0,
    note: ''
  };
}
