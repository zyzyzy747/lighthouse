import { common } from '@kit.AbilityKit';
import { Palette, Metrics } from '../common/Theme';
import { DbHelper } from '../model/DbHelper';
import { Log } from '../common/Logger';
import { NAV_KEY, NAV_QUICK, NAV_MAP, NAV_REVIEW, NAV_HOME } from '../common/Nav';
import { WidgetRefresher } from '../service/WidgetRefresher';
import { WidgetData } from '../service/WidgetData';
import { Sentinel, SentinelReport } from '../service/Sentinel';
import { Layout, FoldWatcher } from '../common/Layout';
import { QuickRecordView } from '../view/QuickRecordView';
import { MapView } from '../view/MapView';
import { ReviewView } from '../view/ReviewView';
import { ProfileView } from '../view/ProfileView';

/**
 * 灯塔主框架。
 *
 * 一多形态：
 *   sm（手机竖屏）        底部四栏
 *   md（折叠屏展开）      左侧栏
 *   lg（手机横屏 / 平板） 左侧栏 + 各页内容左右双栏
 *   折叠屏半折叠（悬停）  上半区「作战简报」+ 下半区内容
 *
 * 断点判定全部交给 common/Layout 统一折算后写进 AppStorage，本组件只订阅结果 ——
 * 这样"宽度怎么算档位"只有一处定义，页面之间不会各自解释一套阈值。
 */
@Entry
@Component
struct Index {
  /** ⚠ 不能叫 tabIndex —— 与 CustomComponent 基类的 tabIndex() 方法冲突 */
  @State curTab: number = 0;
  /** 数据版本号：任何页面改了数据就 +1，其余页面收到后自动重载。 */
  @State tick: number = 0;
  @State ready: boolean = false;

  /**
   * 启动页最短停留时长。
   *
   * ⚠ 数据库在 EntryAbility.onCreate 里就已经初始化好了，boot() 里那句 await 是立刻返回的
   *   —— 不留这一小段，启动页会在首帧画出来之前就被替换掉，等于根本不存在
   *   （实测日志里 "DbHelper ready" 和 "ui ready" 是同一毫秒）。
   *   这不是"故意让应用启动变慢"：只要超过了它就立刻进主界面，一刻都不多等。
   */
  private static readonly SPLASH_MIN_MS: number = 700;

  /**
   * 卡片的导航意图。桌面卡片点「＋」会带参数拉起 EntryAbility，
   * 由 common/Nav 写进 AppStorage，这里响应式接住 ——
   * 即使用户把应用留在后台直接点卡片，也能正确落到目标页。
   *
   * ⚠ 这里必须写字符串字面量：装饰器参数在编译期求值，传常量变量不会被识别。
   *   字面量要和 common/Nav 里的 NAV_KEY 保持一致。
   */
  @StorageLink('lhNavTarget') @Watch('onNavTarget') navTarget: string = '';

  // ── 多端布局开关（同样必须写字面量，见 common/Layout 顶部说明）
  @StorageProp('lhSideNav') sideNav: boolean = false;
  @StorageProp('lhTwoPane') twoPane: boolean = false;
  @StorageProp('lhHover') @Watch('onHoverChanged') hover: boolean = false;
  @StorageProp('lhCompact') compact: boolean = false;
  @StorageProp('lhSideW') sideW: number = 104;
  @StorageProp('lhWinHeight') winH: number = 0;

  // ── 悬停简报。数据来自 WidgetData（与桌面卡片同一套文案），
  //    保证「卡片上写的」和「悬停时看的」是同一个口径，不会出现两个数字打架。
  @State bTitle: string = '';
  @State bType: string = '';
  @State bWhen: string = '';
  @State bBig: string = '';
  @State bUnit: string = '';
  @State bLeft: string = '';
  @State bLevel: string = 'normal';
  @State bHead: string = '';
  private briefTimer: number = -1;

  aboutToAppear(): void {
    this.boot();
    // 折叠屏状态监听。非折叠设备上内部会直接返回，只留一条日志说明原因。
    FoldWatcher.start();
    // ⚠ 冷启动时 AppStorage 里可能已经躺着卡片的意图（EntryAbility.onCreate 先于 UI 执行）。
    //   @Watch 只在「值发生变化」时触发，初值就存在的情况它接不住 ——
    //   漏了这一句，点卡片的「＋」会停在默认页，功能只在热启动时看着正常。
    this.consumeNav(false);
  }

  aboutToDisappear(): void {
    this.stopBriefTimer();
  }

  /** 意图 → Tab 下标。未知意图返回 -1，保持原页面不动。 */
  private tabOf(target: string): number {
    if (target === NAV_QUICK) {
      return 0;
    }
    if (target === NAV_MAP) {
      return 1;
    }
    if (target === NAV_REVIEW) {
      return 2;
    }
    if (target === NAV_HOME) {
      return 1;
    }
    return -1;
  }

  onNavTarget(): void {
    this.consumeNav(true);
  }

  /**
   * 消费一次卡片导航意图。
   * @param fresh true = 应用本来就在后台（热启动），顺带重载一次数据，
   *              否则用户会看到"从卡片进来但数字还是旧的"。
   */
  private consumeNav(fresh: boolean): void {
    const target: string = this.navTarget;
    if (target.length === 0) {
      return;
    }
    const idx: number = this.tabOf(target);
    if (idx >= 0) {
      this.curTab = idx;
    }
    // 消费掉，防止后续任何一次重渲染都重复触发
    AppStorage.setOrCreate(NAV_KEY, '');
    Log.i(`卡片意图已执行 target=${target} tab=${idx} fresh=${fresh}`);
    if (fresh) {
      this.bump();
    }
  }

  private async boot(): Promise<void> {
    const t0: number = Date.now();
    try {
      await DbHelper.get();
    } catch (e) {
      // 数据库起不来也照样放行（见 enterMain 注释），否则用户看到的是永远转圈的启动页
      const err: Error = e as Error;
      Log.e(`ui boot failed: ${err.message}`);
    }

    const rest: number = Index.SPLASH_MIN_MS - (Date.now() - t0);
    if (rest > 0) {
      setTimeout(() => {
        this.enterMain();
      }, rest);
    } else {
      this.enterMain();
    }
  }

  /** 离开启动页，进主界面。 */
  private enterMain(): void {
    this.ready = true;
    Log.i('ui ready');
    // 冷启动时可能已经是悬停状态（半折叠着开机 / 从卡片进来），补一次简报
    if (this.hover) {
      this.refreshBrief();
    }
  }

  private bump(): void {
    this.tick = this.tick + 1;
  }

  // ────────────────────────────────────────────────── 悬停简报
  /**
   * ⚠ 方法名不能叫 onHover —— 与 CustomComponent 基类的通用 hover 事件 `onHover()` 冲突，
   *   编译器报 "Property 'onHover' is not assignable to the same property in base type"。
   *   同类坑还有 tabIndex（Index）和 position（QuickRecordView），都是撞了基类成员。
   */
  onHoverChanged(): void {
    if (this.hover) {
      Log.i('多端：进入悬停分栏');
      this.refreshBrief();
      this.startBriefTimer();
    } else {
      Log.i('多端：退出悬停分栏');
      this.stopBriefTimer();
    }
  }

  private startBriefTimer(): void {
    if (this.briefTimer !== -1) {
      return;
    }
    // 30 秒刷一次。悬停简报上的倒计时是"站着看"的信息，
    // 精度到「天 / 小时」就够（与桌面卡片保持同一口径），不需要秒级跳动。
    this.briefTimer = setInterval(() => {
      this.refreshBrief();
    }, 30000);
  }

  private stopBriefTimer(): void {
    if (this.briefTimer !== -1) {
      clearInterval(this.briefTimer);
      this.briefTimer = -1;
    }
  }

  private async refreshBrief(): Promise<void> {
    try {
      const d: Record<string, string> = await WidgetData.build();
      this.bTitle = d['primeTitle'];
      this.bType = d['primeType'];
      this.bWhen = d['primeWhen'];
      this.bBig = d['primeBig'];
      this.bUnit = d['primeUnit'];
      this.bLeft = d['primeLeft'];
      this.bLevel = d['primeLevel'];
      this.bHead = d['head'];
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`悬停简报读取失败：${err.message}`);
    }
  }

  /** 紧急度 → 颜色。语义值由 WidgetData 给，UI 这一层才决定用什么颜色。 */
  private levelColor(): string {
    if (this.bLevel === 'past' || this.bLevel === 'urgent') {
      return Palette.DANGER;
    }
    if (this.bLevel === 'soon') {
      return Palette.ACCENT;
    }
    return Palette.PRIMARY;
  }

  // ────────────────────────────────────────────────── 数据变更收口
  /**
   * 数据变了：既重载页面，也把新数据推给桌面卡片，并让节奏哨兵重排提醒。
   *
   * 所有页面的写操作都通过 onChanged 收到这里（bump 是全应用唯一的「数据已变」信号），
   * 所以卡片一致性与哨兵排程都只需要在这一个地方收口 —— 各处写库后不必各自记得处理，
   * 少一处遗漏就少一种「桌面显示了过期数据 / 取消了的面试还在提醒」的可能。
   *
   * 两件事都不 await：都是跨进程 IPC，不该让用户点了保存还等它。
   */
  private bumpAndPush(): void {
    this.bump();
    if (this.hover) {
      this.refreshBrief();
    }
    const ctx: common.UIAbilityContext | undefined = WidgetRefresher.contextOf(this.getUIContext());
    WidgetRefresher.refreshAll(ctx);
    // 提醒排程必须跟着数据走：删掉一场面试后，系统里那条提醒要撤掉；
    // 新录进来的截止日要排进去。sync 内部按差分只动真正变化的部分，
    // 所以在这里"每次写库都调"的代价是可以接受的。
    if (ctx !== undefined) {
      // 本地提醒：刚录入一场"明天下午的面试"，这一句就让它立刻找到你
      Sentinel.evaluate(ctx, '数据变更')
        .then((n: number) => {
          if (n > 0) {
            Log.i(`哨兵(数据变更) 发出 ${n} 条提醒`);
          }
        })
        .catch((err: Error) => {
          Log.e(`哨兵(数据变更) 评估异常：${err.message}`);
        });
      // 系统代理提醒排程（需要配额，排不进去会如实降级）
      Sentinel.sync(ctx)
        .then((rep: SentinelReport) => {
          Log.i(`哨兵(数据变更) ${rep.message}`);
        })
        .catch((err: Error) => {
          Log.e(`哨兵(数据变更) 排程异常：${err.message}`);
        });
    }
  }

  private barStyle(label: string): SubTabBarStyle {
    const ls: LabelStyle = {
      selectedColor: Palette.ACCENT,
      unselectedColor: Palette.TX_3,
      font: { size: 15 }
    };
    return new SubTabBarStyle(label)
      .indicator({ color: Palette.ACCENT, height: 3, borderRadius: 2 })
      .selectedMode(SelectedMode.INDICATOR)
      .labelStyle(ls);
  }

  /**
   * 启动页。
   *
   * 它不只是"加载中"，还要回答一个更基本的问题：**这是个什么应用**。
   * 评委第一次打开、或者从桌面卡片按进来，看到的第一屏就是这里 ——
   * 只摆一个转圈，等于把最贵的一块位置空着。
   */
  @Builder
  splash() {
    Column() {
      Blank()

      Image($r('app.media.splash_logo'))
        .width(this.splashLogoSide())
        .height(this.splashLogoSide())
        .borderRadius(26)
        // 一圈蓝色光晕。图标自带深色的海面底，直接贴在页面底色上是一个生硬的方块；
        // 加了以后边界化开，更像灯塔本身在发光。
        .shadow({ radius: 36, color: '#4A9EFF59', offsetX: 0, offsetY: 0 })

      Text('灯塔')
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TX)
        .margin({ top: 26 })

      Text('把求职，变成一场有节奏的战役')
        .fontSize(14)
        .fontColor(Palette.TX_2)
        .margin({ top: 10 })

      Row({ space: 8 }) {
        this.splashChip('投递记录')
        this.splashChip('面试倒计时')
        this.splashChip('AI 复盘')
      }
      .margin({ top: 22 })

      Blank()

      Row({ space: 8 }) {
        LoadingProgress().width(15).height(15).color(Palette.PRIMARY)
        Text('正在点亮…').fontSize(12).fontColor(Palette.TX_3)
      }
      .margin({ bottom: 46 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
  }

  /** 启动页 logo 边长。矮屏（手机横屏）时收小，免得把下面的文案挤出屏幕。 */
  private splashLogoSide(): number {
    return this.compact ? 72 : 104;
  }

  @Builder
  splashChip(t: string) {
    Text(t)
      .fontSize(11)
      .fontColor(Palette.TX_2)
      .backgroundColor(Palette.PANEL_2)
      .borderRadius(10)
      .padding({ left: 11, right: 11, top: 5, bottom: 5 })
  }

  @Builder
  mainTabs() {
    Tabs({
      barPosition: this.sideNav ? BarPosition.Start : BarPosition.End,
      index: this.curTab
    }) {
      TabContent() {
        QuickRecordView({ tick: this.tick, onChanged: (): void => this.bumpAndPush() })
      }
      .tabBar(this.barStyle('快记'))

      TabContent() {
        MapView({ tick: this.tick, onGoto: (i: number): void => {
          this.curTab = i;
        } })
      }
      .tabBar(this.barStyle('地图'))

      TabContent() {
        ReviewView({ tick: this.tick, onChanged: (): void => this.bumpAndPush() })
      }
      .tabBar(this.barStyle('复盘'))

      TabContent() {
        ProfileView({ tick: this.tick, onChanged: (): void => this.bumpAndPush() })
      }
      .tabBar(this.barStyle('我的'))
    }
    .vertical(this.sideNav)
    .barWidth(this.sideNav ? this.sideW : '100%')
    .barHeight(this.sideNav ? '100%' : Metrics.TAB_H)
    .barBackgroundColor(Palette.PANEL)
    .backgroundColor(Palette.BG)
    .animationDuration(180)
    .layoutWeight(1)
    .onChange((index: number) => {
      this.curTab = index;
      // 切页即重载，保证四个页面的数字永远一致（本地库，代价可忽略）
      this.bump();
    })
  }

  /**
   * 悬停简报。
   *
   * 半折叠时手机能自己立在桌上，用户是**站着、不拿手**在看的，
   * 所以这一屏不做"等比例放大整个页面"，而是只回答一个问题：下一件事还有多久。
   * 其它信息（漏斗、复盘、AI）都留给下半区，需要时低头看。
   */
  @Builder
  briefingPane() {
    Column({ space: 14 }) {
      Row() {
        Text('悬停模式')
          .fontSize(11)
          .fontColor(Palette.BG)
          .backgroundColor(Palette.ACCENT)
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        Blank()
        Text(this.bHead)
          .fontSize(11.5)
          .fontColor(Palette.TX_3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      Row() {
        Column({ space: 7 }) {
          Text(this.bTitle)
            .fontSize(21)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TX)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 8 }) {
            Text(this.bType)
              .fontSize(11)
              .fontColor(this.levelColor())
              .backgroundColor(Palette.PANEL_2)
              .borderRadius(6)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            Text(this.bWhen)
              .fontSize(13)
              .fontColor(Palette.TX_2)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row({ space: 5 }) {
          Text(this.bBig)
            .fontSize(42)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.levelColor())
          Text(this.bUnit)
            .fontSize(13)
            .fontColor(Palette.TX_3)
            .margin({ bottom: 7 })
        }
        .alignItems(VerticalAlign.Bottom)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.bLeft)
        .fontSize(12.5)
        .fontColor(Palette.TX_3)
        .width('100%')
    }
    .width('100%')
    .height(this.winH * Layout.HOVER_TOP_RATIO)
    .padding({ left: Metrics.PAGE_PAD + 6, right: Metrics.PAGE_PAD + 6 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Palette.PANEL)
  }

  build() {
    Column() {
      if (!this.ready) {
        this.splash()
      } else if (this.hover && !this.compact) {
        // 悬停且系统给了整屏：上方简报 + 下方内容，中间留出折痕的安全距离
        this.briefingPane()
        Row().width('100%').height(Layout.CREASE_GAP)
        this.mainTabs()
      } else {
        this.mainTabs()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const w: number = Number.parseFloat(newArea.width.toString());
      const h: number = Number.parseFloat(newArea.height.toString());
      Layout.publish(w, h);
    })
  }
}
