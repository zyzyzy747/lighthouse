import { AbilityConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { DbHelper } from '../model/DbHelper';
import { DeepSeekClient } from '../service/DeepSeekClient';
import { Sentinel, SentinelSettings, SentinelReport } from '../service/Sentinel';
import { Appearance } from '../service/Appearance';
import { Auth } from '../service/Auth';
import { DemoData } from '../service/DemoData';
import { VoiceMemo } from '../service/VoiceMemo';
import { AvatarStore } from '../service/AvatarStore';
import { WidgetRefresher } from '../service/WidgetRefresher';
import { pushNavTarget, navTargetOf, NAV_AGENT } from '../common/Nav';
import { applyLayoutPreview } from '../common/Layout';
import { Log } from '../common/Logger';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 数据库在这里拉起一次，之后全应用共用同一个 store。
    // 不 await：建库是毫秒级，页面 aboutToAppear 里会通过 DbHelper.get() 自然排队等待。
    DbHelper.init(this.context)
      .then(() => {
        Log.i('DbHelper ready in Ability.onCreate');
      })
      .catch((err: Error) => {
        Log.e(`DbHelper init failed: ${err.message}`);
      });

    // AI 客户端同理，必须在这里加载一次。
    // ⚠ 漏了这一步会静默降级：apiKey 初值是空串，isCloudEnabled() 会一直为 false，
    //   于是「配了 key 也用不上云端」，日志只留一句『云端不可用：未配置 API Key』，
    //   从表面看像是没配 key，实际是压根没读进来。
    DeepSeekClient.get().load(this.context)
      .then(() => {
        Log.i(`AI client ready, cloudEnabled=${DeepSeekClient.get().isCloudEnabled()}`);
      })
      .catch((err: Error) => {
        Log.e(`AI client load failed: ${err.message}`);
      });

    // 首次启动可能是从桌面卡片点进来的，意图要先接住再交给 UI
    this.acceptIntent(want);

    // 多端：悬停预览开关（只用于没有折叠屏设备时把悬停布局渲染出来自检，正常启动不命中）
    applyLayoutPreview(want.parameters);

    // 本地档案：把本次会话置回"未解锁"，并按需跑自检自动登录。
    //
    // ★ 必须早于 maybeLoadDemo —— 载入演示数据写的是业务表，而界面这时还被
    //   登录门挡着的话，验收脚本会看到"数据载入了但界面是空的"，红得像功能坏了。
    // 不 await：这里只是挂一个 promise，界面那头用 Auth.settle() 汇合
    //（不汇合就是竞态，见 Index.boot 的注释）。
    Auth.bootstrapSession(this.selfFlag(want, 'lh_autologin'));

    // 语音探测开关（同样只在自检时命中，正常启动不会跑）。
    // 为什么延后 4 秒：权限弹窗要挂在已经建好的窗口上，onCreate 阶段窗口还没出来。
    const probe: Object | undefined = want.parameters === undefined ? undefined : want.parameters['lh_mic_probe'];
    if (probe !== undefined && probe !== null) {
      Log.i('语音探测：收到自检开关，4 秒后开始录音');
      const ctx: common.UIAbilityContext = this.context;
      setTimeout(() => {
        VoiceMemo.probe(ctx);
      }, 4000);
    }

    // 语音识别链路自检：把 rawfile 里的测试音频当麦克风数据喂给引擎，看能不能出字。
    // 这条路径不用麦克风、不弹权限，所以是**无人值守**可跑的最强证据 ——
    // 能过就说明 createEngine/startListening/writeAudio/onResult 四步都通。
    const voice: Object | undefined =
      want.parameters === undefined ? undefined : want.parameters['lh_voice_dict'];
    if (voice !== undefined && voice !== null) {
      Log.i('语音自检：收到开关，4 秒后跑识别链路');
      const ctx: common.UIAbilityContext = this.context;
      setTimeout(() => {
        VoiceMemo.selfTestClip(ctx, 'voice_clip.pcm', ['面试', '简历', '成绩单'])
          .catch((err: Error) => {
            Log.e(`语音自检异常：${err.message}`);
          });
      }, 4000);
    }

    this.maybeAuthDump(want);
    this.maybeLoadDemo(want);
    this.maybeSelfAsk(want);
    this.maybeSelfAvatar(want);
  }

  /**
   * 自检：把库里存了什么打进日志（用来证明密码没落明文）。
   * `aa start --pi lh_auth_dump 1`
   *
   * ⚠ 必须等 `Auth.settle()`：档案可能是本次启动刚由 `lh_autologin` 建出来的，
   *   不等就会 dump 到一张空表 —— 表现出来是"档案根本没存进去"，
   *   而真相只是"念得太早"。这个坑和 Index.boot 里那个是同一个。
   */
  private async maybeAuthDump(want: Want): Promise<void> {
    if (!this.selfFlag(want, 'lh_auth_dump')) {
      return;
    }
    await Auth.settle();
    await Auth.selfTestDump();
  }

  /**
   * 自检用的提问通道：`aa start --ps lh_ask "最近要准备什么"`。
   *
   * 为什么需要它：智能体要能用**任意问话**验证，而验收脚本目前没有可靠的中文输入法
   * （`uinput` 只能注入坐标，输不了文字）。没有这条通道，脚本就只能点那几个预设 chip，
   * 于是"库里查不到时不许编"这类最重要的断言一个都测不了。
   *
   * 走 AppStorage 而不是静态变量，理由和 common/Nav 里那条一样：UI 可能已经建好了，
   * 静态变量不具响应式，界面挂在后台时问话就直接丢了。
   *
   * ⚠ UI 那头必须处理"信号早于界面"的情况（@Watch 只对**变化**触发）——见 AssistantView。
   */
  private maybeSelfAsk(want: Want): void {
    const ask: Object | undefined =
      want.parameters === undefined ? undefined : want.parameters['lh_ask'];
    if (ask === undefined || ask === null) {
      return;
    }
    const q: string = `${ask}`;
    Log.i(`自检：收到提问「${q}」`);
    AppStorage.setOrCreate('lhAsk', q);
    // ★ 还要给一个**递增的序号**。
    //   界面靠 @Watch 收信号，而 @Watch 只在值**变化**时触发 ——
    //   验收脚本如果连问两次同一句话（比如"重复问同一件事，答案要一致"），
    //   光写 lhAsk 第二次值没变，界面根本不会动，看起来像提问通道失效。
    AppStorage.setOrCreate('lhAskSeq', Date.now());
    // 顺手把页面切到助手：验收脚本不必自己找 Tab，人工演示也少一步。
    pushNavTarget(NAV_AGENT);
  }

  /**
   * 读一个自检开关。
   *
   * `--pi x 1` 传进来是数字、`--ps x y` 传进来是字符串，两种都要认；
   * 另外 `0` / `false` 应当算"关"。集中写一处，免得每个开关各解释一套布尔语义。
   */
  private selfFlag(want: Want, key: string): boolean {
    const v: Object | undefined =
      want.parameters === undefined ? undefined : want.parameters[key];
    if (v === undefined || v === null) {
      return false;
    }
    const s: string = `${v}`;
    return s.length > 0 && s !== '0' && s !== 'false';
  }

  /** 读一个字符串型自检参数；没给 / 空 ⇒ 返回空串。`--ps lh_xxx value` 走这里。 */
  private selfStr(want: Want, key: string): string {
    const v: Object | undefined =
      want.parameters === undefined ? undefined : want.parameters[key];
    if (v === undefined || v === null) {
      return '';
    }
    return `${v}`.trim();
  }

  /**
   * 头像自检开关：`aa start --ps lh_avatar demo`（换测试图）/ `reset`（恢复默认）。
   *
   * 为什么非要有这么个开关：模拟器是 **uid=2000 非 root**，没法程序化往系统相册塞图
   * （`mediatool` 只有 recv / delete / query，**没有 insert**；媒体库目录 Permission denied）。
   * 相册为空时，「从相册选头像」这条路径在无人值守的自动验收里根本走不到底。
   *
   * 这个开关绕开相册，直接跑「读图 → 写沙箱 → 记 KV → 界面读取」后半条链路，
   * 装的是 rawfile 里那张**橙黑斜条纹测试图**（`avatar_selftest.png`，1.2 KB，
   * 不出现在任何界面入口）—— 它和默认头像的视觉差异极大，
   * 截一张图比对头像区域就能证明"头像真的换掉了"，不用靠读日志自证。
   */
  private async maybeSelfAvatar(want: Want): Promise<void> {
    const v: string = this.selfStr(want, 'lh_avatar');
    if (v.length === 0) {
      return;
    }
    try {
      if (v === 'reset') {
        await AvatarStore.reset();
        Log.i('自检：头像已恢复默认');
      } else {
        const p: string = await AvatarStore.installFromRaw(this.context, 'avatar_selftest.png');
        Log.i(`自检：头像已换为测试图 → ${p}`);
      }
      // ★ 写入晚于 UI 首次 reload，必须发一次重载信号，否则界面还画着旧头像。
      //   这条通路和 lh_load_demo 一致（Index 那边 @Watch + aboutToAppear 双保险消费）。
      AppStorage.setOrCreate('lhDataBump', Date.now());
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`自检：头像开关失败：${err.message}`);
    }
  }

  /**
   * 演示数据自检开关：`aa start --pi lh_load_demo 1`。
   *
   * 存在的理由：**验收脚本不该靠点界面按钮来准备数据。**
   * 「载入演示数据」搬到设置页之后，脚本要先切到「我的」→ 进设置 → 再滚动找按钮，
   * 而长距离滚动在这个模拟器上本来就不可靠（实测连续 7 次 dump 内容一模一样）。
   * 那种路径失败时报错是"找不到按钮"，看着像功能坏了，其实是导航问题。
   * 带参启动一次到位，且和 lh_mic_probe / lh_voice_dict 是同一套自检惯例。
   *
   * 正常启动不带这个参数，不会跑。
   */
  private maybeLoadDemo(want: Want): void {
    const demo: Object | undefined =
      want.parameters === undefined ? undefined : want.parameters['lh_load_demo'];
    if (demo === undefined || demo === null) {
      // 没让载演示数据时，也可能只单独拍了一个免打扰开关 —— 那条路也要通
      this.applySelfTestSwitches(want);
      return;
    }
    Log.i('自检：收到载入演示数据开关');
    this.loadDemoAndSync(want);
  }

  /**
   * 自检用的免打扰开关：`aa start --pi lh_dnd 0`（0=关掉打扰时段，1=打开）。
   *
   * 为什么非有它不可：免打扰是**按设备时钟**生效的（默认 22:00–08:00），
   * 而自动验收脚本什么时候跑是不挑的 —— 设备时钟落在凌晨时，每一次评估都被
   * 「处在免打扰时段，本次不打扰」**正确地**拦掉。表现出来是
   * "哨兵发出 0 条""通知栏里没有提醒""手动评估没执行"，跟提醒功能真的坏了
   * 长得一模一样，而真相只藏在另一行日志里（2026-09-22 实踩，17/31 全挂在这上面）。
   *
   * 想改设备时间掩盖它是行不通的：`hdc shell date ...` → `Operation not permitted`。
   * 所以只能由脚本显式把免打扰关掉，让"该不该发"这件事脱离时钟。
   * 注意这里**不改哨兵的默认出厂设置**，只是像用户在界面上拨了一次开关那样写入偏好。
   */
  private async applySelfTestSwitches(want: Want): Promise<void> {
    const dnd: Object | undefined =
      want.parameters === undefined ? undefined : want.parameters['lh_dnd'];
    if (dnd === undefined || dnd === null) {
      return;
    }
    const turnOff: boolean = `${dnd}` !== '1';
    try {
      const s: SentinelSettings = await Sentinel.load(this.context);
      s.dndEnabled = !turnOff;
      await Sentinel.save(this.context, s);
      Log.i(`自检：免打扰已${s.dndEnabled ? '开启' : '关闭'}`);
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`自检：免打扰开关失败：${err.message}`);
    }
  }

  /**
   * 载入演示数据 + 补一次哨兵评估。
   *
   * ⚠ 后半步不是多余的：界面路径点「载入演示数据」会走 onChanged → bumpAndPush，
   *   那里顺带做一次哨兵评估 —— 验收脚本（verify_notify）就是靠这条日志断言
   *   "提醒真的发出去了"。带参载入没有界面，这一步必须在这里补齐，
   *   否则开关路径和按钮路径的行为悄悄分叉，脚本红得莫名其妙。
   */
  private async loadDemoAndSync(want: Want): Promise<void> {
    try {
      // ★ 顺序讲究：免打扰开关必须先于 evaluate 落盘。
      //   evaluate() 内部每次都重新 load 设置（见 Sentinel.evaluate 第 207 行），
      //   这两个 await 如果并行写就会有竞态 —— 具体到这一步的表现是"开关写晚了，
      //   本次评估仍按旧设置在打扰时段里被拦掉"，症状和上面那条记录又是同一个。
      await this.applySelfTestSwitches(want);
      const n: number = await DemoData.load();
      Log.i(`自检：演示数据已载入 ${n} 条`);
      const ctx: common.UIAbilityContext = this.context;
      const fired: number = await Sentinel.evaluate(ctx, '自检载入');
      const rep: SentinelReport = await Sentinel.sync(ctx);
      Log.i(`自检：哨兵排程 ${rep.message}`);
      // ★ 还要把桌面卡片推一次。
      //   界面上点「载入演示数据」会走到 Index.bumpAndPush()，那里有这一步；
      //   开关路径不经过 UI，**不补就等于桌面卡片还挂着旧数据** ——
      //   而"App 写库 → 卡片跟着刷新"恰好是卡片验证里最重要的一条断言，
      //   一旦两条路径行为分叉，就会出现"点按钮时全绿、走开关时卡片不刷新"。
      //   这种只在测试路径上才暴露的差异最难查，所以这里必须对齐。
      WidgetRefresher.refreshAll(ctx);
      if (fired > 0) {
        Log.i(`自检：演示数据触发了 ${fired} 条本地提醒`);
      }
      // 通知 UI 重载。⚠ 没有这一步，快记页会是空的：数据是后台写进库的，
      // 而 UI 的首次 reload 早于写入完成（建库要排队），写入完成后又没人 bump。
      // 界面路径点按钮会走 onChanged → bump，开关路径必须自己把这个信号补上。
      AppStorage.setOrCreate('lhDataBump', Date.now());
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`自检：演示数据载入失败：${err.message}`);
    }
  }

  /**
   * 应用已在运行时被卡片再次拉起（用户没杀掉后台，直接点桌面卡片）。
   * ⚠ 这条回调不写，卡片就只能在"冷启动"时跳对页面 ——
   *   而真实使用场景里绝大多数点击都是热启动，等于功能只在演示时成立。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.acceptIntent(want);
    // 自检开关同样要在热启动路径上生效：`aa start --ps ...` 打在活着的进程上是走
    // onNewWant 而不是 onCreate，这里不接一次，"先起应用再带参拉起"就完全无效。
    applyLayoutPreview(want.parameters);
    // 自检自动登录在热启动路径上也要生效：`aa start` 打在活着的进程上是走
    // onNewWant 而不是 onCreate，这里不接一次，"先起应用再带参拉起"就完全无效。
    // ⚠ 热启动只登录、**不重新锁定** —— 否则会把用户当前的解锁会话踢掉。
    Auth.applySelfTestLogin(this.selfFlag(want, 'lh_autologin'));
    this.maybeLoadDemo(want);
    this.maybeSelfAsk(want);
    this.maybeSelfAvatar(want);
  }

  /** 把卡片带过来的 lh_target 转成导航意图交给 UI（UI 还没起来也不会丢） */
  private acceptIntent(want: Want): void {
    const target: string = navTargetOf(want.parameters);
    if (target.length === 0) {
      return;
    }
    pushNavTarget(target);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    // 外观（深/浅）是应用级设置，不会自己记住 —— 每次启动都要把用户上次的选择重新告诉系统。
    // 不 await：这只是把偏好写进 ApplicationContext，界面已经先画出来了也无所谓。
    // ⚠ 放在 loadContent 之后而不是之前：setColorMode 会触发一次配置变更重建，
    //   太早调用会和首帧渲染抢，启动页会闪一下。
    Appearance.apply(this.context)
      .then(() => {
        Log.i('外观偏好已应用');
      })
      .catch((err: Error) => {
        Log.e(`外观偏好应用失败：${err.message}`);
      });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    this.syncSentinel();
  }

  /**
   * 节奏哨兵：每次回到前台评估一次提醒、并对齐系统排程。
   *
   * 为什么放在 onForeground 而不是 onCreate：
   *   onCreate 只在冷启动跑一次，而"跨天""用户改了系统时间""上次没授权这次授权了"
   *   这些情况都发生在应用一直活着的时候。onForeground 每次回前台都会触发，覆盖面刚好。
   *
   * 不 await：都是跨进程调用，不该让用户等 —— 两个函数内部各自有互斥/去重，
   * 连点几次也不会重复发或重复排。
   */
  private syncSentinel(): void {
    // ① 本地通知：真正可用的主通道。用户回到应用就当场把该发的发掉，
    //    不必等卡片那条 30 分钟的心跳。
    Sentinel.evaluate(this.context, '前台')
      .then((n: number) => {
        Log.i(`哨兵(前台) 本地提醒 ${n} 条`);
      })
      .catch((err: Error) => {
        Log.e(`哨兵(前台) 评估异常：${err.message}`);
      });

    // ② 系统代理提醒：精度最高，但有管控配额（普通应用默认 0 条）。
    //    排不进去会如实降级并在 UI 上说明，不影响 ①。
    Sentinel.sync(this.context)
      .then((rep: SentinelReport) => {
        Log.i(`哨兵(前台) ${rep.message}`);
      })
      .catch((err: Error) => {
        Log.e(`哨兵(前台) 排程异常：${err.message}`);
      });
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}