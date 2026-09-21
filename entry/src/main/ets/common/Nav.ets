import { Log } from './Logger';

/**
 * 外部入口带来的导航意图。
 *
 * 场景：用户在桌面点卡片的「＋」，系统以 router 事件拉起 EntryAbility 并带上参数，
 * 但此时 UI 可能① 还没创建，② 已经在后台（只走 onNewWant，页面不重建）。
 * 两种情况都要能落到正确的页面，所以用 AppStorage 做一条 UI 无关的通道：
 *
 *   EntryAbility(onCreate / onNewWant) → pushNavTarget() → AppStorage
 *   Index(@StorageLink + @Watch)       → 消费后清空
 *
 * 为什么不用静态变量：UIAbility 与页面虽同进程，但静态变量不具备响应式，
 * 页面已经在后台时不会重新执行 aboutToAppear，意图就丢了。
 */

export const NAV_KEY: string = 'lhNavTarget';

/** 默认首页（作战地图） */
export const NAV_HOME: string = 'home';
/** 投递快记 */
export const NAV_QUICK: string = 'quick';
/** 作战地图 */
export const NAV_MAP: string = 'map';
/** 面试复盘 */
export const NAV_REVIEW: string = 'review';

export const NAV_VALUES: string[] = [NAV_HOME, NAV_QUICK, NAV_MAP, NAV_REVIEW];

export function pushNavTarget(target: string): void {
  if (target.length === 0) {
    return;
  }
  let known: boolean = false;
  for (let i: number = 0; i < NAV_VALUES.length; i++) {
    if (NAV_VALUES[i] === target) {
      known = true;
      break;
    }
  }
  if (!known) {
    Log.w(`未知的导航意图，忽略：${target}`);
    return;
  }
  AppStorage.setOrCreate(NAV_KEY, target);
  Log.i(`导航意图已入队：${target}`);
}

/** 从 want 里取出 lh_target 并转为导航意图。返回是否命中。 */
export function navTargetOf(params: Record<string, Object> | undefined): string {
  if (params === undefined) {
    return '';
  }
  const v: Object | undefined = params['lh_target'];
  if (v === undefined || v === null) {
    return '';
  }
  return `${v}`;
}
