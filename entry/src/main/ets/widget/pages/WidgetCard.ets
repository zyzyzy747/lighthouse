/**
 * 「灯塔 · 节奏哨兵」主卡片（2×4）。
 *
 * ⚠ 这个文件是**独立编译单元**，不能 import 应用里的任何代码（Repo / Theme / Types）。
 *   所有数据都通过 FormExtensionAbility 的 formBindingData 注入 LocalStorage，
 *   这里只负责摆放、配色、点击。要改数据口径请去 service/WidgetData.ets。
 *
 * 设计意图：卡片是「灯塔」的主入口而不是缩略图 ——
 *   ① 最紧急那个节点用大字倒计时做视觉锚点，扫一眼就知道还剩多久；
 *   ② 剩余节点压在下方两行，不抢视线但不丢失；
 *   ③ 右下角常驻 ＋，投递完回到桌面 3 秒补录一条，这是「服务找人」的最小闭环。
 *
 * ⚠ 倒计时只精确到「天 / 小时」：系统的定时刷新（updateDuration）最小粒度是 30 分钟，
 *   显示到分钟会立刻变成骗人的数字。宁可粗一点，也不能给用户假的精确感。
 */

let storageWidgetMain = new LocalStorage();

@Entry(storageWidgetMain)
@Component
struct WidgetCard {
  @LocalStorageProp('empty') empty: string = '1';
  @LocalStorageProp('head') head: string = '';
  @LocalStorageProp('total') total: string = '0';
  @LocalStorageProp('overdue') overdue: string = '0';
  @LocalStorageProp('overdueText') overdueText: string = '';

  @LocalStorageProp('primeTitle') primeTitle: string = '';
  @LocalStorageProp('primeType') primeType: string = '';
  @LocalStorageProp('primeWhen') primeWhen: string = '';
  @LocalStorageProp('primeBig') primeBig: string = '—';
  @LocalStorageProp('primeUnit') primeUnit: string = '';
  @LocalStorageProp('primeLeft') primeLeft: string = '';
  @LocalStorageProp('primeLevel') primeLevel: string = 'normal';

  @LocalStorageProp('sub1') sub1: string = '';
  @LocalStorageProp('sub2') sub2: string = '';
  @LocalStorageProp('more') more: string = '';
  @LocalStorageProp('stamp') stamp: string = '';

  /** 紧急度 → 颜色。语义由数据层给，颜色由卡片层定，两边不耦合。 */
  private accent(): Resource {
    if (this.primeLevel === 'urgent' || this.primeLevel === 'past') {
      return $r('app.color.card_warn');
    }
    if (this.primeLevel === 'soon') {
      return $r('app.color.card_accent');
    }
    return $r('app.color.card_ok');
  }

  /** 点卡片任意处：拉起应用（不带参数 = 停在上次那个页面） */
  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        'lh_target': 'home'
      }
    });
  }

  /** 点 ＋：拉起应用并直接落在「投递快记」页 */
  private openQuick(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        'lh_target': 'quick'
      }
    });
  }

  build() {
    Column() {
      // ── 顶栏：品牌 + 概览 + 快捷入口 ──
      Row() {
        Row() {
          // 用一个小圆点代替图标：不用额外资源，深浅色下都成立
          Row()
            .width(7)
            .height(7)
            .borderRadius(4)
            .backgroundColor(this.accent())
          Text('灯塔')
            .fontSize(12.5)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.card_title'))
            .margin({ left: 6 })
          Text(this.overdue !== '0' ? `· ${this.overdueText}` : `· ${this.head}`)
            .fontSize(10.5)
            .fontColor(this.overdue !== '0' ? $r('app.color.card_warn') : $r('app.color.card_faint'))
            .maxLines(1)
            .margin({ left: 5 })
            .layoutWeight(1)
        }
        .layoutWeight(1)

        Text('＋')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.card_accent'))
          .width(28)
          .height(24)
          .textAlign(TextAlign.Center)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_plus_bg'))
          .onClick(() => {
            this.openQuick();
          })
      }
      .width('100%')
      .height(26)
      .alignItems(VerticalAlign.Center)

      Row()
        .width('100%')
        .height(1)
        .backgroundColor($r('app.color.card_line'))
        .margin({ top: 6 })

      // ── 主体：左侧大字倒计时，右侧节点信息 ──
      Row() {
        Column() {
          Text(this.primeBig)
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.accent())
            .maxLines(1)
          Text(this.primeUnit)
            .fontSize(10.5)
            .fontColor(this.accent())
            .maxLines(1)
        }
        .width(70)
        .alignItems(HorizontalAlign.Start)

        Column() {
          Row() {
            Text(this.primeType)
              .fontSize(9.5)
              .fontColor($r('app.color.card_faint'))
              .borderRadius(3)
              .backgroundColor($r('app.color.card_plus_bg'))
              .padding({ left: 5, right: 5, top: 1.5, bottom: 1.5 })
            Text(this.primeLeft)
              .fontSize(10.5)
              .fontColor(this.accent())
              .maxLines(1)
              .margin({ left: 6 })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.primeTitle)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.card_title'))
            .maxLines(1)
            .margin({ top: 4 })

          Text(this.primeWhen)
            .fontSize(11.5)
            .fontColor($r('app.color.card_sub'))
            .maxLines(1)
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 4 })
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)

      // ── 次要节点：两行封顶，空串自动隐藏 ──
      if (this.empty === '1') {
        Text(this.primeLeft)
          .fontSize(10.5)
          .fontColor($r('app.color.card_faint'))
          .maxLines(1)
          .width('100%')
      } else {
        Column() {
          Row()
            .width('100%')
            .height(1)
            .backgroundColor($r('app.color.card_line'))
            .margin({ bottom: 5 })

          if (this.sub1.length > 0) {
            Text(this.sub1)
              .fontSize(11)
              .fontColor($r('app.color.card_sub'))
              .maxLines(1)
              .width('100%')
          }
          if (this.sub2.length > 0) {
            Text(this.sub2)
              .fontSize(11)
              .fontColor($r('app.color.card_sub'))
              .maxLines(1)
              .width('100%')
              .margin({ top: 2 })
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 13, right: 13, top: 11, bottom: 11 })
    .justifyContent(FlexAlign.Start)
    .onClick(() => {
      this.openApp();
    })
  }
}
