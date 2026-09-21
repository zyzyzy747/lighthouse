import { EventNode, getEventTypeMeta } from '../common/Types';
import { EventRepo } from '../repository/EventRepo';
import { Log } from '../common/Logger';
import { pad2 } from '../common/Utils';

/**
 * 桌面卡片的数据装配层。
 *
 * 为什么要有这一层：ArkTS 卡片的 UI 文件（widget/pages/*.ets）是**独立编译单元**，
 * 不能 import 应用里的 Repo / Types / Theme。它能拿到的只有 FormExtensionAbility
 * 通过 formBindingData 喂进去的 `Record<string, string>`。
 *
 * 所以职责边界是：
 *   查库、算倒计时、拼文案  →  这里（可自由用应用代码）
 *   摆放、配色、点击        →  卡片 UI（只认字符串和资源）
 *
 * ⚠ 卡片进程与 UIAbility 不共享内存，FormExtensionAbility 需要自己 init 一次 RDB。
 */

const MIN_MS: number = 60 * 1000;
const HOUR_MS: number = 60 * MIN_MS;
const DAY_MS: number = 24 * HOUR_MS;

/** 紧急度分档。卡片 UI 拿这个语义值去映射颜色资源，不要在这里传死 hex。 */
const LEVEL_PAST: string = 'past';
const LEVEL_URGENT: string = 'urgent';   // < 6 小时
const LEVEL_SOON: string = 'soon';       // < 48 小时
const LEVEL_NORMAL: string = 'normal';

export class WidgetData {
  /**
   * 组装卡片数据。
   * 永远返回一份可直接渲染的数据 —— 查库失败时返回「空态」而不是抛错，
   * 否则卡片会白屏，比显示"暂无节点"难看得多。
   */
  static async build(now: number = Date.now()): Promise<Record<string, string>> {
    let nodes: EventNode[] = [];
    try {
      nodes = await EventRepo.allPending();
    } catch (e) {
      const err = e as Error;
      Log.e(`WidgetData 查库失败，回落空态：${err.message}`);
      return WidgetData.empty(`读取失败`);
    }

    const past: EventNode[] = [];
    const future: EventNode[] = [];
    for (let i: number = 0; i < nodes.length; i++) {
      if (nodes[i].happenAt < now) {
        past.push(nodes[i]);
      } else {
        future.push(nodes[i]);
      }
    }

    // 主位：优先显示最近一个未发生的节点；全都逾期了才退而显示最后一个逾期的
    let prime: EventNode | undefined = undefined;
    if (future.length > 0) {
      prime = future[0];
    } else if (past.length > 0) {
      prime = past[past.length - 1];
    }

    if (prime === undefined) {
      return WidgetData.empty('等待第一个节点');
    }

    const out: Record<string, string> = {
      'empty': '0',
      'total': `${nodes.length}`,
      'overdue': `${past.length}`,
      'overdueText': past.length > 0 ? `${past.length} 个节点已逾期` : '',
      'head': past.length > 0
        ? `${nodes.length} 个节点在等 · ${past.length} 个已逾期`
        : `${nodes.length} 个节点在等`,
      'stamp': WidgetData.stamp(now),

      'primeTitle': prime.title.length > 0 ? prime.title : '未命名节点',
      'primeType': getEventTypeMeta(prime.type).label,
      'primeWhen': WidgetData.whenText(prime.happenAt, now),
      'primeBig': WidgetData.bigOf(prime.happenAt, now),
      'primeUnit': WidgetData.unitOf(prime.happenAt, now),
      'primeLeft': WidgetData.leftText(prime.happenAt, now),
      'primeLevel': WidgetData.levelOf(prime.happenAt, now),

      // 次要两行：主位之后的节点，最多两条
      'sub1': WidgetData.subLine(future, 1, past, now),
      'sub2': WidgetData.subLine(future, 2, past, now),
      'more': future.length > 3 ? `还有 ${future.length - 3} 个` : ''
    };
    return out;
  }

  /** 空态数据：卡片显示引导语，而不是一片空白 */
  static empty(head: string): Record<string, string> {
    const out: Record<string, string> = {
      'empty': '1',
      'total': '0',
      'overdue': '0',
      'overdueText': '',
      'head': head,
      'stamp': WidgetData.stamp(Date.now()),

      'primeTitle': '还没有关键节点',
      'primeType': '提示',
      'primeWhen': '点右下角 ＋ 记一笔',
      'primeBig': '—',
      'primeUnit': '',
      'primeLeft': '投递后随手加个截止日，哨兵就会替你盯着',
      'primeLevel': LEVEL_NORMAL,

      'sub1': '',
      'sub2': '',
      'more': ''
    };
    return out;
  }

  /** HH:mm，用于卡片上标出数据新鲜度，也方便验证"到底刷没刷" */
  private static stamp(now: number): string {
    const d: Date = new Date(now);
    return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  }

  /** 大字数值。⚠ 定时刷新最快 30 分钟一次，所以只精确到「天/小时」，绝不给到分钟以下。 */
  private static bigOf(ts: number, now: number): string {
    const ms: number = ts - now;
    if (ms <= 0) {
      return '—';
    }
    const days: number = Math.floor(ms / DAY_MS);
    if (days >= 1) {
      return `${days}`;
    }
    const hours: number = Math.floor(ms / HOUR_MS);
    if (hours >= 1) {
      return `${hours}`;
    }
    return `${Math.max(Math.floor(ms / MIN_MS), 1)}`;
  }

  private static unitOf(ts: number, now: number): string {
    const ms: number = ts - now;
    if (ms <= 0) {
      return '已逾期';
    }
    const days: number = Math.floor(ms / DAY_MS);
    if (days >= 1) {
      return '天后';
    }
    const hours: number = Math.floor(ms / HOUR_MS);
    if (hours >= 1) {
      return '小时后';
    }
    return '分钟后';
  }

  /** 完整倒计时表述，副标题用 */
  private static leftText(ts: number, now: number): string {
    const ms: number = ts - now;
    if (ms <= 0) {
      return '时间已过，确认一下是否已完成';
    }
    const days: number = Math.floor(ms / DAY_MS);
    if (days >= 1) {
      const hours: number = Math.floor((ms % DAY_MS) / HOUR_MS);
      return `还有 ${days} 天 ${hours} 小时`;
    }
    const hours: number = Math.floor(ms / HOUR_MS);
    return `还有 ${hours} 小时`;
  }

  /** 具体时刻。「今天 14:00」比「0.3 天后」好读得多。 */
  private static whenText(ts: number, now: number): string {
    const d: Date = new Date(ts);
    const clock: string = `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
    const a: number = WidgetData.dayStart(ts);
    const b: number = WidgetData.dayStart(now);
    const diff: number = Math.round((a - b) / DAY_MS);
    if (diff === 0) {
      return `今天 ${clock}`;
    }
    if (diff === 1) {
      return `明天 ${clock}`;
    }
    if (diff === -1) {
      return `昨天 ${clock}`;
    }
    return `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${clock}`;
  }

  private static dayStart(ts: number): number {
    const d: Date = new Date(ts);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  private static levelOf(ts: number, now: number): string {
    const ms: number = ts - now;
    if (ms <= 0) {
      return LEVEL_PAST;
    }
    if (ms < 6 * HOUR_MS) {
      return LEVEL_URGENT;
    }
    if (ms < 48 * HOUR_MS) {
      return LEVEL_SOON;
    }
    return LEVEL_NORMAL;
  }

  /** 次要行：`光庭信息笔试 · 1 天后`。越界返回空串，卡片按空串隐藏该行。 */
  private static subLine(future: EventNode[], idx: number, past: EventNode[], now: number): string {
    if (idx < future.length) {
      const n: EventNode = future[idx];
      return `${WidgetData.whenText(n.happenAt, now)} · ${n.title}`;
    }
    // future 不够两条时，用逾期的补齐 —— 逾期不显示等于鼓励用户无视它
    const need: number = idx - future.length;
    if (need < past.length) {
      const n: EventNode = past[past.length - 1 - need];
      return `已逾期 · ${n.title}`;
    }
    return '';
  }
}
