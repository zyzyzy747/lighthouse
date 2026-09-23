import { Palette, Metrics, Tint } from '../common/Theme';
import { ApplicationRepo, FunnelStat } from '../repository/ApplicationRepo';
import { ReviewRepo } from '../repository/ReviewRepo';
import { EventRepo } from '../repository/EventRepo';
import { KvRepo } from '../repository/KvRepo';
import { AvatarStore } from '../service/AvatarStore';
import { Application, EventNode, getEventTypeMeta, getStatusMeta } from '../common/Types';
import { humanDeadline, dayDiff } from '../common/Utils';
import { Log } from '../common/Logger';

/**
 * 资质标注。这是**已核验的事实**（编码可在华为开发者官网查），不是装饰。
 * ⛔ 别往这里加没真正拿到过的赛事或证书。
 */
const CERT_TEXT: string = '华为 HarmonyOS 应用开发者 · 高级认证';
/** 交稿署名。比赛信息只在这里出现一次，改队名只需改这一行 */
const FOOT_TEXT: string = '灯塔 v1.0 · 想睡觉队';

/** 跟进提醒的阈值：投出去这么多天还没动静，就该催了 */
const STALE_DAYS: number = 7;

/** 漏斗的一个刻度。ArkTS 的 ForEach 要真正的类/接口，不能用匿名对象字面量 */
class FunnelStep {
  label: string = '';
  value: number = 0;
  color: Resource = Palette.PRIMARY;

  constructor(label: string, value: number, color: Resource) {
    this.label = label;
    this.value = value;
    this.color = color;
  }
}

/** @Styles 只能用通用属性 */
@Styles
function panel() {
  .padding(14)
  .backgroundColor(Palette.PANEL)
  .borderRadius(Metrics.CARD_RADIUS)
  .width('100%')
}

/** ⚠ fontColor/fontSize 是 Text 专有属性，必须走 @Extend(Text) */
@Extend(Text)
function cardHead() {
  .fontSize(13)
  .fontColor(Palette.TX_3)
}

@Extend(Text)
function chipText() {
  .fontSize(11)
  .fontColor(Palette.TX_2)
  .backgroundColor(Palette.PANEL_2)
  .borderRadius(Metrics.CHIP_RADIUS)
  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
}

/**
 * 我的页。
 *
 * 这里只回答两件事：**我是谁**、**我这阵子投得怎么样**。
 * 所有开关（外观 / AI / 提醒 / 卡片 / 演示数据 / 关于）都搬去「设置」了 ——
 * 它们是"改一次就再也不动"的东西，堆在个人页里只会把真正要看的数字挤出屏幕。
 *
 * 布局取舍（2026-09-22 实测后重做）：
 *   改前只有三张卡，内容总高 463vp，而可视区 663vp。ArkUI 的 `Scroll` 在内容不足一屏时
 *   **会把内容垂直居中**，于是上下各空 100vp（实测 350px / 351px，差 1px），
 *   看起来就是"内容挤在中间"。两处一起治：
 *     ① `.align(Alignment.Top)` —— 把内容钉到顶部（治标，空白归到一处）；
 *     ② 「我的数据」从 5 行干列表改成**投递漏斗**，再补「最近要跑」「该催一催了」——
 *        治本：空白只能靠**有信息量的内容**去占。
 *   ⛔ 别用 SpaceBetween 或拉高卡片去"填满"：用空白填空白，只会让内容更稀、更难看。
 *
 * ⚠ 踩坑记录（务必保留这个写法）：
 * ArkUI V1 的 @Builder **按值传参不会建立响应式依赖** ——
 * 形如 `this.kvRow('投递记录', `${this.funnel.total} 条`, c)` 的写法，
 * @State funnel 变化后 Builder 内的文字**不会刷新**（组件重建时才更新，
 * 表现为"点完按钮数字不动，切走再切回才对"）。
 * 因此所有动态数字一律用**无参 @Builder + @Extend 属性 + 内联节点**输出。
 */
@Component
export struct ProfileView {
  @Prop @Watch('onTick') tick: number = 0;
  onChanged: () => void = (): void => {};
  /** 去设置页。设置是二级页，不占底部 Tab。 */
  onOpenSettings: () => void = (): void => {};
  /** 去地图页。「最近要跑」的出口 —— 地图是主 Tab，跳过去比在卡片里画小图更省 */
  onOpenMap: () => void = (): void => {};

  @State funnel: FunnelStat = new FunnelStat();
  @State reviewCount: number = 0;
  @State analyzed: number = 0;
  @State pendingNodes: number = 0;
  /** 最近的待办节点（最多 3 条） */
  @State nextNodes: EventNode[] = [];
  /** 投出去太久没动静的（卡片里最多列 2 条）。空数组 ⇒ 整张卡不出现 */
  @State stale: Application[] = [];
  /** 符合条件的**总数**。⚠ 不能拿 `stale.length` 当总数 —— 那是截断后的，会少报 */
  @State staleTotal: number = 0;

  /** 档案只在设置页里改，这里负责显示。 */
  @State pfName: string = '';
  @State pfTarget: string = '';
  /** 自定义头像的 uri；空串 ⇒ 用内置默认头像。同样只在设置页里改。 */
  @State avatarSrc: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  onTick(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      this.funnel = await ApplicationRepo.funnel();
      this.reviewCount = await ReviewRepo.count();
      this.analyzed = await ReviewRepo.analyzedCount();
      this.pendingNodes = await EventRepo.pendingCount();
      this.nextNodes = await EventRepo.upcoming(3);
      const s: Application[] = await ApplicationRepo.staleApplied(STALE_DAYS);
      this.staleTotal = s.length;
      this.stale = s.length > 2 ? [s[0], s[1]] : s;
      const all: Record<string, string> = await KvRepo.getAll();
      this.pfName = all['profile_name'] === undefined ? '' : all['profile_name'];
      this.pfTarget = all['profile_target'] === undefined ? '' : all['profile_target'];
      this.avatarSrc = await AvatarStore.imageSrc();
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`ProfileView reload failed: ${err.message}`);
    }
  }

  /* ======================= 取值（Builder 内不能声明局部变量） ======================= */

  /** 四个刻度。数字全部来自仓库，**不在 UI 里另算一套**，否则两页对不上 */
  private steps(): FunnelStep[] {
    return [
      new FunnelStep('投递', this.funnel.total, Palette.PRIMARY),
      new FunnelStep('推进', this.funnel.active, Palette.PURPLE),
      new FunnelStep('面试', this.funnel.interview, Palette.ACCENT),
      new FunnelStep('Offer', this.funnel.offer, Palette.OK)
    ];
  }

  /**
   * 刻度条的宽度（百分比）。
   * 下限留 10%：值为 0 的那一档如果宽度真是 0，视觉上会像"卡片缺了一块"。
   */
  private pct(v: number): number {
    const base: number = this.funnel.total > 0 ? this.funnel.total : 1;
    return Math.max(10, Math.round(v * 100 / base));
  }

  /** 面试转化率，直接用仓库算好的那份（分母口径是"真正投出去并推进过的"） */
  private rateText(): string {
    return `面试转化率 ${Math.round(this.funnel.interviewRate * 100)}%`;
  }

  /** 还剩几天。和「快记」的倒计时同一口径，别另起一套 */
  private leftDays(ts: number): string {
    const d: number = dayDiff(ts);
    return d <= 0 ? '今天' : `${d} 天`;
  }

  /** 已经静默几天 */
  private quietDays(ts: number): number {
    const d: number = -dayDiff(ts);
    return d < 0 ? 0 : d;
  }

  /* ================================ 卡片 ================================ */

  @Builder
  identityCard() {
    Row({ space: 12 }) {
      // 头像：用户在设置页换过就用自己的图，否则用内置默认图。
      // ⚠ 两条分支都必须是 Image —— 混用 Image 与 Text 时宽高对齐口径不同，
      //   右侧文字的垂直对齐会跟着飘。
      if (this.avatarSrc.length > 0) {
        Image(this.avatarSrc)
          .width(52)
          .height(52)
          .borderRadius(26)
          .objectFit(ImageFit.Cover)
          .borderWidth(1)
          .borderColor(Palette.LINE)
      } else {
        Image($rawfile('avatar_default.png'))
          .width(52)
          .height(52)
          .borderRadius(26)
          .objectFit(ImageFit.Cover)
          .borderWidth(1)
          .borderColor(Palette.LINE)
      }

      Column({ space: 4 }) {
        Text(this.pfName.length > 0 ? this.pfName : '还没有填称呼')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pfName.length > 0 ? Palette.TX : Palette.TX_3)
        Text(this.pfTarget.length > 0 ? this.pfTarget : '目标方向也没填')
          .fontSize(12.5)
          .fontColor(Palette.TX_3)
        // 资质。放在身份卡里而不是单开一卡：它本来就是"我是谁"的一部分，
        // 而且这是评委一眼能看到的加分项。
        Text(CERT_TEXT)
          .fontSize(10.5)
          .fontColor(Palette.PRIMARY)
          .backgroundColor(Tint.PRIMARY)
          .borderRadius(Metrics.CHIP_RADIUS)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .panel()
  }

  /** 投递漏斗。四档 + 每档一条按比例的长度条 —— 一眼看出"投得多、进得少" */
  @Builder
  funnelCard() {
    Column({ space: 10 }) {
      Row() {
        Text('我的数据').cardHead()
        Blank()
        Text(this.rateText())
          .fontSize(11.5)
          .fontColor(Palette.PRIMARY)
      }
      .width('100%')

      Row({ space: 10 }) {
        ForEach(this.steps(), (s: FunnelStep) => {
          Column({ space: 5 }) {
            Text(`${s.value}`)
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor(Palette.TX)
            // 轨道 + 填充两层：只画填充的话，比例感全靠脑补
            Row() {
              Row()
                .width(`${this.pct(s.value)}%`)
                .height(5)
                .backgroundColor(s.color)
                .borderRadius(3)
            }
            .width('100%')
            .height(5)
            .backgroundColor(Palette.PANEL_2)
            .borderRadius(3)

            Text(s.label)
              .fontSize(11.5)
              .fontColor(Palette.TX_3)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
          // ⚠⚠ key 里**必须带上 value**。ForEach 是按 key 缓存的：只写 `fs-投递` 的话，
          //   数据到位后 key 没变 ⇒ 这一格**不会重建**，屏幕上是首次渲染时的 0，
          //   而同一张卡里不在 ForEach 内的「面试转化率」却正常刷新 ——
          //   表现为"数字全是 0，百分比却是对的"这种自相矛盾的画面。
          //   （MapView 的 `bar-${status}-${count}` 早就是这么写的，原因相同。）
        }, (s: FunnelStep) => `fs-${s.label}-${s.value}`)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Divider().color(Palette.LINE).strokeWidth(1)

      // 这三项不进漏斗（复盘和能力分析不是投递阶段），但都是"我这阵子干了什么"，别丢
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        Text(`待办节点 ${this.pendingNodes} 个`).chipText().margin({ right: 6, bottom: 6 })
        Text(`面试复盘 ${this.reviewCount} 场`).chipText().margin({ right: 6, bottom: 6 })
        Text(`能力分析 ${this.analyzed} 场`).chipText().margin({ right: 6, bottom: 6 })
      }
      .width('100%')
    }
    .panel()
  }

  /** 最近要跑。整块可点 ⇒ 去地图（那里有真地图和坐标） */
  @Builder
  nextCard() {
    Column({ space: 9 }) {
      Row() {
        Text('最近要跑').cardHead()
        Blank()
        Text('去看地图 ›')
          .fontSize(11.5)
          .fontColor(Palette.PRIMARY)
      }
      .width('100%')
      .onClick(() => {
        this.onOpenMap();
      })

      if (this.nextNodes.length === 0) {
        Text('没有待办节点。去「快记」补一个笔试或面试时间，这里会按倒计时排好。')
          .fontSize(11.5)
          .fontColor(Palette.TX_3)
          .lineHeight(17)
          .width('100%')
      } else {
        ForEach(this.nextNodes, (e: EventNode) => {
          Row({ space: 9 }) {
            // 左侧色条：用事件类型的颜色，一眼分清是笔试还是面试
            Row()
              .width(3)
              .height(30)
              .backgroundColor(getEventTypeMeta(e.type).color)
              .borderRadius(2)

            Column({ space: 3 }) {
              Text(e.title)
                .fontSize(13.5)
                .fontColor(Palette.TX)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(`${getEventTypeMeta(e.type).label} · ${humanDeadline(e.happenAt)}`)
                .fontSize(11)
                .fontColor(Palette.TX_3)
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text(this.leftDays(e.happenAt))
              .fontSize(11.5)
              .fontColor(Palette.ACCENT)
              .backgroundColor(Tint.ACCENT)
              .borderRadius(Metrics.CHIP_RADIUS)
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          }
          .width('100%')
          // ⚠ 同上一处：key 必须带上会变的内容，否则节点时间改了界面不跟着改
        }, (e: EventNode) => `nx-${e.id}-${e.happenAt}-${e.title}`)
      }
    }
    .panel()
  }

  /** 该催一催了。没东西可催时**整张卡不出现** —— 空态文案只会白占地方 */
  @Builder
  staleCard() {
    if (this.stale.length > 0) {
      Column({ space: 9 }) {
        Row() {
          Text(`投出去 ${STALE_DAYS} 天没动静`).cardHead()
          Blank()
          Text(`${this.staleTotal} 家`)
            .fontSize(11.5)
            .fontColor(Palette.DANGER)
        }
        .width('100%')

        ForEach(this.stale, (a: Application) => {
          Row({ space: 9 }) {
            Column({ space: 3 }) {
              Text(`${a.company} · ${a.position}`)
                .fontSize(13.5)
                .fontColor(Palette.TX)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(`投出去 ${this.quietDays(a.updatedAt)} 天没有更新`)
                .fontSize(11)
                .fontColor(Palette.TX_3)
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            // 这里只标状态，不做假按钮 —— 页面上不放"点了没反应"的东西
            Text(getStatusMeta(a.status).label)
              .fontSize(11.5)
              .fontColor(Palette.ACCENT)
              .backgroundColor(Tint.ACCENT)
              .borderRadius(Metrics.CHIP_RADIUS)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          }
          .width('100%')
          // ⚠ key 带上 updatedAt：跟进之后"静默天数"要立刻变，不能停在旧节点上
        }, (a: Application) => `st-${a.id}-${a.updatedAt}`)

        Text('催之前先在「复盘」里看一眼上次聊到哪，别重复问同一个问题。')
          .fontSize(11)
          .fontColor(Palette.TX_3)
          .width('100%')
      }
      .panel()
    }
  }

  /** 设置入口。副标题把里面有什么写出来，省得用户猜。 */
  @Builder
  settingsEntry() {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text('设置')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TX)
        Text('外观 · AI 引擎 · 提醒 · 桌面卡片 · 关于')
          .fontSize(11.5)
          .fontColor(Palette.TX_3)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(22)
        .fontColor(Palette.TX_3)
    }
    .width('100%')
    .panel()
    .onClick(() => {
      this.onOpenSettings();
    })
  }

  @Builder
  content() {
    Column({ space: Metrics.GAP }) {
      Row() {
        Text('我的')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.TX)
        Blank()
      }
      .width('100%')
      .padding({ top: 8, bottom: 2 })

      this.identityCard()
      this.funnelCard()
      this.nextCard()
      this.staleCard()
      this.settingsEntry()

      // 收口。别让页面以一片空白结束 —— 顺便把队名留在评委眼前
      Text(FOOT_TEXT)
        .fontSize(11)
        .fontColor(Palette.TX_3)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 2, bottom: 6 })
    }
    .width('100%')
    .padding({ left: Metrics.PAGE_PAD, right: Metrics.PAGE_PAD })
  }

  build() {
    // 个人页不拆双栏：卡片都是满宽的信息块，拆了反而两边都空。
    Scroll() {
      this.content()
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .backgroundColor(Palette.BG)
    // ⚠ 必须显式钉顶部：Scroll 在内容不足一屏时**默认垂直居中**，
    //   表现为"上下各留一块一样大的空白"（实测 350px/351px）。详见文件头。
    .align(Alignment.Top)
  }
}
