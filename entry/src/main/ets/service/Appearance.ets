import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { KvRepo } from '../repository/KvRepo';
import { Log } from '../common/Logger';

/**
 * 外观（日间 / 夜间）。
 *
 * ⚠ 深浅色本身**不由这份代码决定**，由资源限定词决定：
 *   `resources/base/` 是浅色，`resources/dark/` 是深色，系统按当前 colorMode 自己挑。
 *   这里只负责把用户的选择告诉系统（`ApplicationContext.setColorMode`）。
 *   所以整个应用 —— 包括跑在另一个进程的桌面卡片 —— 会一起变，不需要我们手动刷任何颜色。
 *
 * ⚠ setColorMode 是**应用级**设置，不会自己持久化：每次冷启动都要重新设一次，
 *   所以 EntryAbility.onWindowStageCreate 里必须调 apply()，否则用户选的深色下次开机就没了。
 */

/** 数值即存库值。改顺序等于改存量数据，必须同步写迁移。 */
export enum AppearanceMode {
  FOLLOW = 0,
  LIGHT = 1,
  DARK = 2
}

const KEY_MODE: string = 'appearance_mode';

export function appearanceLabel(m: number): string {
  if (m === AppearanceMode.LIGHT) {
    return '浅色';
  }
  if (m === AppearanceMode.DARK) {
    return '深色';
  }
  return '跟随系统';
}

export class Appearance {
  static async load(): Promise<number> {
    try {
      const v: string | undefined = await KvRepo.get(KEY_MODE);
      if (v === undefined) {
        return AppearanceMode.FOLLOW;
      }
      const n: number = Number.parseInt(v);
      // 只认得的值才用；库里要是躺着别的数，退回跟随系统而不是让界面卡在中间态
      if (n === AppearanceMode.LIGHT || n === AppearanceMode.DARK) {
        return n;
      }
      return AppearanceMode.FOLLOW;
    } catch (e) {
      const err: Error = e as Error;
      Log.w(`外观偏好读取失败，按跟随系统处理：${err.message}`);
      return AppearanceMode.FOLLOW;
    }
  }

  /** 冷启动时把上次的选择重新告诉系统。 */
  static async apply(ctx: common.Context): Promise<void> {
    const m: number = await Appearance.load();
    Appearance.applyNow(ctx, m);
  }

  /** 用户在设置里点了某一个 —— 落盘 + 立刻生效。 */
  static async set(ctx: common.Context, m: number): Promise<void> {
    try {
      await KvRepo.put(KEY_MODE, String(m));
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`外观偏好保存失败：${err.message}`);
    }
    Appearance.applyNow(ctx, m);
    Log.i(`外观已切换：${appearanceLabel(m)}`);
  }

  private static applyNow(ctx: common.Context, m: number): void {
    let cm: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (m === AppearanceMode.LIGHT) {
      cm = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (m === AppearanceMode.DARK) {
      cm = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    try {
      ctx.getApplicationContext().setColorMode(cm);
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`设置 colorMode 失败：${err.message}`);
    }
  }
}
