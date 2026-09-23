import { promptAction } from '@kit.ArkUI';
import { formProvider } from '@kit.FormKit';
import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Palette, Metrics } from '../common/Theme';
import { ApplicationRepo, FunnelStat } from '../repository/ApplicationRepo';
import { ReviewRepo } from '../repository/ReviewRepo';
import { EventRepo } from '../repository/EventRepo';
import { DbHelper } from '../model/DbHelper';
import { DemoData } from '../service/DemoData';
import { DeepSeekClient } from '../service/DeepSeekClient';
import { WidgetRefresher, FORM_MAIN, FORM_MINI } from '../service/WidgetRefresher';
import { Sentinel, SentinelSettings, SentinelReport, LEAD_CHOICES, leadLabel } from '../service/Sentinel';
import { Appearance, AppearanceMode, appearanceLabel } from '../service/Appearance';
import { KvRepo } from '../repository/KvRepo';
import { AvatarStore } from '../service/AvatarStore';
import { Notifier } from '../service/Notifier';
import { AiResult, ChatMessage } from '../common/AiTypes';
import { Log } from '../common/Logger';

/** @Styles 只能用通用属性 */
@Styles
function panel() {
  .padding(14)
  .backgroundColor(Palette.PANEL)
  .borderRadius(Metrics.CARD_RADIUS)
  .width('100%')
}

/** 统计行：宽度铺满 + 上下留白 */
@Styles
function kvRowBox() {
  .width('100%')
  .padding({ top: 7, bottom: 7 })
}

/** ⚠ fontColor/fontSize 是 Text 专有属性，必须走 @Extend(Text) */
@Extend(Text)
function pvCardHead() {
  .fontSize(13)
  .fontColor(Palette.TX_3)
  .width('100%')
}

@Extend(Text)
function kvLabel() {
  .fontSize(13.5)
  .fontColor(Palette.TX_2)
}

@Extend(Text)
function kvValue() {
  .fontSize(13.5)
  .fontWeight(FontWeight.Medium)
}

/** ⚠ placeholderColor/fontSize 是 TextInput 专有属性 */
@Extend(TextInput)
function pvField() {
  .backgroundColor(Palette.PANEL_2)
  .borderRadius(Metrics.CHIP_RADIUS)
  .fontSize(14)
  .fontColor(Palette.TX)
  .placeholderColor(Palette.TX_3)
  .height(44)
}

/**
 * 设置页。
 *
 * 从「我的」拆出来的：原来一页塞了档案、数据、AI、哨兵、卡片、演示数据、关于、危险操作
 * 八块共 994 行 —— 想改个提醒提前量，得先滚过一屏无关信息。
 * 现在「我的」只回答"我是谁 / 我这阵子投得怎么样"，**所有开关都收在这里**。
 *
 * ⚠ 踩坑记录（务必保留这个写法）：
 * ArkUI V1 的 @Builder **按值传参不会建立响应式依赖** ——
 * 形如 `this.kvRow('投递记录', `${this.funnel.total} 条`, c)` 的写法，
 * @State funnel 变化后 Builder 内的文字**不会刷新**（组件重建时才更新，
 * 表现为"点完按钮数字不动，切走再切回才对"）。
 * 因此所有动态数字一律用 @Extend 属性 + 内联 Row 输出，不走带参 @Builder。
 */
@Component
export struct SettingsView {
  @Prop @Watch('onTick') tick: number = 0;
  onChanged: () => void = (): void => {};
  /** 返回「我的」。设置页是二级页，不占底部 Tab —— 底部只有四个主场景。 */
  onBack: () => void = (): void => {};

  @State funnel: FunnelStat = new FunnelStat();
  @State reviewCount: number = 0;
  @State analyzed: number = 0;
  @State pendingNodes: number = 0;
  @State busy: boolean = false;

  /* ---- 节奏哨兵 ----
   * ⚠ 这些偏好刻意用**独立的基础类型 @State**，不塞进 SentinelSettings 实例：
   *   对象成员的变化能不能触发刷新取决于框架对 class 的一层观测，
   *   而布尔/数字是确定会刷的。这个坑在本页已经踩过一次（见文件头 @Builder 那段），
   *   能避就避。
   */
  @State sEnabled: boolean = true;
  @State sLead: number = 24;
  @State sTwoStage: boolean = true;
  @State sDnd: boolean = true;
  @State sDndStart: number = 22;
  @State sDndEnd: number = 8;
  @State sPermission: boolean = false;   // 系统通知是否已授权
  @State sTotal: number = 0;             // 系统里当前排着的提醒数
  @State sPreview: string[] = [];        // 将会排出的提醒预览
  @State sSyncing: boolean = false;
  @State sLastMessage: string = '';
  /** 系统代理提醒被拒的条数。>0 表示本机不支持，界面要如实说降级，不能假装排上了。 */
  @State sFailed: number = 0;
  @State sDiagnose: string = '';
  /** 宽屏双栏。⚠ @StorageProp 的参数必须写字面量（编译期求值），不能传常量变量 */
  @StorageProp('lhTwoPane') twoPane: boolean = false;

  /* ---- 外观 ---- */
  @State apMode: number = 0;

  /* ---- 本地档案 ----
   * 放在设置页顶部，是为了给「本地账号」留位置：等登录做进来，这一块就是账号信息区。
   * 现在它先承担一件当下的事 —— 记住"我是谁、我要投什么"，让个人页不再是匿名数字。
   */
  @State pfName: string = '';
  @State pfTarget: string = '';
  @State pfEditing: boolean = false;
  /** 自定义头像 uri（空串 = 默认头像）与"换图进行中"闸门 */
  @State avatarSrc: string = '';
  @State avatarHasCustom: boolean = false;
  @State avatarBusy: boolean = false;

  /* ---- AI 设置相关 ---- */
  @State aiReady: boolean = false;       // 云端是否可用（有 key 且开关打开）
  @State aiAllowed: boolean = true;      // 用户是否允许联网
  @State aiKeyTail: string = '';         // 密钥尾号，仅用于回显确认
  @State aiSource: string = '';          // 密钥来源说明
  @State showKeyInput: boolean = false;
  @State keyInput: string = '';
  @State testing: boolean = false;
  @State testResult: string = '';
  @State testOk: boolean = false;

  aboutToAppear(): void {
    // 兜一层竞态：EntryAbility.onCreate 里的 load() 是异步的。若用户在启动瞬间就切到本页，
    // syncAiState() 会看到还没读进来的空 key，界面误报「未配置密钥」。
    // 这里幂等地再读一次（只是读 preferences，开销可忽略），读完再刷新。
    const ctx: common.Context | undefined = this.uiContext();
    if (ctx === undefined) {
      this.reload();
      return;
    }
    DeepSeekClient.get().load(ctx)
      .then(() => {
        this.reload();
      })
      .catch((err: Error) => {
        Log.w(`AI 偏好重载失败，沿用现有状态：${err.message}`);
        this.reload();
      });
  }

  onTick(): void {
    this.reload();
  }

  private uiContext(): common.Context | undefined {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    return ctx;
  }

  private syncAiState(): void {
    const c: DeepSeekClient = DeepSeekClient.get();
    this.aiReady = c.isCloudEnabled();
    this.aiAllowed = c.isCloudAllowed();
    this.aiKeyTail = c.keyTail();
    if (!c.hasKey()) {
      this.aiSource = '未配置密钥，当前使用本地引擎';
    } else if (this.aiKeyTail.length > 0) {
      this.aiSource = `密钥尾号 ${this.aiKeyTail}`;
    } else {
      this.aiSource = '密钥已配置';
    }
  }

  private async reload(): Promise<void> {
    try {
      this.funnel = await ApplicationRepo.funnel();
      this.reviewCount = await ReviewRepo.count();
      this.analyzed = await ReviewRepo.analyzedCount();
      this.pendingNodes = await EventRepo.pendingCount();
      this.syncAiState();
      await this.reloadAppearance();
      await this.reloadProfile();
      await this.reloadSentinel();
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`SettingsView reload failed: ${err.message}`);
    }
  }

  /* ==================== 外观 ==================== */

  private async reloadAppearance(): Promise<void> {
    // 读的是库里存的偏好，不是"当前实际是深还是浅" ——
    // 跟随系统时两者会不一样，界面上要显示的是用户的选择。
    this.apMode = await Appearance.load();
  }

  private async pickAppearance(m: number): Promise<void> {
    const ctx: common.Context | undefined = this.uiContext();
    if (ctx === undefined) {
      return;
    }
    this.apMode = m;
    await Appearance.set(ctx, m);
  }

  /* ==================== 本地档案 ==================== */

  private async reloadProfile(): Promise<void> {
    try {
      const all: Record<string, string> = await KvRepo.getAll();
      this.pfName = all['profile_name'] === undefined ? '' : all['profile_name'];
      this.pfTarget = all['profile_target'] === undefined ? '' : all['profile_target'];
      // 头像走 AvatarStore 而不是直接读 KV：它还要验文件在不在、转成 Image 能吃的 uri。
      this.avatarSrc = await AvatarStore.imageSrc();
      this.avatarHasCustom = this.avatarSrc.length > 0;
    } catch (e) {
      const err: Error = e as Error;
      Log.w(`档案读取失败：${err.message}`);
    }
  }

  private async saveProfile(): Promise<void> {
    const map: Record<string, string> = {
      'profile_name': this.pfName.trim(),
      'profile_target': this.pfTarget.trim()
    };
    try {
      await KvRepo.putAll(map);
      this.pfEditing = false;
      this.onChanged();
      promptAction.showToast({ message: '档案已保存' });
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`档案保存失败：${err.message}`);
    }
  }

  /**
   * 换头像：拉起系统相册。
   *
   * 用户取消时 picker 返回空串 —— 那是正常操作，静默返回，别弹"你取消了"。
   * 图库为空（模拟器常态）时 picker 会停在空列表，也不该报错。
   */
  private async changeAvatar(): Promise<void> {
    if (this.avatarBusy) {
      return;
    }
    const ctx: common.Context | undefined = this.uiContext();
    if (ctx === undefined) {
      promptAction.showToast({ message: '拿不到应用上下文，重开一次试试' });
      return;
    }
    this.avatarBusy = true;
    try {
      const p: string = await AvatarStore.pickFromGallery(ctx);
      if (p.length === 0) {
        return;
      }
      await this.reloadProfile();
      this.onChanged();
      promptAction.showToast({ message: '头像已更新' });
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`changeAvatar failed: ${err.message}`);
      promptAction.showToast({ message: `换头像失败：${err.message}` });
    } finally {
      this.avatarBusy = false;
    }
  }

  private async resetAvatar(): Promise<void> {
    if (this.avatarBusy) {
      return;
    }
    this.avatarBusy = true;
    try {
      await AvatarStore.reset();
      await this.reloadProfile();
      this.onChanged();
      promptAction.showToast({ message: '已恢复默认头像' });
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`resetAvatar failed: ${err.message}`);
    } finally {
      this.avatarBusy = false;
    }
  }

  /* ==================== 节奏哨兵 ==================== */

  private async reloadSentinel(): Promise<void> {
    const ctx: common.Context | undefined = this.uiContext();
    if (ctx === undefined) {
      return;
    }
    try {
      const s: SentinelSettings = await Sentinel.load(ctx);
      this.sEnabled = s.enabled;
      this.sLead = s.leadHours;
      this.sTwoStage = s.twoStage;
      this.sDnd = s.dndEnabled;
      this.sDndStart = s.dndStart;
      this.sDndEnd = s.dndEnd;
      this.sPermission = await Notifier.isEnabled();
      this.sTotal = await Sentinel.plannedCount(ctx);
      this.sPreview = await Sentinel.preview(ctx);
      // ★ 从库里把「代理提醒能不能用」读回来，而不是等某次交互的返回值。
      //   后台自动 sync（onForeground）那次没人接收 rep，若不读库，
      //   用户进这一页时 sFailed 恒为 0 ⇒ 降级提示不显示 ⇒ 用户以为会被提醒。
      const agent: SentinelReport = await Sentinel.agentStatus(ctx);
      this.sFailed = agent.failed;
      this.sDiagnose = agent.diagnose;
    } catch (e) {
      const err: Error = e as Error;
      Log.w(`哨兵状态读取失败：${err.message}`);
    }
  }

  private settingsNow(): SentinelSettings {
    const s: SentinelSettings = new SentinelSettings();
    s.enabled = this.sEnabled;
    s.leadHours = this.sLead;
    s.twoStage = this.sTwoStage;
    s.dndEnabled = this.sDnd;
    s.dndStart = this.sDndStart;
    s.dndEnd = this.sDndEnd;
    return s;
  }

  /**
   * 改设置 → 立刻落盘 → 重排。
   *
   * 为什么每次都重排而不是等下次进应用：用户把提前量从 2 天改成 1 小时，
   * 期望的是"现在就按新规则算"，而不是"下次再说"。sync 内部按差分只动变化的部分，
   * 所以这里不心疼调用次数。
   */
  private async applySentinel(label: string): Promise<void> {
    const ctx: common.Context | undefined = this.uiContext();
    if (ctx === undefined) {
      return;
    }
    try {
      await Sentinel.save(ctx, this.settingsNow());
      const rep: SentinelReport = await Sentinel.sync(ctx);
      this.sLastMessage = rep.message;
      this.sFailed = rep.failed;
      this.sDiagnose = rep.diagnose;
      Log.i(`哨兵设置已改（${label}）：${rep.message}`);
      await this.reloadSentinel();
    } catch (e) {
      const err: Error = e as Error;
      promptAction.showToast({ message: `设置未生效：${err.message}` });
    }
  }

  /** 「立刻评估」：手动挡。演示时不必等卡片那 30 分钟的心跳。 */
  private async syncSentinelNow(): Promise<void> {
    if (this.sSyncing) {
      return;
    }
    const ctx: common.Context | undefined = this.uiContext();
    if (ctx === undefined) {
      return;
    }
    this.sSyncing = true;
    try {
      const fired: number = await Sentinel.evaluate(ctx, '手动');
      const rep: SentinelReport = await Sentinel.sync(ctx);
      this.sFailed = rep.failed;
      this.sDiagnose = rep.diagnose;
      const head: string = fired > 0 ? `已发出 ${fired} 条提醒` : '当前没有需要提醒的节点';
      this.sLastMessage = rep.failed > 0 ? `${head}；${rep.message}` : head;
      promptAction.showToast({ message: this.sLastMessage });
    } catch (e) {
      const err: Error = e as Error;
      promptAction.showToast({ message: `同步失败：${err.message}` });
    } finally {
      this.sSyncing = false;
      await this.reloadSentinel();
    }
  }

  /**
   * 申请通知授权。
   * ⚠ 代理提醒（系统级排程）与即时通知都卡在这一步 —— 没授权时系统会抛 1700001，
   *   报错信息不会说"是没授权"，所以界面上必须把这条状态直白地摆在用户眼前。
   */
  private async askPermission(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = WidgetRefresher.contextOf(this.getUIContext());
    if (ctx === undefined) {
      return;
    }
    const on: boolean = await Notifier.requestEnable(ctx);
    this.sPermission = on;
    promptAction.showToast({ message: on ? '通知已开启' : '通知仍未开启，去系统设置里打开' });
    if (on) {
      await this.syncSentinelNow();
    }
  }

  /* ==================== AI 设置 ==================== */

  private async saveKey(): Promise<void> {
    const k: string = this.keyInput.trim();
    if (k.length === 0) {
      promptAction.showToast({ message: '先把密钥粘进来' });
      return;
    }
    const ctx: common.Context | undefined = this.uiContext();
    if (ctx === undefined) {
      promptAction.showToast({ message: '拿不到应用上下文，重开一次试试' });
      return;
    }
    try {
      await DeepSeekClient.get().saveKey(ctx, k);
      this.keyInput = '';
      this.showKeyInput = false;
      this.testResult = '';
      this.syncAiState();
      promptAction.showToast({ message: '密钥已保存，点「测试连接」验证一下' });
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`saveKey failed: ${err.message}`);
      promptAction.showToast({ message: '保存失败' });
    }
  }

  private async toggleCloud(on: boolean): Promise<void> {
    const ctx: common.Context | undefined = this.uiContext();
    this.aiAllowed = on;
    if (ctx === undefined) {
      return;
    }
    try {
      await DeepSeekClient.get().saveAllowCloud(ctx, on);
      this.syncAiState();
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`toggleCloud failed: ${err.message}`);
    }
  }

  /** 一次极短的真实调用 —— 让用户在答辩前就能确认密钥和网络都通 */
  private async testConn(): Promise<void> {
    if (this.testing) {
      return;
    }
    const c: DeepSeekClient = DeepSeekClient.get();
    if (!c.hasKey()) {
      this.testOk = false;
      this.testResult = '还没有密钥，先填一个';
      return;
    }
    if (!c.isCloudAllowed()) {
      this.testOk = false;
      this.testResult = '云端开关是关着的，先打开再测';
      return;
    }
    this.testing = true;
    this.testResult = '正在连接…';
    try {
      const msgs: ChatMessage[] = [
        { role: 'user', content: '只回复两个字：可用' }
      ];
      const r: AiResult<string> = await c.chatRaw(msgs, 16, 0.1);
      const ms: number = r.latencyMs !== undefined ? r.latencyMs : 0;
      if (r.ok) {
        this.testOk = true;
        const reply: string = r.raw !== undefined ? r.raw.trim() : '';
        this.testResult = `连接正常 · 用时 ${(ms / 1000).toFixed(1)}s · 模型回复「${reply}」`;
      } else {
        this.testOk = false;
        const why: string = r.error !== undefined ? r.error : '未知原因';
        this.testResult = `连接失败：${why}`;
      }
      Log.i(`AI 连接自检 ok=${r.ok} ${ms}ms`);
    } catch (e) {
      const err: Error = e as Error;
      this.testOk = false;
      this.testResult = `异常：${err.message}`;
    } finally {
      this.testing = false;
    }
  }

  /* ==================== 桌面卡片 ==================== */

  /**
   * 拉起系统的卡片管理页，用户在里面点「添加至桌面」。
   *
   * 为什么不能一键直接加桌：加桌是用户的桌面主权，系统不提供绕过用户确认的接口
   * （openFormManager 已经是官方给的最短路径）。所以这里把用户送到正确的地方，
   * 而不是假装能代劳。
   */
  private addWidget(formName: string, dimension: number, label: string): void {
    const want: Want = {
      bundleName: 'com.wuit.lighthouse',
      abilityName: 'EntryFormAbility',
      parameters: {
        'ohos.extra.param.key.form_dimension': dimension,
        'ohos.extra.param.key.form_name': formName,
        'ohos.extra.param.key.module_name': 'entry'
      }
    };
    try {
      formProvider.openFormManager(want);
      Log.i(`已拉起卡片管理页：${label}`);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.e(`拉起卡片管理页失败 code=${err.code} msg=${err.message}`);
      promptAction.showToast({ message: `打不开卡片管理页：${err.message}` });
    }
  }

  /* ==================== 演示数据 ==================== */

  private async loadDemo(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const n: number = await DemoData.load();
      await this.reload();
      this.onChanged();
      promptAction.showToast({ message: n > 0 ? `已载入 ${n} 条演示数据` : '库里已有记录，未覆盖' });
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`loadDemo failed: ${err.message}`);
      promptAction.showToast({ message: '载入失败，看下日志' });
    } finally {
      this.busy = false;
    }
  }

  private async clearDemo(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await DemoData.clear();
      await this.reload();
      this.onChanged();
      promptAction.showToast({ message: '演示数据已清除' });
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`clearDemo failed: ${err.message}`);
    } finally {
      this.busy = false;
    }
  }

  private confirmWipe(): void {
    AlertDialog.show({
      title: '清空全部数据？',
      message: '投递、节点、复盘会全部删除，无法恢复。演示前重置数据可以用这个。',
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '清空',
        fontColor: Palette.DANGER,
        action: (): void => {
          this.wipe();
        }
      }
    });
  }

  private async wipe(): Promise<void> {
    try {
      await DbHelper.wipe();
      await this.reload();
      this.onChanged();
      promptAction.showToast({ message: '已清空' });
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`wipe failed: ${err.message}`);
    }
  }

  /* ==================== UI ==================== */

  /** 三档外观。@Builder 里不能声明局部变量，所以数组由方法给出。 */
  private appearanceModes(): number[] {
    return [AppearanceMode.FOLLOW, AppearanceMode.LIGHT, AppearanceMode.DARK];
  }

  /**
   * 本地档案。
   *
   * 现在只有两个字段，但它占的是「账号信息」的位置 —— 等本地登录做进来，
   * 这一块就是"已登录为 XXX"，不用再挪动版式。
   */
  @Builder
  profilePanel() {
    Column({ space: 10 }) {
      Text('本地档案').pvCardHead()

      // 头像行放在名字上面：先认脸，再认名字。
      Row({ space: 12 }) {
        if (this.avatarSrc.length > 0) {
          Image(this.avatarSrc)
            .width(54)
            .height(54)
            .borderRadius(27)
            .objectFit(ImageFit.Cover)
            .borderWidth(1)
            .borderColor(Palette.LINE)
        } else {
          Image($rawfile('avatar_default.png'))
            .width(54)
            .height(54)
            .borderRadius(27)
            .objectFit(ImageFit.Cover)
            .borderWidth(1)
            .borderColor(Palette.LINE)
        }

        Column({ space: 3 }) {
          Text('头像')
            .fontSize(13.5)
            .fontColor(Palette.TX)
          Text(this.avatarHasCustom ? '正在用你自己的图片' : '当前是默认头像')
            .fontSize(11)
            .fontColor(Palette.TX_3)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button(this.avatarBusy ? '打开中…' : '更换')
          .fontSize(13.5)
          .fontColor(Palette.PRIMARY)
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor(Palette.PRIMARY)
          .height(34)
          .padding({ left: 14, right: 14 })
          .enabled(!this.avatarBusy)
          .onClick(() => {
            this.changeAvatar();
          })
      }
      .width('100%')

      if (this.avatarHasCustom) {
        Text('恢复默认头像')
          .fontSize(12)
          .fontColor(Palette.TX_3)
          .decoration({ type: TextDecorationType.Underline, color: Palette.TX_3 })
          .onClick(() => {
            this.resetAvatar();
          })
      }

      if (this.pfEditing) {
        TextInput({ text: this.pfName, placeholder: '称呼，比如「曾有」' })
          .pvField()
          .onChange((v: string) => {
            this.pfName = v;
          })
        TextInput({ text: this.pfTarget, placeholder: '目标方向，比如「Java 后端」' })
          .pvField()
          .onChange((v: string) => {
            this.pfTarget = v;
          })
        Row({ space: 10 }) {
          Button('取消')
            .fontSize(14)
            .fontColor(Palette.TX_2)
            .backgroundColor(Color.Transparent)
            .borderWidth(1)
            .borderColor(Palette.LINE)
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              this.pfEditing = false;
              this.reloadProfile();
            })
          Button('保存')
            .fontSize(14)
            .fontColor(Palette.BG)
            .backgroundColor(Palette.PRIMARY)
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              this.saveProfile();
            })
        }
        .width('100%')
      } else {
        Row() {
          Column({ space: 3 }) {
            Text(this.pfName.length > 0 ? this.pfName : '还没填称呼')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.pfName.length > 0 ? Palette.TX : Palette.TX_3)
            Text(this.pfTarget.length > 0 ? this.pfTarget : '填上目标方向，个人页会照着排')
              .fontSize(12)
              .fontColor(Palette.TX_3)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button('编辑')
            .fontSize(13.5)
            .fontColor(Palette.PRIMARY)
            .backgroundColor(Color.Transparent)
            .borderWidth(1)
            .borderColor(Palette.PRIMARY)
            .height(34)
            .padding({ left: 14, right: 14 })
            .onClick(() => {
              this.pfEditing = true;
            })
        }
        .width('100%')
      }
    }
    .panel()
  }

  @Builder
  appearancePanel() {
    Column({ space: 10 }) {
      Text('外观').pvCardHead()
      Row({ space: 8 }) {
        ForEach(this.appearanceModes(), (m: number) => {
          Text(appearanceLabel(m))
            .fontSize(12.5)
            .fontColor(this.apMode === m ? Palette.BG : Palette.TX_2)
            .backgroundColor(this.apMode === m ? Palette.PRIMARY : Palette.PANEL_2)
            .borderRadius(Metrics.CHIP_RADIUS)
            .textAlign(TextAlign.Center)
            .height(34)
            .layoutWeight(1)
            .onClick(() => {
              this.pickAppearance(m);
            })
        }, (m: number) => `ap-${m}-${this.apMode === m}`)
      }
      .width('100%')

      Text('选「跟随系统」时，日落后会自己转深色；手动选了就不再跟着系统变。桌面卡片会一起变 —— 它是跟着系统的资源走的。')
        .fontSize(11.5)
        .fontColor(Palette.TX_3)
        .width('100%')
        .lineHeight(17)
    }
    .panel()
  }

  @Builder
  aiPanel() {
    Column({ space: 10 }) {
      Text('AI 分析引擎').pvCardHead()

      // 状态行：用颜色和文案讲清楚"现在能不能用云端"
      Row({ space: 7 }) {
        Text(this.aiReady ? '●' : '○')
          .fontSize(13)
          .fontColor(this.aiReady ? Palette.OK : Palette.TX_3)
        Text(this.aiReady ? '云端已就绪' : (this.aiAllowed ? '云端未就绪' : '云端已关闭'))
          .fontSize(13.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.aiReady ? Palette.OK : Palette.TX_2)
        Blank()
        Text(this.aiSource)
          .fontSize(11.5)
          .fontColor(Palette.TX_3)
      }
      .width('100%')

      Text('复盘原文交给 DeepSeek 归因，产出六维能力雷达。只在你点「生成雷达」时联网，其他一切都在本机。')
        .fontSize(12.5)
        .fontColor(Palette.TX_2)
        .width('100%')
        .lineHeight(19)

      if (!this.aiReady) {
        Text('没有云端也能用：会切到本地关键词引擎，雷达照样出，只是不做语义归因。断网演示不会翻车。')
          .fontSize(11.5)
          .fontColor(Palette.TX_3)
          .width('100%')
          .lineHeight(17)
      }

      // 密钥输入
      if (this.showKeyInput) {
        TextInput({ text: this.keyInput, placeholder: '粘贴 DeepSeek API Key（sk- 开头）' })
          .pvField()
          .type(InputType.Password)
          .onChange((v: string) => {
            this.keyInput = v;
          })
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(13.5)
            .fontColor(Palette.TX_3)
            .padding({ top: 8, bottom: 8, left: 4, right: 10 })
            .onClick(() => {
              this.showKeyInput = false;
              this.keyInput = '';
            })
          Blank()
          Button('保存密钥')
            .fontSize(14)
            .fontColor(Palette.BG)
            .backgroundColor(Palette.PRIMARY)
            .height(40)
            .onClick(() => {
              this.saveKey();
            })
        }
        .width('100%')
      } else {
        Button(this.aiReady ? '更换 API Key' : '填入 API Key')
          .fontSize(14)
          .fontColor(this.aiReady ? Palette.TX_2 : Palette.BG)
          .backgroundColor(this.aiReady ? Color.Transparent : Palette.PRIMARY)
          .borderWidth(this.aiReady ? 1 : 0)
          .borderColor(Palette.LINE)
          .height(40)
          .width('100%')
          .onClick(() => {
            this.showKeyInput = true;
          })
      }

      // 云端开关
      Row() {
        Column({ space: 2 }) {
          Text('允许联网分析').fontSize(13.5).fontColor(Palette.TX)
          Text('关掉后全程本地运算，数据绝不出设备')
            .fontSize(11)
            .fontColor(Palette.TX_3)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.aiAllowed })
          .selectedColor(Palette.PRIMARY)
          .onChange((on: boolean) => {
            this.toggleCloud(on);
          })
      }
      .width('100%')

      // 连接自检 —— 答辩前跑一次就安心了
      Row({ space: 10 }) {
        Button(this.testing ? '测试中…' : '测试连接')
          .fontSize(13.5)
          .fontColor(Palette.PRIMARY)
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor(Palette.PRIMARY)
          .height(38)
          .layoutWeight(1)
          .enabled(!this.testing)
          .onClick(() => {
            this.testConn();
          })
      }
      .width('100%')

      if (this.testResult.length > 0) {
        Text(this.testResult)
          .fontSize(11.5)
          .fontColor(this.testOk ? Palette.OK : Palette.ACCENT)
          .width('100%')
          .lineHeight(17)
      }

      Text('端侧另有离线语音速记，录音不出设备 —— 能端侧的一律端侧，只有非结构化的人类语言才上云。')
        .fontSize(11)
        .fontColor(Palette.TX_3)
        .width('100%')
        .lineHeight(17)
    }
    .panel()
  }

  /* ==================== 节奏哨兵 ==================== */

  @Builder
  sentinelPanel() {
    Column({ space: 10 }) {
      Text('节奏哨兵').pvCardHead()
      Text('到点由通知找你。心跳来自桌面卡片——系统每 30 分钟唤醒它一次，所以应用没打开也能提醒。')
        .fontSize(12.5)
        .fontColor(Palette.TX_2)
        .width('100%')
        .lineHeight(19)

      // 授权状态必须显眼：没授权时所有提醒都是哑的，而系统报错不会说"是没授权"
      Row({ space: 8 }) {
        Text(this.sPermission ? '● 通知已开启' : '● 通知未开启，提醒发不出来')
          .fontSize(12.5)
          .fontColor(this.sPermission ? Palette.OK : Palette.DANGER)
        Blank()
        if (!this.sPermission) {
          Button('去开启')
            .fontSize(12.5)
            .fontColor(Palette.BG)
            .backgroundColor(Palette.PRIMARY)
            .height(30)
            .padding({ left: 14, right: 14 })
            .onClick(() => {
              this.askPermission();
            })
        }
      }
      .width('100%')

      Divider().color(Palette.LINE)

      // 系统拒绝排程时如实降级，并把原因摊开 —— 假装"提醒已排上"是最坏的选择，
      // 用户会因此真的错过面试。
      if (this.sFailed > 0) {
        Column({ space: 4 }) {
          Text('系统级代理提醒不可用，已改由「卡片心跳 + 本地通知」承担')
            .fontSize(12.5)
            .fontColor(Palette.ACCENT)
            .width('100%')
          if (this.sDiagnose.length > 0) {
            Text(this.sDiagnose)
              .fontSize(11)
              .fontColor(Palette.TX_3)
              .width('100%')
              .lineHeight(16)
          }
          Text('原因：代理提醒有管控配额，普通应用默认可用条数为 0，须邮件申请权益。' +
            '影响：提醒精度从「分钟级」降到「30 分钟内」。')
            .fontSize(11)
            .fontColor(Palette.TX_3)
            .width('100%')
            .lineHeight(16)
        }
        .width('100%')
        .padding(10)
        .backgroundColor(Palette.PANEL_2)
        .borderRadius(Metrics.CHIP_RADIUS)
      }

      Row() {
        Column({ space: 3 }) {
          Text('哨兵开关').fontSize(13.5).fontColor(Palette.TX)
          Text('关掉会撤下所有已排的系统提醒').fontSize(11).fontColor(Palette.TX_3)
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.sEnabled })
          .selectedColor(Palette.PRIMARY)
          .onChange((on: boolean) => {
            this.sEnabled = on;
            this.applySentinel('开关');
          })
      }
      .width('100%')

      if (this.sEnabled) {
        Column({ space: 6 }) {
          Text('提前多久提醒').fontSize(13.5).fontColor(Palette.TX)
          Row({ space: 8 }) {
            // ⚠ key 里带上"是否选中"：只用小时数做 key 时，改选中项不会重建这些节点
            ForEach(LEAD_CHOICES, (h: number) => {
              Text(leadLabel(h))
                .fontSize(12.5)
                .fontColor(this.sLead === h ? Palette.BG : Palette.TX_2)
                .backgroundColor(this.sLead === h ? Palette.PRIMARY : Palette.PANEL_2)
                .borderRadius(Metrics.CHIP_RADIUS)
                .textAlign(TextAlign.Center)
                .height(34)
                .layoutWeight(1)
                .onClick(() => {
                  this.sLead = h;
                  this.applySentinel('提前量');
                })
            }, (h: number) => `lead-${h}-${this.sLead === h}`)
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Row() {
          Column({ space: 3 }) {
            Text('开始前 1 小时再提醒一次').fontSize(13.5).fontColor(Palette.TX)
            Text('只对面试和笔试生效，截止日提前 1 小时没意义').fontSize(11).fontColor(Palette.TX_3)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.sTwoStage })
            .selectedColor(Palette.PRIMARY)
            .onChange((on: boolean) => {
              this.sTwoStage = on;
              this.applySentinel('二次提醒');
            })
        }
        .width('100%')

        Row() {
          Column({ space: 3 }) {
            Text(`免打扰 ${this.sDndStart}:00–${this.sDndEnd}:00`).fontSize(13.5).fontColor(Palette.TX)
            Text('落在静默时段的提醒整体顺延到早上，但不会晚过事件本身')
              .fontSize(11)
              .fontColor(Palette.TX_3)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.sDnd })
            .selectedColor(Palette.PRIMARY)
            .onChange((on: boolean) => {
              this.sDnd = on;
              this.applySentinel('免打扰');
            })
        }
        .width('100%')
      }

      if (this.sEnabled) {
        Button(this.sSyncing ? '评估中…' : '立刻评估提醒')
          .fontSize(14)
          .fontColor(Palette.BG)
          .backgroundColor(Palette.PRIMARY)
          .height(40)
          .width('100%')
          .enabled(!this.sSyncing)
          .onClick(() => {
            this.syncSentinelNow();
          })

        Text(this.sLastMessage.length > 0
          ? this.sLastMessage
          : `卡片每 30 分钟心跳一次，进入提醒档位的节点会自动弹通知`)
          .fontSize(11.5)
          .fontColor(this.sLastMessage.length > 0 ? Palette.PRIMARY : Palette.TX_3)
          .width('100%')
          .lineHeight(17)

        if (this.sPreview.length > 0) {
          Column({ space: 4 }) {
            ForEach(this.sPreview, (line: string, idx: number) => {
              Row({ space: 6 }) {
                Text('·').fontSize(12).fontColor(Palette.TX_3)
                Text(line)
                  .fontSize(11.5)
                  .fontColor(Palette.TX_2)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
            }, (line: string, idx: number) => `pv-${idx}-${line}`)
          }
          .width('100%')
        }
      }
    }
    .panel()
  }

  /**
   * 宽屏左列：档案 / 外观 / 桌面卡片 / 节奏哨兵。
   * 左列是「这台设备怎么服务我」，右列是「数据与危险操作」——
   * 调提醒提前量的时候，不用先滚过一屏演示数据和关于信息。
   */
  @Builder
  colLeft() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Text('‹')
          .fontSize(26)
          .fontColor(Palette.TX_2)
          .onClick(() => {
            this.onBack();
          })
        Text('设置')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.TX)
        Blank()
      }
      .width('100%')
      .padding({ top: 8 })

      this.profilePanel()
      this.appearancePanel()

      Column({ space: 10 }) {
        Text('桌面卡片').pvCardHead()
        Text('把「节奏哨兵」钉在主屏：不打开应用就能看到最近节点的倒计时。两种尺寸共用同一份数据，跟随系统深浅色。')
          .fontSize(12.5)
          .fontColor(Palette.TX_2)
          .width('100%')
          .lineHeight(19)
        Row({ space: 10 }) {
          Button('2×4 主卡')
            .fontSize(14)
            .fontColor(Palette.BG)
            .backgroundColor(Palette.ACCENT)
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              this.addWidget(FORM_MAIN, 3, '2×4 主卡');
            })
          Button('2×2 小卡')
            .fontSize(14)
            .fontColor(Palette.TX_2)
            .backgroundColor(Color.Transparent)
            .borderWidth(1)
            .borderColor(Palette.LINE)
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              this.addWidget(FORM_MINI, 2, '2×2 小卡');
            })
        }
        .width('100%')
      }
      .panel()

      // 卡片与通知是同一件事的两半：卡片常驻看全局，通知在关键节点主动叫你。
      // 放在一起是让答辩时能一眼看出这是"服务找人"的完整闭环。
      this.sentinelPanel()
    }
    .width('100%')
  }

  /** 宽屏右列：演示数据 / AI 引擎 / 关于 / 危险操作 */
  @Builder
  colRight() {
    Column({ space: 12 }) {

      Column({ space: 10 }) {
        Text('演示数据').pvCardHead()
        Text('一键载入一组 Java 后端方向的投递样本，方便先看到成品形态。库里已有记录时不会覆盖。')
          .fontSize(12.5)
          .fontColor(Palette.TX_2)
          .width('100%')
          .lineHeight(19)
        Button(this.busy ? '处理中…' : '载入演示数据')
          .fontSize(14)
          .fontColor(Palette.BG)
          .backgroundColor(Palette.PRIMARY)
          .height(40)
          .width('100%')
          .enabled(!this.busy)
          .onClick(() => {
            this.loadDemo();
          })
        Button('清除演示数据')
          .fontSize(14)
          .fontColor(Palette.TX_2)
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor(Palette.LINE)
          .height(40)
          .width('100%')
          .enabled(!this.busy)
          .onClick(() => {
            this.clearDemo();
          })
      }
      .panel()

      this.aiPanel()

      Column({ space: 6 }) {
        Text('关于').pvCardHead()
        Row() {
          Text('作品名').kvLabel()
          Blank()
          Text('灯塔 Lighthouse').kvValue().fontColor(Palette.TX)
        }.kvRowBox()
        Row() {
          Text('版本').kvLabel()
          Blank()
          Text('1.0.0（内测）').kvValue().fontColor(Palette.TX_2)
        }.kvRowBox()
        Row() {
          Text('参赛').kvLabel()
          Blank()
          Text('2026 光谷杯鸿蒙生态创新大赛').kvValue().fontColor(Palette.TX_2)
        }.kvRowBox()
      }
      .panel()

      Column({ space: 8 }) {
        Text('危险操作').pvCardHead()
        Button('清空全部数据')
          .fontSize(14)
          .fontColor(Palette.DANGER)
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor(Palette.DANGER)
          .height(40)
          .width('100%')
          .onClick(() => {
            this.confirmWipe();
          })
      }
      .panel()

      Row().height(20)
    }
    .width('100%')
  }

  build() {
    if (this.twoPane) {
      // ── 宽屏双栏。两列各自滚动：改设置和查数据不需要在同一条长列表里来回翻。
      Row({ space: Metrics.GAP }) {
        Scroll() {
          this.colLeft()
        }
        .layoutWeight(1)
        .height('100%')
        .scrollBar(BarState.Off)

        Scroll() {
          this.colRight()
        }
        .layoutWeight(1)
        .height('100%')
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .padding({ left: Metrics.PAGE_PAD, right: Metrics.PAGE_PAD })
      .backgroundColor(Palette.BG)
    } else {
      Scroll() {
        Column({ space: 12 }) {
          this.colLeft()
          this.colRight()
        }
        .width('100%')
        .padding({ left: Metrics.PAGE_PAD, right: Metrics.PAGE_PAD })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .backgroundColor(Palette.BG)
    }
  }
}
