import { common } from '@kit.AbilityKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import notification from '@ohos.notification';
import { BusinessError } from '@kit.BasicServicesKit';
import { EventNode, EventType, getEventTypeMeta, EventTypeMeta } from '../common/Types';
import { EventRepo } from '../repository/EventRepo';
import { KvRepo } from '../repository/KvRepo';
import { Log } from '../common/Logger';
import { fmtDateTime, humanDeadline, countdownText } from '../common/Utils';
import { Notifier } from './Notifier';
import { NAV_MAP } from '../common/Nav';

const K_ENABLED: string = 'enabled';
const K_LEAD: string = 'leadHours';
const K_TWO_STAGE: string = 'twoStage';
const K_DND_ON: string = 'dndEnabled';
const K_DND_START: string = 'dndStart';
const K_DND_END: string = 'dndEnd';
const K_PLAN: string = 'plan';
const K_SENT: string = 'sent';
/** 后台自动同步（onForeground）拿到的代理提醒成败，落库供 UI 回显 */
const K_AGENT_FAILED: string = 'agentFailed';
const K_AGENT_DIAG: string = 'agentDiagnose';

const BUNDLE: string = 'com.wuit.lighthouse';
const ABILITY: string = 'EntryAbility';

const MIN: number = 60 * 1000;
const HOUR: number = 60 * MIN;
const DAY: number = 24 * HOUR;

/** 系统代理提醒的额度很宝贵（超限抛 1700002），按「最近的 N 个节点 × 最多 2 档」留足余量 */
const MAX_NODES: number = 6;
const MAX_REMINDERS: number = 14;
/** 只给 30 天内的节点排系统提醒 */
const HORIZON: number = 30 * DAY;
/** 提醒时刻距现在不足这个间隔就不再排系统提醒，改走即时通知（系统来不及调度） */
const IMMEDIATE_WINDOW: number = 2 * MIN;
/** 「开始前 1 小时」二次提醒 */
const SECOND_LEAD_HOURS: number = 1;
/** 去重记录上限，防止无限增长 */
const SENT_CAP: number = 200;

/** UI 上可选的提前量 */
export const LEAD_CHOICES: number[] = [1, 6, 24, 48];

export function leadLabel(hours: number): string {
  if (hours >= 24) {
    return `${Math.round(hours / 24)} 天`;
  }
  return `${hours} 小时`;
}

/** 哨兵偏好。默认全开：作品的价值就在于"主动找你"，默认关掉等于没做。 */
export class SentinelSettings {
  enabled: boolean = true;
  leadHours: number = 24;
  twoStage: boolean = true;
  dndEnabled: boolean = true;
  dndStart: number = 22;
  dndEnd: number = 8;
}

/** 一条已排进系统的代理提醒。落盘用于差分，避免每次 sync 重复排。 */
export class PlannedReminder {
  key: string = '';
  reminderId: number = 0;
  at: number = 0;

  constructor(key: string, reminderId: number, at: number) {
    this.key = key;
    this.reminderId = reminderId;
    this.at = at;
  }
}

/** 一次同步的结果，直接喂给 UI 和验证脚本 */
export class SentinelReport {
  enabled: boolean = true;
  permission: boolean = false;
  planned: number = 0;      // 本次新排
  kept: number = 0;         // 沿用未动
  cancelled: number = 0;    // 本次撤下
  failed: number = 0;       // 排程被系统拒绝的条数（>0 = 代理提醒在本机不可用）
  total: number = 0;        // 排完后系统里的总数
  immediate: number = 0;    // 本次发出的本地通知
  dndShifted: number = 0;   // 因免打扰被顺延的条数
  diagnose: string = '';    // 失败时的自检结论
  message: string = '';
}

/** 待排的一条系统提醒（内部结构） */
class Wish {
  key: string;
  at: number;
  stage: number;
  nodeId: number;
  title: string;
  content: string;

  constructor(key: string, at: number, stage: number, nodeId: number, title: string, content: string) {
    this.key = key;
    this.at = at;
    this.stage = stage;
    this.nodeId = nodeId;
    this.title = title;
    this.content = content;
  }
}

/**
 * 节奏哨兵。
 *
 * 把「投递截止 / 笔试 / 面试」三类节点变成会自己找上门的提醒。两条通道：
 *
 *   ① 本地通知（notificationManager）—— **真正可用的主通道**，无任何资质门槛。
 *      由「应用回前台」+「桌面卡片每 30 分钟的系统定时刷新」两处心跳驱动。
 *      卡片那次心跳很关键：它让提醒在**应用根本没打开**的时候也能发出，
 *      而且用的是 Form Kit 本来就会发生的系统唤醒，零额外权限、零后台任务。
 *
 *   ② 系统代理提醒（reminderAgentManager）—— 到点由系统弹，不依赖任何心跳，
 *      精度也最好。但它有**管控配额**：普通应用默认可用提醒数为 0，
 *      必须邮件向华为申请代理提醒权限。本机实测一条都排不进去（1700002），
 *      所以代码保留、失败时如实降级并自检，不假装排上了。
 *
 * 去重记录放 RDB：卡片进程与 UIAbility 是不同的进程，两边都要读同一份"发过没有"。
 */
export class Sentinel {
  private static busy: boolean = false;
  /** 自检结论缓存：进程内只真跑一次，但结论要能反复回显（见 sync 里的注释） */
  private static diagnosis: string = '';

  /* ==================== 配置读写（全部走 RDB，跨进程一致） ==================== */

  static async load(ctx: common.Context): Promise<SentinelSettings> {
    const s: SentinelSettings = new SentinelSettings();
    let kv: Record<string, string> = {};
    try {
      kv = await KvRepo.getAll();
    } catch (e) {
      const err: Error = e as Error;
      Log.w(`哨兵配置读取失败，用默认值：${err.message}`);
      return s;
    }
    s.enabled = Sentinel.bool(kv, K_ENABLED, true);
    s.leadHours = Sentinel.num(kv, K_LEAD, 24);
    s.twoStage = Sentinel.bool(kv, K_TWO_STAGE, true);
    s.dndEnabled = Sentinel.bool(kv, K_DND_ON, true);
    s.dndStart = Sentinel.num(kv, K_DND_START, 22);
    s.dndEnd = Sentinel.num(kv, K_DND_END, 8);
    return s;
  }

  static async save(ctx: common.Context, s: SentinelSettings): Promise<void> {
    // 提前量变了就要清空去重记录。
    // 语义上：用户把提前量从 1 天改成 2 天，意思是"我要更早被提醒"，
    // 那么旧的"按 1 天档位已经提醒过"就不该拦住新的 2 天档提醒；
    // 反过来调小，也该允许更接近出发点的档位再提醒一次。
    // 代价可控：清空后每个节点最多补一条当前档位的通知，不会刷屏。
    const before: SentinelSettings = await Sentinel.load(ctx);
    const leadChanged: boolean = before.leadHours !== s.leadHours;

    const map: Record<string, string> = {};
    map[K_ENABLED] = s.enabled ? '1' : '0';
    map[K_LEAD] = `${s.leadHours}`;
    map[K_TWO_STAGE] = s.twoStage ? '1' : '0';
    map[K_DND_ON] = s.dndEnabled ? '1' : '0';
    map[K_DND_START] = `${s.dndStart}`;
    map[K_DND_END] = `${s.dndEnd}`;
    if (leadChanged) {
      map[K_SENT] = '[]';
    }
    await KvRepo.putAll(map);
    Log.i(`哨兵配置已保存 enabled=${s.enabled} lead=${s.leadHours}h two=${s.twoStage} ` +
      `dnd=${s.dndEnabled} 去重表${leadChanged ? '已清空' : '保留'}`);
  }

  private static bool(kv: Record<string, string>, k: string, def: boolean): boolean {
    const v: string | undefined = kv[k];
    return v === undefined ? def : v === '1';
  }

  private static num(kv: Record<string, string>, k: string, def: number): number {
    const v: string | undefined = kv[k];
    if (v === undefined) {
      return def;
    }
    const n: number = Number.parseInt(v, 10);
    return Number.isNaN(n) ? def : n;
  }

  /* ==================== ① 本地通知：真正可用的主通道 ==================== */

  /**
   * 评估一次并发出该发的本地提醒。可被任何进程反复调用 —— 内部靠 RDB 去重。
   *
   * 触发点（都是"心跳"）：
   *   · EntryFormAbility.onUpdateForm —— 系统每 30 分钟唤醒卡片进程一次，**应用没打开也有效**
   *   · EntryAbility.onForeground     —— 用户回到应用
   *   · Index.bumpAndPush             —— 用户刚改了数据
   *
   * @param source 日志用，标明是哪条心跳触发的
   * @returns 本次实际发出的通知条数
   */
  static async evaluate(ctx: common.Context, source: string): Promise<number> {
    try {
      const s: SentinelSettings = await Sentinel.load(ctx);
      if (!s.enabled) {
        return 0;
      }
      if (!await Notifier.isEnabled()) {
        // ⚠ 这里必须留日志。原来是一声不响 return 0：授权没给时，卡片心跳、前台评估
        //   全部"跑了但什么都没发生"，日志里连一行都看不到 —— 于是排查方向会跑偏到
        //   "心跳没触发""卡片没恢复""去重表坏了"，而真相是少了一次授权。
        Log.w(`哨兵评估(${source}) 跳过：通知未授权`);
        return 0;
      }
      const now: number = Date.now();
      // 免打扰：静默时段完全不打扰。跳过的这批不会补发 ——
      // 因为档位是"剩余时长"推出来的，出了静默时段自然会对上新档位。
      if (Sentinel.inQuiet(now, s)) {
        Log.i(`哨兵评估(${source}) 处在免打扰时段，本次不打扰`);
        return 0;
      }

      const nodes: EventNode[] = await EventRepo.allPending();
      const sent: string[] = await Sentinel.loadSent(ctx);
      let fired: number = 0;

      for (let i: number = 0; i < nodes.length; i++) {
        const node: EventNode = nodes[i];
        const left: number = node.happenAt - now;
        if (left <= 0) {
          // 逾期未完成 —— 这才是"可能真的错过"的那一类，值得单独说一句
          const pKey: string = `${node.id}:past`;
          if (sent.indexOf(pKey) >= 0) {
            continue;
          }
          const pMeta: EventTypeMeta = getEventTypeMeta(node.type);
          const pText: string = `${pMeta.label} · 原定 ${fmtDateTime(node.happenAt)}，还没标记完成`;
          if (await Notifier.publishNow(100 + node.id, node.title, pText, '灯塔 · 节奏哨兵')) {
            sent.push(pKey);
            fired = fired + 1;
          }
          continue;
        }

        const bucket: string = Sentinel.bucketOf(left, s.leadHours);
        if (bucket.length === 0) {
          continue;
        }
        const key: string = `${node.id}:${bucket}`;
        if (sent.indexOf(key) >= 0) {
          continue;
        }
        const meta: EventTypeMeta = getEventTypeMeta(node.type);
        const text: string = `${meta.label} · ${Sentinel.bucketText(bucket, node.happenAt, now)}`;
        if (await Notifier.publishNow(node.id, node.title, text, '灯塔 · 节奏哨兵')) {
          sent.push(key);
          fired = fired + 1;
          Log.i(`哨兵(${source}) 提醒 ${node.title} 档位=${bucket}`);
        }
      }

      if (fired > 0) {
        await Sentinel.saveSent(ctx, sent);
      }
      Log.i(`哨兵评估(${source}) 完成，发出 ${fired} 条，去重表 ${sent.length} 条`);
      return fired;
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`哨兵评估(${source}) 异常：${err.message}`);
      return 0;
    }
  }

  /**
   * 剩余时长 → 提醒档位。
   *
   * 为什么要分档而不是"到了提前量就发一条"：
   * 心跳是 30 分钟一次，用"临界值"判断会漏（这一跳还没到、下一跳已经过了）。
   * 分档后每一档只发一次，30 分钟的抖动就不影响正确性 —— 顶多晚半小时，
   * 而"还有不到 6 小时"这句话本身也不承诺分钟级精度。
   */
  private static bucketOf(msLeft: number, leadHours: number): string {
    if (leadHours >= 1 && msLeft <= HOUR) {
      return 'h1';
    }
    if (leadHours >= 6 && msLeft <= 6 * HOUR) {
      return 'h6';
    }
    if (leadHours >= 24 && msLeft <= DAY) {
      return 'd1';
    }
    if (leadHours >= 48 && msLeft <= 2 * DAY) {
      return 'd2';
    }
    return '';
  }

  private static bucketText(bucket: string, happenAt: number, now: number): string {
    if (bucket === 'h1') {
      return `${humanDeadline(happenAt)} · ${countdownText(happenAt, now)}`;
    }
    if (bucket === 'h6') {
      return `${humanDeadline(happenAt)} · 还有不到 6 小时`;
    }
    if (bucket === 'd1') {
      return `${humanDeadline(happenAt)} · 还有不到 24 小时`;
    }
    return `${humanDeadline(happenAt)} · 还有不到 2 天`;
  }

  private static async loadSent(ctx: common.Context): Promise<string[]> {
    try {
      const raw: string | undefined = await KvRepo.get(K_SENT);
      if (raw === undefined || raw.length === 0) {
        return [];
      }
      const parsed: string[] = JSON.parse(raw) as string[];
      return parsed === undefined || parsed === null ? [] : parsed;
    } catch (e) {
      Log.w('去重记录损坏，按空处理（可能重发一次）');
      return [];
    }
  }

  private static async saveSent(ctx: common.Context, sent: string[]): Promise<void> {
    const capped: string[] = sent.length > SENT_CAP ? sent.slice(sent.length - SENT_CAP) : sent;
    try {
      await KvRepo.put(K_SENT, JSON.stringify(capped));
    } catch (e) {
      Log.w('去重记录落盘失败');
    }
  }

  /* ==================== ② 系统代理提醒：需要资质，失败即降级 ==================== */

  /**
   * 对齐系统代理提醒的排程。可重复调用：内部按「节点 + 档位」差分，只有变化才动系统。
   *
   * ⚠ 本机（模拟器 + 未申请配额）实测全部被拒 1700002，这是**管控配额为 0**，
   *   不是参数问题 —— 详见 diagnose()。所以这个函数的返回里带 failed 计数，
   *   UI 必须如实显示降级，不能假装排上了。
   */
  static async sync(ctx: common.Context): Promise<SentinelReport> {
    const rep: SentinelReport = new SentinelReport();
    if (Sentinel.busy) {
      rep.message = '正在同步…';
      return rep;
    }
    Sentinel.busy = true;
    try {
      const s: SentinelSettings = await Sentinel.load(ctx);
      rep.enabled = s.enabled;

      if (!s.enabled) {
        const n: number = await Sentinel.cancelPlanned(ctx);
        rep.cancelled = n;
        rep.message = n > 0 ? `哨兵已关闭，撤下 ${n} 条系统提醒` : '哨兵已关闭';
        Log.i(`哨兵同步：关闭状态，撤下 ${n} 条`);
        return rep;
      }

      const on: boolean = await Notifier.isEnabled();
      rep.permission = on;
      if (!on) {
        rep.message = '通知未授权，提醒发不出来';
        Log.w('哨兵同步中止：通知未授权');
        return rep;
      }

      const now: number = Date.now();
      const all: EventNode[] = await EventRepo.allPending();
      const nodes: EventNode[] = [];
      for (let i: number = 0; i < all.length; i++) {
        const n: EventNode = all[i];
        if (n.happenAt > now && n.happenAt - now <= HORIZON && nodes.length < MAX_NODES) {
          nodes.push(n);
        }
      }

      const systemWishes: Wish[] = [];
      for (let i: number = 0; i < nodes.length; i++) {
        Sentinel.planNode(nodes[i], s, now, systemWishes, rep);
      }

      const prev: PlannedReminder[] = await Sentinel.loadPlan();
      const prevByKey: Map<string, PlannedReminder> = new Map<string, PlannedReminder>();
      for (let i: number = 0; i < prev.length; i++) {
        prevByKey.set(prev[i].key, prev[i]);
      }

      const next: PlannedReminder[] = [];
      const used: string[] = [];
      const budget: number = Math.min(systemWishes.length, MAX_REMINDERS);
      for (let i: number = 0; i < budget; i++) {
        const w: Wish = systemWishes[i];
        const old: PlannedReminder | undefined = prevByKey.get(w.key);
        if (old !== undefined && old.at === w.at) {
          next.push(old);
          used.push(w.key);
          rep.kept = rep.kept + 1;
          continue;
        }
        if (old !== undefined) {
          await Sentinel.cancelOne(old.reminderId);
          rep.cancelled = rep.cancelled + 1;
        }
        const rid: number = await Sentinel.publish(w);
        if (rid > 0) {
          next.push(new PlannedReminder(w.key, rid, w.at));
          used.push(w.key);
          rep.planned = rep.planned + 1;
        } else {
          rep.failed = rep.failed + 1;
        }
      }

      for (let i: number = 0; i < prev.length; i++) {
        if (used.indexOf(prev[i].key) < 0) {
          await Sentinel.cancelOne(prev[i].reminderId);
          rep.cancelled = rep.cancelled + 1;
        }
      }
      await Sentinel.savePlan(next);
      rep.total = next.length;

      // 系统拒绝排程时自检，把原因落到日志里 + 喂给 UI。
      //
      // 自检本体（读一遍系统已排列表 + 发一条倒计时探针）开销不小，进程内只真跑一次；
      // 但**结论要缓存下来反复回显** —— 否则用户第二次点「立刻评估提醒」时，
      // 失败原因那一行会突然消失，看起来就像"这次成功了"，
      // 而这恰恰是最不能出现的误导（用户会真的错过面试）。
      if (rep.failed > 0) {
        if (Sentinel.diagnosis.length === 0) {
          Sentinel.diagnosis = await Sentinel.diagnose();
        }
        rep.diagnose = Sentinel.diagnosis;
      }
      // ★ 还要**落库**。
      //   rep 只活在这一次调用的返回值里，而 UI 上的「降级提示」是靠
      //   「用户刚好在这一次交互里拿到 rep」才显示出来的。
      //   实际走查发现：应用一启动就会自动 sync 一次（onForeground），那次的 rep 没人接收，
      //   于是用户**进「我的」页时 sFailed 还是 0，降级提示根本不显示** ——
      //   日志里写着"代理提醒不可用"，界面上却一片祥和。
      //   这比排不上提醒更糟：用户以为会被提醒。
      await Sentinel.saveAgentStatus(rep.failed, rep.diagnose);

      if (rep.failed > 0) {
        rep.message = `系统代理提醒不可用（${rep.failed} 条被拒），已改由卡片心跳+本地通知承担`;
      } else if (rep.planned > 0) {
        rep.message = `已排 ${rep.total} 条系统提醒（新增 ${rep.planned}）`;
      } else {
        rep.message = `系统提醒 ${rep.total} 条已是最新`;
      }
      Log.i(`哨兵同步完成 排${rep.total} 新增${rep.planned} 沿用${rep.kept} 撤${rep.cancelled} ` +
        `失败${rep.failed} 免打扰顺延${rep.dndShifted}`);
      return rep;
    } catch (e) {
      const err: Error = e as Error;
      rep.message = `同步失败：${err.message}`;
      Log.e(`哨兵同步异常：${err.message}`);
      return rep;
    } finally {
      Sentinel.busy = false;
    }
  }

  private static async loadPlan(): Promise<PlannedReminder[]> {
    try {
      const raw: string | undefined = await KvRepo.get(K_PLAN);
      if (raw === undefined || raw.length === 0) {
        return [];
      }
      const parsed: PlannedReminder[] = JSON.parse(raw) as PlannedReminder[];
      return parsed === undefined || parsed === null ? [] : parsed;
    } catch (e) {
      Log.w('排程记录损坏，按空处理（会重排一次）');
      return [];
    }
  }

  private static async savePlan(plan: PlannedReminder[]): Promise<void> {
    try {
      await KvRepo.put(K_PLAN, JSON.stringify(plan));
    } catch (e) {
      Log.w('排程记录落盘失败');
    }
  }

  /** 系统里当前排着几条（UI 回显用） */
  static async plannedCount(ctx: common.Context): Promise<number> {
    const plan: PlannedReminder[] = await Sentinel.loadPlan();
    return plan.length;
  }

  /**
   * 把「代理提醒能不能用」这件事落库。
   *
   * 为什么要落库而不是只留在返回值里：后台那次自动 sync（onForeground）的 rep 没有任何人接收，
   * 用户进页面时拿不到它，于是**降级提示压根不显示**。落库之后 reloadSentinel() 每次都能读回来。
   * 成功排上（failed=0）时也照样写入，等于把上一次的告警清掉。
   */
  private static async saveAgentStatus(failed: number, diagnose: string): Promise<void> {
    const map: Record<string, string> = {};
    map[K_AGENT_FAILED] = `${failed}`;
    map[K_AGENT_DIAG] = diagnose;
    try {
      await KvRepo.putAll(map);
    } catch (e) {
      const err: Error = e as Error;
      Log.w(`代理提醒状态落库失败：${err.message}`);
    }
  }

  /** 读回最近一次代理提醒的成败（UI 进页面时回显用） */
  static async agentStatus(ctx: common.Context): Promise<SentinelReport> {
    const r: SentinelReport = new SentinelReport();
    try {
      const kv: Record<string, string> = await KvRepo.getAll();
      r.failed = Sentinel.num(kv, K_AGENT_FAILED, 0);
      const d: string | undefined = kv[K_AGENT_DIAG];
      r.diagnose = d === undefined ? '' : d;
    } catch (e) {
      const err: Error = e as Error;
      Log.w(`代理提醒状态读取失败：${err.message}`);
    }
    return r;
  }

  /** 撤下全部系统提醒（关掉哨兵 / 重置演示数据时用） */
  static async cancelPlanned(ctx: common.Context): Promise<number> {
    const plan: PlannedReminder[] = await Sentinel.loadPlan();
    let n: number = 0;
    for (let i: number = 0; i < plan.length; i++) {
      if (await Sentinel.cancelOne(plan[i].reminderId)) {
        n = n + 1;
      }
    }
    await Sentinel.savePlan([]);
    return n;
  }

  private static async cancelOne(reminderId: number): Promise<boolean> {
    try {
      await reminderAgentManager.cancelReminder(reminderId);
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      // 1700003 = 提醒不存在（用户手动清了或被系统回收），不算失败
      Log.w(`撤销代理提醒 ${reminderId} 失败 code=${err.code}`);
      return false;
    }
  }

  /** 把一个节点翻译成 0~2 条系统提醒 */
  private static planNode(node: EventNode, s: SentinelSettings, now: number,
    system: Wish[], rep: SentinelReport): void {
    const meta: EventTypeMeta = getEventTypeMeta(node.type);
    const abs: string = fmtDateTime(node.happenAt);

    const mainRaw: number = node.happenAt - s.leadHours * HOUR;
    // 提醒时刻已经过了（节点是刚录进来的）：系统来不及调度，这一档交给本地通知
    if (mainRaw > now + IMMEDIATE_WINDOW) {
      const at: number = Sentinel.quietShift(mainRaw, s, node.happenAt);
      if (at !== mainRaw) {
        rep.dndShifted = rep.dndShifted + 1;
      }
      system.push(new Wish(Sentinel.planKey(node.id, 0), at, 0, node.id, node.title,
        `${meta.label} · ${abs}`));
    }

    if (!s.twoStage) {
      return;
    }
    // 二次提醒只给「真的要准时到场」的两类：面试、笔试。投递截止提前 1 小时没意义。
    if (node.type !== EventType.INTERVIEW && node.type !== EventType.WRITTEN) {
      return;
    }
    const secondRaw: number = node.happenAt - SECOND_LEAD_HOURS * HOUR;
    if (secondRaw <= now + IMMEDIATE_WINDOW) {
      return;
    }
    const at2: number = Sentinel.quietShift(secondRaw, s, node.happenAt);
    if (at2 !== secondRaw) {
      rep.dndShifted = rep.dndShifted + 1;
    }
    system.push(new Wish(Sentinel.planKey(node.id, 1), at2, 1, node.id, `${node.title} · 1 小时后开始`,
      `${meta.label} · ${abs}`));
  }

  /**
   * 免打扰顺延。
   *
   * 凌晨 3 点弹一条"9 点有笔试"不但没用，还会让人把通知整个关掉 ——
   * 那才是哨兵真正的失败。所以落在静默时段的提醒整体推到静默结束，
   * 但**不允许推到事件之后**（晚了就不如按原时刻提醒）。
   */
  private static quietShift(at: number, s: SentinelSettings, happenAt: number): number {
    if (!s.dndEnabled || s.dndStart === s.dndEnd) {
      return at;
    }
    if (!Sentinel.hourInQuiet(new Date(at).getHours(), s)) {
      return at;
    }
    const out: Date = new Date(at);
    out.setHours(s.dndEnd, 0, 0, 0);
    if (out.getTime() <= at) {
      out.setDate(out.getDate() + 1);
    }
    const shifted: number = out.getTime();
    return shifted < happenAt ? shifted : at;
  }

  private static hourInQuiet(h: number, s: SentinelSettings): boolean {
    return s.dndStart < s.dndEnd
      ? (h >= s.dndStart && h < s.dndEnd)
      : (h >= s.dndStart || h < s.dndEnd);
  }

  private static inQuiet(ts: number, s: SentinelSettings): boolean {
    if (!s.dndEnabled || s.dndStart === s.dndEnd) {
      return false;
    }
    return Sentinel.hourInQuiet(new Date(ts).getHours(), s);
  }

  private static planKey(nodeId: number, stage: number): string {
    return `${nodeId}:${stage}`;
  }

  /** 把一条提醒交给系统。返回 reminderId，失败返回 -1。 */
  private static async publish(w: Wish): Promise<number> {
    if (w.at <= Date.now()) {
      Log.w(`提醒时刻已过，放弃排程 key=${w.key}`);
      return -1;
    }
    const d: Date = new Date(w.at);
    const req: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: d.getFullYear(),
        month: d.getMonth() + 1,
        day: d.getDate(),
        hour: d.getHours(),
        minute: d.getMinutes(),
        second: 0
      },
      title: w.title,
      content: w.content,
      expiredContent: `${w.title} 的时间已过`,
      // 通知栏里的 id 必须唯一，否则同一档位的多条提醒会互相覆盖
      notificationId: 9100 + w.stage * 1000 + (w.nodeId % 1000),
      slotType: notification.SlotType.SOCIAL_COMMUNICATION,
      wantAgent: {
        pkgName: BUNDLE,
        abilityName: ABILITY,
        parameters: {
          'lh_target': NAV_MAP
        }
      },
      tapDismissed: true
    };
    try {
      const id: number = await reminderAgentManager.publishReminder(req);
      Log.i(`代理提醒已排 id=${id} key=${w.key} at=${fmtDateTime(w.at)} title=${w.title}`);
      return id;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      // 1700001 没授权 / 1700002 配额为 0 或超限 —— 两种都要让用户看见，不能吞
      Log.e(`代理提醒排程失败 key=${w.key} code=${err.code} msg=${err.message}`);
      return -1;
    }
  }

  /**
   * 排程被拒时的自检。
   *
   * 1700002「数量超限」这个报错有个坑：它不告诉你配额是多少、已占几条，只丢一句"超限"。
   * 本机实测在**一条都没排进去**的情况下也报这个错 —— 只看报错很容易往
   * "是不是我排太多"的方向查（而代码里已经限到 14 条了）。
   * 所以这里把系统里的真实状态拉出来，再用一条最短的倒计时提醒做探针：
   *   探针成功 → 是日历参数的问题；
   *   探针同样被拒 → 是这台设备/这个应用没有代理提醒配额，跟传什么无关。
   *
   * 官方错误码文档给出的原因是「因管控限制，当前应用可用提醒数量为 0，
   * 不能使用代理提醒」，处理步骤是「通过邮件形式申请代理提醒的使用权限」。
   */
  static async diagnose(): Promise<string> {
    const parts: string[] = [];
    try {
      const valid: reminderAgentManager.ReminderRequest[] =
        await reminderAgentManager.getValidReminders();
      parts.push(`系统内已有 ${valid.length} 条`);
      for (let i: number = 0; i < valid.length; i++) {
        Log.w(`  已存在提醒 #${i} type=${valid[i].reminderType} title=${valid[i].title}`);
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      parts.push(`读取已排提醒失败 code=${err.code}`);
    }

    const probe: reminderAgentManager.ReminderRequestTimer = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
      triggerTimeInSeconds: 300,
      title: '灯塔自检',
      content: '看到这条说明本机代理提醒可用',
      notificationId: 9900,
      slotType: notification.SlotType.SOCIAL_COMMUNICATION
    };
    try {
      const id: number = await reminderAgentManager.publishReminder(probe);
      parts.push(`探针排程成功 id=${id}`);
      await reminderAgentManager.cancelReminder(id);
      parts.push('探针已撤销');
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      parts.push(`探针同样被拒 code=${err.code}`);
    }
    const msg: string = parts.join('；');
    Log.w(`代理提醒自检：${msg}`);
    return msg;
  }

  /** 预览：把将会发出的提醒列出来（UI 展示用，不碰系统） */
  static async preview(ctx: common.Context): Promise<string[]> {
    const s: SentinelSettings = await Sentinel.load(ctx);
    const now: number = Date.now();
    const all: EventNode[] = await EventRepo.allPending();
    const out: string[] = [];
    let count: number = 0;
    for (let i: number = 0; i < all.length && count < MAX_NODES; i++) {
      const node: EventNode = all[i];
      if (node.happenAt <= now) {
        out.push(`${node.title} · 已逾期，等你标记`);
        continue;
      }
      count = count + 1;
      const bucket: string = Sentinel.bucketOf(node.happenAt - now, s.leadHours);
      const when: string = Sentinel.bucketText(bucket.length > 0 ? bucket : 'd1', node.happenAt, now);
      out.push(bucket.length > 0 ? `${node.title} · ${when}（该发了）` : `${node.title} · 还早`);
    }
    return out;
  }
}
