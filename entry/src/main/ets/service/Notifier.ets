import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent, WantAgent, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';
import { NAV_MAP } from '../common/Nav';

const BUNDLE: string = 'com.wuit.lighthouse';
const ABILITY: string = 'EntryAbility';

/**
 * 通知渠道。
 *
 * 面试 / 笔试这类提醒是「用户自己定的、错过代价高」的信息，用它换横幅与锁屏可见性。
 * ⚠ 槽位语义是审核关注点：真要上架被质疑，改这一行即可，别把 SlotType 散落在各处。
 */
const SLOT: notificationManager.SlotType = notificationManager.SlotType.SOCIAL_COMMUNICATION;

/** 即时通知的 id 段。系统代理提醒走 9100 段，两段隔开避免 id 撞号。 */
const IMMEDIATE_ID_BASE: number = 8000;

/**
 * 通知出口。
 *
 * 两条通道，职责不同：
 *   ① 代理提醒（reminderAgentManager）—— 交给系统排程，到点由系统弹，**应用不需要活着**。
 *      这是「服务找人」的关键：用户关掉应用、锁屏放一晚上，面试提醒照样会响。
 *   ② 即时通知（notificationManager.publish）—— 应用此刻就在前台时的兜底与演示。
 *
 * ⚠ 两条通道都卡在同一个前置条件上：用户的通知授权。没授权时
 *   publishReminder 抛 1700001（Notification is not enabled），
 *   publish 则直接静默无效 —— 报错信息不会告诉你"是没授权"，
 *   很容易被当成"提醒功能写坏了"来排查。所以 Sentinel 每次 sync 都先查一次 isEnabled。
 */
export class Notifier {
  private static clickAgent: WantAgent | undefined = undefined;
  private static slotReady: boolean = false;

  /** 通知总开关是否已由用户打开。 */
  static async isEnabled(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.w(`查询通知开关失败 code=${err.code} msg=${err.message}`);
      return false;
    }
  }

  /**
   * 申请通知授权 —— 全程唯一必须用户点一下的环节（系统会弹对话框）。
   * 只能在拿到 UIAbilityContext 的地方调（页面 / Ability），不要在卡片进程里调。
   */
  static async requestEnable(context: common.UIAbilityContext): Promise<boolean> {
    try {
      await notificationManager.requestEnableNotification(context);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.e(`申请通知授权失败 code=${err.code} msg=${err.message}`);
      return false;
    }
    const on: boolean = await Notifier.isEnabled();
    Log.i(`通知授权结束 enabled=${on}`);
    return on;
  }

  /** 建渠道。幂等，重复调用无害。 */
  static async ensureSlot(): Promise<void> {
    if (Notifier.slotReady) {
      return;
    }
    try {
      await notificationManager.addSlot(SLOT);
      Notifier.slotReady = true;
      Log.i(`通知渠道就绪 slot=${SLOT}`);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.w(`建通知渠道失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 发一条即时通知。点通知会拉起应用并落到作战地图页。
   * @returns 是否发布成功（未授权 / 异常时为 false）
   */
  static async publishNow(id: number, title: string, text: string, extra: string): Promise<boolean> {
    await Notifier.ensureSlot();
    const agent: WantAgent | undefined = await Notifier.agent();
    const req: notificationManager.NotificationRequest = {
      id: IMMEDIATE_ID_BASE + id,
      notificationSlotType: SLOT,
      tapDismissed: true,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text,
          additionalText: extra
        }
      }
    };
    if (agent !== undefined) {
      req.wantAgent = agent;
    }
    try {
      await notificationManager.publish(req);
      Log.i(`即时通知已发出 id=${IMMEDIATE_ID_BASE + id} title=${title}`);
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.e(`即时通知发布失败 code=${err.code} msg=${err.message}`);
      return false;
    }
  }

  /** 撤掉一条即时通知（用户标记完成后调用，免得通知栏留着过期提醒） */
  static async cancelNow(id: number): Promise<void> {
    try {
      await notificationManager.cancel(IMMEDIATE_ID_BASE + id);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.w(`撤销即时通知失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 点击通知的去向。缓存在进程内 —— getWantAgent 是跨进程调用，没必要每条通知都算一次。
   * 返回 undefined 时不挂 wantAgent：通知仍会正常弹出，只是点了不跳页，不该因此不通知。
   */
  private static async agent(): Promise<WantAgent | undefined> {
    if (Notifier.clickAgent !== undefined) {
      return Notifier.clickAgent;
    }
    const want: Want = {
      bundleName: BUNDLE,
      abilityName: ABILITY,
      parameters: {
        'lh_target': NAV_MAP
      }
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      Notifier.clickAgent = await wantAgent.getWantAgent(info);
      return Notifier.clickAgent;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.w(`构造通知跳转失败，本条通知不挂跳转 code=${err.code} msg=${err.message}`);
      return undefined;
    }
  }
}
