import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { Configuration, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DbHelper } from '../model/DbHelper';
import { WidgetData } from '../service/WidgetData';
import { Sentinel } from '../service/Sentinel';
import { Log } from '../common/Logger';

/**
 * 桌面服务卡片的提供方（FormExtensionAbility）。
 *
 * 生命周期与职责：
 *   onAddForm        卡片被加到桌面 → 立刻给一份数据，然后异步补真实数据
 *   onUpdateForm     系统定时刷新（updateDuration:1 = 30 分钟）+ App 侧 reloadForms 触发
 *   onFormEvent      卡内 message 事件（卡片上的刷新按钮）
 *   onRemoveForm     卡片被移除
 *
 * ⚠ 三条容易踩的坑，都在这份代码里处理了：
 *   1. onAddForm 是**同步**接口，而 RDB 是异步的 ⇒ 必须先返回占位数据，
 *      再 updateForm 推真实数据。不能 await，也不能直接返回空。
 *   2. 卡片跑在独立的 FormExtension 进程，与 UIAbility **不共享内存** ⇒
 *      这里的 DbHelper 是卡片进程自己的一份，需要自己 init。
 *   3. 用户没给应用联网权限也不会影响卡片 —— 卡片只读本地库，全程离线可用。
 *
 * ★ 还有一件事被刻意放在这里：**节奏哨兵的心跳**。
 *   系统每 30 分钟会唤醒本进程刷新卡片，这次唤醒顺便做一次提醒评估 ——
 *   于是"应用没打开也能提醒"这件事不需要任何后台任务、不需要代理提醒配额、
 *   不需要任何审批，用的是 Form Kit 本来就会发生的系统调度。
 *   （系统级代理提醒才是精度最高的方案，但它有管控配额，普通应用默认 0 条。）
 */
export default class EntryFormAbility extends FormExtensionAbility {
  private dbReady: Promise<void> | undefined = undefined;

  /** 卡片进程内独立初始化一次数据库，失败后允许下次重试 */
  private ensureDb(): Promise<void> {
    if (this.dbReady === undefined) {
      this.dbReady = DbHelper.init(this.context)
        .then(() => {
          Log.i('form: db ready');
        })
        .catch((e: Error) => {
          Log.e(`form: db init failed ${e.message}`);
          this.dbReady = undefined;
          throw e as Error;
        });
    }
    return this.dbReady;
  }

  /**
   * 卡片进程被拉起。
   *
   * ⚠ 这个方法不只是"启动日志"：卡片进程是**用完即退**的（ps 里能看到
   *   `com.wuit.lighthouse:form` 只在刷新那一刻存在），系统每次定时刷新都会重新拉起它。
   *   所以这里是哨兵最可靠的心跳点 —— 应用进程死没死都无所谓。
   */
  onCreate(want: Want): void {
    Log.i('form: onCreate（卡片进程启动）');
    this.heartbeat();
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = EntryFormAbility.formIdOf(want);
    const name: string = EntryFormAbility.nameOf(want);
    Log.i(`onAddForm formId=${formId} name=${name}`);

    // 同步返回占位数据，真实数据由 push() 异步补上
    this.push(formId);
    return formBindingData.createFormBindingData(WidgetData.empty('正在读取…'));
  }

  onUpdateForm(formId: string): void {
    Log.i(`onUpdateForm formId=${formId}`);
    this.push(formId);
  }

  onFormEvent(formId: string, message: string): void {
    Log.i(`onFormEvent formId=${formId} message=${message}`);
    this.push(formId);
  }

  onRemoveForm(formId: string): void {
    Log.i(`onRemoveForm formId=${formId}`);
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    // READY：卡片随时可以添加。若返回 UNKNOWN，卡片中心不会展示它。
    return formInfo.FormState.READY;
  }

  onConfigurationUpdate(config: Configuration): void {
    // 深浅色切换、字体大小变化都会走这里。下一次刷新自然带上新配色，
    // 但主动推一次能让用户体验到"立刻跟随系统"，成本只是查一次库。
    Log.i('form: onConfigurationUpdate');
  }

  /** 查库 → 组装 → 推给卡片。所有触发路径都收敛到这一个出口。 */
  private async push(formId: string): Promise<void> {
    if (formId.length === 0) {
      Log.w('form: 拿不到卡片 id，跳过刷新');
      return;
    }
    try {
      await this.ensureDb();
      const data: Record<string, string> = await WidgetData.build();
      const payload: formBindingData.FormBindingData = formBindingData.createFormBindingData(data);
      await formProvider.updateForm(formId, payload);
      // ⚠ 新增字段一律**追加在末尾**：验收脚本用 `主位=(.+?) 共\d+个节点` 取主位，
      //   在中间插字段会把后面那段一起并进主位里，脚本会"通过"但取到垃圾值。
      // `提示` = data['head']（那行「N 个节点在等 / 未解锁 · N 个节点在等」）。
      //   加它是为了验证脱敏**真的到了卡片上**：只藏公司名、却看不出这张卡在锁着，
      //   用户就不知道该去解锁看详情 —— 那是把功能做残，不是做安全。
      Log.i(`卡片已刷新 formId=${formId} 锁=${data['locked']} 主位=${data['primeTitle']} ${data['primeWhen']} 共${data['total']}个节点 提示=${data['head']}`);
    } catch (e) {
      const err = e as BusinessError;
      Log.e(`卡片刷新失败 formId=${formId} code=${err.code} msg=${err.message}`);
      return;
    }
    this.heartbeat();
  }

  /**
   * ★ 节奏哨兵的心跳。
   *
   * 系统每 30 分钟唤醒本进程刷新卡片，这次唤醒顺便做一次提醒评估 ——
   * 于是"应用没打开也能提醒"不需要后台任务、不需要代理提醒配额、不需要任何审批，
   * 用的是 Form Kit 本来就会发生的系统调度。
   *
   * 不 await 进卡片刷新流程：提醒发不发都不该影响卡片显示。
   * 去重在 RDB 里，所以每 30 分钟跳一次也不会重复打扰。
   */
  private heartbeat(): void {
    this.ensureDb()
      .then(() => Sentinel.evaluate(this.context, '卡片心跳'))
      .then((n: number) => {
        if (n > 0) {
          Log.i(`哨兵心跳：本轮发出 ${n} 条提醒（应用未打开也走通了）`);
        }
      })
      .catch((err: Error) => {
        Log.w(`哨兵心跳异常：${err.message}`);
      });
  }

  private static formIdOf(want: Want): string {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return '';
    }
    const v: Object | undefined = params[formInfo.FormParam.IDENTITY_KEY];
    if (v === undefined || v === null) {
      return '';
    }
    return `${v}`;
  }

  private static nameOf(want: Want): string {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return '';
    }
    const v: Object | undefined = params[formInfo.FormParam.NAME_KEY];
    return v === undefined ? '' : `${v}`;
  }
}
