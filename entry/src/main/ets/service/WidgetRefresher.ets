import { formProvider } from '@kit.FormKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';

/**
 * 把「应用改了数据」这件事推给桌面卡片。
 *
 * 这是设计文档里点名的那条一致性约定：
 *   App 写库 ──► reloadForms ──► FormExtension 重新读库 ──► 卡片重绘
 * 只在 App 侧更新而不推卡片，桌面就会一直显示过期数据 ——
 * 同类作品最常见的翻车点，也是这个作品里最容易讲清楚"技术深度"的地方。
 *
 * ⚠ reloadForms 从 API 22 起可用，且**仅支持在 UIAbility 中调用**，
 *   所以要传 UIAbilityContext（页面里用 getUIContext().getHostContext() 拿）。
 *
 * ⚠ 没加桌时调用会返回 0 或抛 16501000，这属于正常情况，不要当故障打错误日志。
 */

const MODULE_NAME: string = 'entry';
const FORM_ABILITY: string = 'EntryFormAbility';

/** 与 resources/base/profile/form_config.json 里的 name 字段严格一致 */
export const FORM_MAIN: string = 'rhythm_card';
export const FORM_MINI: string = 'rhythm_mini';

const FORM_NAMES: string[] = [FORM_MAIN, FORM_MINI];

export class WidgetRefresher {
  /**
   * 刷新本应用所有已加桌的卡片。
   * 传入 context 为 undefined 时静默跳过 —— 某些上下文（如无 UI 的 service）拿不到，
   * 此时不该让业务写入失败。
   */
  static async refreshAll(context: common.UIAbilityContext | undefined): Promise<void> {
    if (context === undefined) {
      Log.w('卡片刷新跳过：拿不到 UIAbilityContext');
      return;
    }
    for (let i: number = 0; i < FORM_NAMES.length; i++) {
      const name: string = FORM_NAMES[i];
      try {
        const n: number = await formProvider.reloadForms(context, MODULE_NAME, FORM_ABILITY, name);
        Log.i(`卡片刷新已请求 ${name} 命中 ${n} 张`);
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        Log.w(`卡片刷新未生效 ${name} code=${err.code} msg=${err.message}`);
      }
    }
  }

  /** 从页面上下文取出 UIAbilityContext，失败返回 undefined（不抛） */
  static contextOf(ui: UIContext): common.UIAbilityContext | undefined {
    try {
      const ctx: common.Context | undefined = ui.getHostContext();
      if (ctx === undefined) {
        return undefined;
      }
      return ctx as common.UIAbilityContext;
    } catch (e) {
      const err: Error = e as Error;
      Log.w(`取 UIAbilityContext 失败：${err.message}`);
      return undefined;
    }
  }
}
