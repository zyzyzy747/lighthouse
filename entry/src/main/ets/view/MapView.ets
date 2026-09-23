import { Palette, Metrics } from '../common/Theme';
import { JobMapCard } from './JobMapCard';
import { ApplicationRepo, FunnelStat, StatusCount } from '../repository/ApplicationRepo';
import { EventRepo } from '../repository/EventRepo';
import { STATUS_LIST, EventNode, getStatusMeta, getEventTypeMeta } from '../common/Types';
import { countdownText, humanDeadline } from '../common/Utils';
import { Log } from '../common/Logger';

/** @Styles 只能用通用属性 */
@Styles
function mapCard() {
  .padding(14)
  .backgroundColor(Palette.PANEL)
  .borderRadius(Metrics.CARD_RADIUS)
  .width('100%')
}

/** ⚠ fontColor/fontSize 是 Text 专有属性，必须走 @Extend(Text) */
@Extend(Text)
function mapCardHead() {
  .fontSize(13)
  .fontColor(Palette.TX_3)
  .width('100%')
}

/**
 * ⚠ 概览大数字一律用 @Extend + 内联，不要写成 statCell(value, label, color) 这种
 *   带值类型参数的 @Builder —— ArkUI V1 下 @Builder 按值传参不建立响应式依赖，
 *   数据变了数字不会动（要等组件重建才对）。详见 ProfileView 的同类注释。
 */
@Extend(Text)
function statValue() {
  .fontSize(24)
  .fontWeight(FontWeight.Bold)
}

@Extend(Text)
function statLabel() {
  .fontSize(11.5)
  .fontColor(Palette.TX_3)
}

/**
 * 作战地图。
 * 把「海投」这个模糊动作拆成看得见的漏斗与转化率 —— 这是本产品区别于清单类工具的核心。
 *
 * ⚠ 外层用 List 而不是 Scroll：Scroll 在内容不足一屏时会把内容沿滚动方向居中，
 *   表现为标题浮到屏幕中部。List 永远从顶部排。
 *
 * 一多：宽屏（≥840vp，手机横屏 / 平板）拆成左右两栏 ——
 *   左「投得怎么样」（漏斗 + 转化率），右「接下来做什么」（待办与逾期节点）。
 *   这两件事本来挤在一列里要来回滚，宽屏上分开放才用得上多出来的横向空间；
 *   而且两个 List 各自滚动，「看统计」和「看清单」互不打断。
 */
@Component
export struct MapView {
  @Prop @Watch('onTick') tick: number = 0;
  onGoto: (index: number) => void = (index: number): void => {};

  /** 宽屏双栏。⚠ @StorageProp 的参数必须写字面量（编译期求值），不能传常量变量 */
  @StorageProp('lhTwoPane') twoPane: boolean = false;

  @State funnel: FunnelStat = new FunnelStat();
  @State pending: EventNode[] = [];
  @State overdue: EventNode[] = [];
  @State loading: boolean = true;

  aboutToAppear(): void {
    this.reload();
  }

  onTick(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      this.funnel = await ApplicationRepo.funnel();
      this.pending = await EventRepo.allPending();
      this.overdue = await EventRepo.overdue();
      this.loading = false;
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`MapView reload failed: ${err.message}`);
    }
  }

  /** GROUP BY 出来的顺序不定，按漏斗固定顺序重排，且过滤掉 0 */
  private orderedBars(): StatusCount[] {
    const out: StatusCount[] = [];
    for (let i = 0; i < STATUS_LIST.length; i++) {
      const key: string = STATUS_LIST[i].key;
      let c: number = 0;
      for (let j = 0; j < this.funnel.byStatus.length; j++) {
        if (this.funnel.byStatus[j].status === key) {
          c = this.funnel.byStatus[j].count;
          break;
        }
      }
      if (c > 0) {
        out.push(new StatusCount(key, c));
      }
    }
    return out;
  }

  private maxCount(): number {
    let max: number = 0;
    for (let i = 0; i < this.funnel.byStatus.length; i++) {
      if (this.funnel.byStatus[i].count > max) {
        max = this.funnel.byStatus[i].count;
      }
    }
    return max;
  }

  @Builder
  barRow(s: StatusCount, max: number) {
    Row({ space: 10 }) {
      Text(getStatusMeta(s.status).label)
        .fontSize(12.5)
        .fontColor(Palette.TX_2)
        .width(52)
        .textAlign(TextAlign.End)
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(20)
          .backgroundColor(Palette.PANEL_2)
          .borderRadius(5)
        Row()
          .width(`${max > 0 ? Math.max(8, Math.round(s.count / max * 100)) : 0}%`)
          .height(20)
          .backgroundColor(getStatusMeta(s.status).color)
          .borderRadius(5)
      }
      .layoutWeight(1)
      .height(20)
      Text(`${s.count}`)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.TX)
        .width(28)
        .textAlign(TextAlign.End)
    }
    .width('100%')
  }

  @Builder
  eventRow(node: EventNode) {
    Row({ space: 10 }) {
      Column()
        .width(3)
        .height(32)
        .backgroundColor(getEventTypeMeta(node.type).color)
        .borderRadius(2)
      Column({ space: 3 }) {
        Text(node.title)
          .fontSize(13.5)
          .fontColor(Palette.TX)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${getEventTypeMeta(node.type).label} · ${humanDeadline(node.happenAt)}`)
          .fontSize(11.5)
          .fontColor(Palette.TX_3)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(countdownText(node.happenAt))
        .fontSize(12)
        .fontColor(node.happenAt < Date.now() ? Palette.DANGER : Palette.ACCENT)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  // ────────────────────────────────── 各区块（双栏时被拆到不同列里复用）

  @Builder
  headItem(sub: string) {
    ListItem() {
      Row() {
        Text('作战地图')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.TX)
        Blank()
        Text(sub)
          .fontSize(11.5)
          .fontColor(Palette.TX_3)
      }
      .width('100%')
      .padding({ top: 8 })
    }
  }

  @Builder
  emptyItem() {
    ListItem() {
      Column({ space: 10 }) {
        Text('地图还是空的')
          .fontSize(15)
          .fontColor(Palette.TX_2)
        Text('先去「快记」记下第一条投递，这里会自动长出漏斗和转化率')
          .fontSize(12.5)
          .fontColor(Palette.TX_3)
          .textAlign(TextAlign.Center)
        Button('去记一条')
          .fontSize(14)
          .fontColor(Palette.BG)
          .backgroundColor(Palette.ACCENT)
          .height(38)
          .onClick(() => {
            this.onGoto(0);
          })
      }
      .width('100%')
      .padding({ top: 50, bottom: 50 })
    }
  }

  /**
   * 真实求职地图。
   *
   * 放在漏斗**上面**而不是下面：用户进这一页先想知道的是「接下来往哪跑」，
   * 转化率是要静下来看的数字。放在下面要滚两屏才见得到地图，等于没有。
   */
  @Builder
  mapCardItem() {
    ListItem() {
      JobMapCard({ tick: this.tick })
    }
  }

  @Builder
  overviewItem() {
    ListItem() {
      Column({ space: 12 }) {
        Text('概览').mapCardHead()
        Row() {
          Column({ space: 4 }) {
            Text(`${this.funnel.total}`).statValue().fontColor(Palette.TX)
            Text('总投递').statLabel()
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Column({ space: 4 }) {
            Text(`${this.funnel.active}`).statValue().fontColor(Palette.PRIMARY)
            Text('推进中').statLabel()
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Column({ space: 4 }) {
            Text(`${this.funnel.interview}`).statValue().fontColor(Palette.ACCENT)
            Text('进面试').statLabel()
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Column({ space: 4 }) {
            Text(`${this.funnel.offer}`).statValue().fontColor(Palette.OK)
            Text('Offer').statLabel()
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        Row() {
          Column({ space: 4 }) {
            Text(`${Math.round(this.funnel.interviewRate * 100)}%`)
              .statValue()
              .fontColor(Palette.ACCENT)
            Text('简历→面试').statLabel()
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Column({ space: 4 }) {
            Text(`${Math.round(this.funnel.offerRate * 100)}%`)
              .statValue()
              .fontColor(Palette.OK)
            Text('面试→Offer').statLabel()
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
      }
      .mapCard()
    }
  }

  @Builder
  barsItem() {
    ListItem() {
      Column({ space: 12 }) {
        Text('漏斗分布').mapCardHead()
        ForEach(this.orderedBars(), (s: StatusCount) => {
          this.barRow(s, this.maxCount())
        }, (s: StatusCount) => `bar-${s.status}-${s.count}`)
      }
      .mapCard()
    }
  }

  @Builder
  pendingItems() {
    if (this.pending.length > 0) {
      ListItem() {
        Column({ space: 4 }) {
          Text(`待办节点 · ${this.pending.length}`).mapCardHead()
          ForEach(this.pending, (node: EventNode) => {
            this.eventRow(node)
          }, (node: EventNode) => `p-${node.id}-${node.happenAt}-${node.title}`)
        }
        .mapCard()
      }
    }
  }

  @Builder
  overdueItems() {
    if (this.overdue.length > 0) {
      ListItem() {
        Column({ space: 4 }) {
          Text(`已逾期未处理 · ${this.overdue.length}`).mapCardHead()
          ForEach(this.overdue, (node: EventNode) => {
            this.eventRow(node)
          }, (node: EventNode) => `o-${node.id}`)
        }
        .mapCard()
      }
    }
  }

  @Builder
  quietItem(text: string) {
    ListItem() {
      Column({ space: 8 }) {
        Text(text)
          .fontSize(13.5)
          .fontColor(Palette.TX_2)
        Text('节点都清空了，节奏很好')
          .fontSize(12)
          .fontColor(Palette.TX_3)
      }
      .width('100%')
      .padding({ top: 34, bottom: 34 })
      .alignItems(HorizontalAlign.Center)
    }
  }

  @Builder
  bottomPad() {
    ListItem() {
      Row().height(20)
    }
  }

  build() {
    if (this.twoPane) {
      // ── 宽屏双栏：左「投得怎么样」，右「接下来做什么」
      Row({ space: Metrics.GAP }) {
        List({ space: 12 }) {
          this.headItem('按状态实时统计')
          if (this.funnel.total === 0) {
            this.emptyItem()
          } else {
            this.mapCardItem()
            this.overviewItem()
            this.barsItem()
          }
          this.bottomPad()
        }
        .layoutWeight(1)
        .height('100%')
        .scrollBar(BarState.Off)

        List({ space: 12 }) {
          this.headItem(`${this.pending.length + this.overdue.length} 个待处理`)
          if (this.funnel.total === 0) {
            this.quietItem('还没有投递记录')
          } else {
            this.pendingItems()
            this.overdueItems()
            if (this.pending.length === 0 && this.overdue.length === 0) {
              this.quietItem('暂无待办节点')
            }
          }
          this.bottomPad()
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
      List({ space: 12 }) {
        this.headItem('按状态实时统计')

        if (this.funnel.total === 0) {
          this.emptyItem()
        } else {
          this.mapCardItem()
          this.overviewItem()
          this.barsItem()
          this.pendingItems()
          this.overdueItems()
        }

        this.bottomPad()
      }
      .width('100%')
      .height('100%')
      .padding({ left: Metrics.PAGE_PAD, right: Metrics.PAGE_PAD })
      .scrollBar(BarState.Off)
      .backgroundColor(Palette.BG)
    }
  }
}
