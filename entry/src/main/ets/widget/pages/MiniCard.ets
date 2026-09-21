/**
 * 「灯塔 · 下一件事」小卡片（2×2）。
 *
 * 与主卡的定位差别：主卡是"全局面板"，小卡是"一件事"——
 * 占地小所以信息必须收敛到只剩最紧急的那个节点，多一个数字都是噪音。
 * 适合放在桌面第一屏最顺手的位置。
 *
 * ⚠ 同样不能 import 应用代码，数据口径见 service/WidgetData.ets。
 */

let storageWidgetMini = new LocalStorage();

@Entry(storageWidgetMini)
@Component
struct MiniCard {
  @LocalStorageProp('empty') empty: string = '1';
  @LocalStorageProp('total') total: string = '0';
  @LocalStorageProp('overdue') overdue: string = '0';

  @LocalStorageProp('primeTitle') primeTitle: string = '';
  @LocalStorageProp('primeWhen') primeWhen: string = '';
  @LocalStorageProp('primeBig') primeBig: string = '—';
  @LocalStorageProp('primeUnit') primeUnit: string = '';
  @LocalStorageProp('primeLevel') primeLevel: string = 'normal';

  private accent(): Resource {
    if (this.primeLevel === 'urgent' || this.primeLevel === 'past') {
      return $r('app.color.card_warn');
    }
    if (this.primeLevel === 'soon') {
      return $r('app.color.card_accent');
    }
    return $r('app.color.card_ok');
  }

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
      // 顶栏：品牌点 + 名称 + 待办计数
      Row() {
        Row()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(this.accent())
        Text(this.overdue !== '0' ? '有新变化' : '灯塔')
          .fontSize(11)
          .fontColor($r('app.color.card_faint'))
          .margin({ left: 5 })
          .layoutWeight(1)
          .maxLines(1)
        Text('＋')
          .fontSize(13)
          .fontColor($r('app.color.card_accent'))
          .width(24)
          .height(20)
          .textAlign(TextAlign.Center)
          .borderRadius(10)
          .backgroundColor($r('app.color.card_plus_bg'))
          .onClick(() => {
            this.openQuick();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 中部：把大字倒计时压到底部，视觉重心落在数字上
      Blank()

      Row() {
        Text(this.primeBig)
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.accent())
          .maxLines(1)
        Text(this.primeUnit)
          .fontSize(10)
          .fontColor(this.accent())
          .margin({ left: 3, bottom: 4 })
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Text(this.primeTitle)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.card_title'))
        .maxLines(1)
        .width('100%')
        .margin({ top: 1 })

      Text(this.primeWhen)
        .fontSize(10.5)
        .fontColor($r('app.color.card_sub'))
        .maxLines(1)
        .width('100%')
        .margin({ top: 1 })
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: {
          'lh_target': 'map'
        }
      });
    })
  }
}
