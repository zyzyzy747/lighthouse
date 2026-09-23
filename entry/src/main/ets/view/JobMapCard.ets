import { MapComponent, map, mapCommon } from '@kit.MapKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Palette, Metrics } from '../common/Theme';
import { ApplicationRepo } from '../repository/ApplicationRepo';
import { EventRepo } from '../repository/EventRepo';
import { Application, EventNode, getStatusMeta, getEventTypeMeta } from '../common/Types';
import { PlaceResolver, Place } from '../service/PlaceResolver';
import { countdownText } from '../common/Utils';
import { Log } from '../common/Logger';

/**
 * 一个「要去的地点」= 一家公司 + 它最近的节点 + 解析出来的真实坐标。
 *
 * ⚠ 为什么把 place 整个塞进来而不是只存经纬度：标记点要显示「这坐标是怎么来的」
 *   （真 POI / 园区近似 / 城市中心），答辩时一句「准不准」能立刻答上来。
 */
class JobPoint {
  company: string = '';
  city: string = '';
  status: string = '';
  eventLabel: string = '';
  happenAt: number = 0;
  place: Place = new Place('', '', 0, 0, '');

  constructor(company: string, city: string, status: string, eventLabel: string, happenAt: number, place: Place) {
    this.company = company;
    this.city = city;
    this.status = status;
    this.eventLabel = eventLabel;
    this.happenAt = happenAt;
    this.place = place;
  }
}

/**
 * 城市筛选里「不筛选」那一档。
 * ⚠ 用「全部」而不是空字符串：空串在 ArkTS 里做相等判断容易被当成 falsy 吃掉，
 *   而且 chip 上要显示的文字就是它，省一次映射。
 */
const ALL_CITIES: string = '全部';

/**
 * 真实求职地图。
 *
 * 用华为 Map Kit 的 MapComponent 画真地图，把「接下来要跑的面试地点」打成标记。
 * 这与上面那个漏斗是两件事：漏斗回答「投得怎么样」，地图回答「下一步要去哪」。
 *
 * ⚠⚠ 三条保命设计，都是被现实逼出来的：
 *
 *  ① **地图可能整个画不出来** —— 最常见的原因是签名 Profile 里没有地图权益
 *     （DevEco 默认自动签名**不含** Map Kit）。此时 MapComponent 的 callback 会
 *     拿到 err，界面必须降级成文字清单，而不是留一块白板让人以为卡了。
 *
 *  ② **坐标解析分三级降级**（详情见 PlaceResolver）：真 POI → 园区近似 → 城市中心。
 *     断网时地点搜索会失败，没有兜底就是空地图。
 *
 *  ③ **标记要在地图就绪之后再加** —— MapComponentController 是异步给的。
 *     数据先到、地图后到和地图先到、数据后到，两种顺序都得能画出点，
 *     所以 pushMarkers() 在两处都会调，内部自己判是否两边都齐了。
 */
@Component
export struct JobMapCard {
  @Prop @Watch('onTick') tick: number = 0;

  @State private points: JobPoint[] = [];
  @State private cities: string[] = [];
  @State private city: string = ALL_CITIES;
  @State private mapOk: boolean = false;
  @State private mapDead: boolean = false;
  @State private deadMsg: string = '';
  @State private summary: string = '正在定位你要去的地方…';
  @State private loading: boolean = true;

  private controller: map.MapComponentController | undefined = undefined;
  /** 防并发：tick 抖一下就会 reload，解析是异步的，不加闸会重复打标记 */
  private busy: boolean = false;

  /** 默认视野：武汉。⛔ target 是**必填**（MapOptions.position 非可选），不传直接建不了图 */
  private mapOptions: mapCommon.MapOptions = {
    position: {
      target: { latitude: 30.5928, longitude: 114.3055 },
      zoom: 11
    }
  };

  /**
   * ⚠ 这里刻意不写 AsyncCallback<T>：那个类型没有稳定的公开导出路径，
   *   而它的结构就是 `(err: BusinessError, data: T) => void`，用内联签名等价且省一个依赖。
   */
  private mapCallback: (err: BusinessError, controller: map.MapComponentController) => void =
    (err: BusinessError, controller: map.MapComponentController): void => {
      if (err) {
        // 白屏的唯一可信判定在这里。code 打进日志，排查时能直接对上官方 FAQ 的条目
        this.mapDead = true;
        this.deadMsg = `code=${err.code}`;
        Log.e(`地图自检结论：FAIL（MapComponent 初始化失败 code=${err.code} ${err.message}）`);
        return;
      }
      this.controller = controller;
      this.mapOk = true;
      Log.i('地图自检结论：PASS（MapComponent 初始化成功）');
      this.pushMarkers();
      this.focus(this.city);
    };

  aboutToAppear(): void {
    this.reload();
  }

  onTick(): void {
    this.reload();
  }

  // ───────────────────────────────────────────── 数据

  private async reload(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const apps: Application[] = await ApplicationRepo.listAll();
      const events: EventNode[] = await EventRepo.upcoming(50);

      // 只画「还要去」的：已终止 / 自己放弃 / 还没投的不算目的地
      const picked: Application[] = [];
      for (let i: number = 0; i < apps.length; i++) {
        if (getStatusMeta(apps[i].status).inFunnel) {
          picked.push(apps[i]);
        }
      }

      // 有临近节点的排前面 —— 「明天下午两点要去光庭信息」比「三周前投了某某」更该出现在地图上
      picked.sort((a: Application, b: Application): number => {
        return this.nearestHappen(events, a.id) - this.nearestHappen(events, b.id);
      });

      const ctx: common.Context = getContext(this) as common.Context;
      const out: JobPoint[] = [];
      const cap: number = picked.length < 8 ? picked.length : 8;
      for (let i: number = 0; i < cap; i++) {
        const a: Application = picked[i];
        const p: Place = await PlaceResolver.resolve(ctx, a.company, a.city);
        const ev: EventNode | undefined = this.nextEvent(events, a.id);
        out.push(new JobPoint(
          a.company,
          a.city,
          a.status,
          ev !== undefined ? `${getEventTypeMeta(ev.type).label} · ${countdownText(ev.happenAt)}` : getStatusMeta(a.status).label,
          ev !== undefined ? ev.happenAt : 0,
          p
        ));
      }

      this.points = out;
      this.loading = false;

      // 城市列表：按出现次数从多到少（用户最关心的城市排最前）
      const tally: string[] = [];
      const cnt: number[] = [];
      for (let i: number = 0; i < out.length; i++) {
        const c: string = out[i].city;
        const at: number = tally.indexOf(c);
        if (at < 0) {
          tally.push(c);
          cnt.push(1);
        } else {
          cnt[at] = cnt[at] + 1;
        }
      }
      for (let i: number = 0; i < tally.length; i++) {
        for (let j: number = i + 1; j < tally.length; j++) {
          if (cnt[j] > cnt[i]) {
            const tc: string = tally[i]; tally[i] = tally[j]; tally[j] = tc;
            const tn: number = cnt[i]; cnt[i] = cnt[j]; cnt[j] = tn;
          }
        }
      }
      this.cities = tally;

      // 当前选中的城市如果没数据了（换账号/清数据），退回「全部」，否则地图会是空的
      if (this.city !== ALL_CITIES && tally.indexOf(this.city) < 0) {
        this.city = ALL_CITIES;
      }

      this.summary = out.length > 0 ? `${this.visible().length} 个地点 · ${tally.length} 座城市` : '还没有要跑的地点';
      Log.i(`地图标记 ${out.length} 个地点：${this.oneLine(out)}`);

      this.pushMarkers();
      this.focus(this.city);
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`JobMapCard reload failed: ${err.message}`);
      this.loading = false;
    }
    this.busy = false;
  }

  private nearestHappen(events: EventNode[], appId: number): number {
    let best: number = 0;
    for (let i: number = 0; i < events.length; i++) {
      if (events[i].appId === appId && events[i].done === false) {
        const t: number = events[i].happenAt;
        if (best === 0 || t < best) {
          best = t;
        }
      }
    }
    return best;
  }

  private nextEvent(events: EventNode[], appId: number): EventNode | undefined {
    let best: EventNode | undefined = undefined;
    for (let i: number = 0; i < events.length; i++) {
      if (events[i].appId === appId && events[i].done === false) {
        if (best === undefined || events[i].happenAt < best.happenAt) {
          best = events[i];
        }
      }
    }
    return best;
  }

  /** 自检/日志用：把地点压成一行 */
  private oneLine(ps: JobPoint[]): string {
    let s: string = '';
    for (let i: number = 0; i < ps.length; i++) {
      s += `${ps[i].company}(${ps[i].place.source}) `;
    }
    return s;
  }

  // ───────────────────────────────────────────── 地图

  /** 当前城市筛选下要显示的点 */
  private visible(): JobPoint[] {
    if (this.city === ALL_CITIES) {
      return this.points;
    }
    const out: JobPoint[] = [];
    for (let i: number = 0; i < this.points.length; i++) {
      if (this.points[i].city === this.city) {
        out.push(this.points[i]);
      }
    }
    return out;
  }

  /**
   * 把镜头对准当前筛选出来的点。
   *
   * 为什么不给标记做显隐切换：城市之间的点本来就隔着几百公里，
   * 镜头移到武汉时上海那几个点**天然在屏幕外**，效果和"隐藏"一样，
   * 但少一次 API 调用、少一份状态要同步 —— 少一个会不同步的东西。
   */
  private focus(city: string): void {
    // ⚠ 先记下选择再判地图 —— 反过来写的话，地图还没就绪时用户点的城市会被丢掉，
    //   等地图起来时镜头还停在默认位置，而筛选条上已经高亮了另一个城市。
    this.city = city;
    if (this.controller === undefined) {
      return;
    }
    const sel: JobPoint[] = this.visible();
    if (sel.length === 0) {
      return;
    }

    let minLat: number = 90;
    let maxLat: number = -90;
    let minLng: number = 180;
    let maxLng: number = -180;
    for (let i: number = 0; i < sel.length; i++) {
      const q: JobPoint = sel[i];
      if (q.place.lat < minLat) { minLat = q.place.lat; }
      if (q.place.lat > maxLat) { maxLat = q.place.lat; }
      if (q.place.lng < minLng) { minLng = q.place.lng; }
      if (q.place.lng > maxLng) { maxLng = q.place.lng; }
    }

    if (sel.length === 1) {
      this.controller.moveCamera(map.newLatLng({ latitude: minLat, longitude: minLng }, 13));
    } else {
      const b: mapCommon.LatLngBounds = {
        northeast: { latitude: maxLat, longitude: maxLng },
        southwest: { latitude: minLat, longitude: minLng }
      };
      this.controller.moveCamera(map.newLatLngBounds(b, 60));
    }
    Log.i(`地图视野已调整：${city}（${sel.length} 点）`);
  }

  /**
   * 打标记。
   *
   * ⚠ 这个方法会在「地图就绪」和「数据到位」两个时机各调一次，
   *   所以开头必须自己判两边是否都齐 —— 否则先到的那一方会白干，
   *   表现为「地图出来了但一个点都没有」，而且再也补不上。
   */
  private pushMarkers(): void {
    if (this.controller === undefined || this.points.length === 0) {
      return;
    }
    const c: map.MapComponentController = this.controller;

    for (let i: number = 0; i < this.points.length; i++) {
      const p: JobPoint = this.points[i];
      const opt: mapCommon.MarkerOptions = {
        position: { latitude: p.place.lat, longitude: p.place.lng },
        title: p.company,
        // 点开信息窗第一眼要看到「这家在哪个城市 / 什么状态」，而不只是公司名
        snippet: `${p.city} · ${p.eventLabel}`,
        clickable: true
      };
      c.addMarker(opt).then((m: map.Marker): void => {
        Log.d(`地图标记已加：${p.company}`);
      }).catch((e: Error): void => {
        Log.w(`地图标记失败 ${p.company}：${e.message}`);
      });
    }
    Log.i(`地图标记已下发（共 ${this.points.length} 个）`);
  }

  // ───────────────────────────────────────────── 界面

  @Builder
  cityChip(c: string) {
    Text(c)
      .fontSize(11.5)
      .fontColor(this.city === c ? Palette.BG : Palette.TX_2)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .backgroundColor(this.city === c ? Palette.ACCENT : Palette.PANEL_2)
      .borderRadius(Metrics.CHIP_RADIUS)
      .maxLines(1)
      .onClick(() => {
        this.focus(c);
      })
  }

  @Builder
  fallbackBody() {
    Column({ space: 8 }) {
      Text('地图没能加载出来')
        .fontSize(13.5)
        .fontColor(Palette.TX_2)
      Text(this.deadMsg.length > 0 ? this.deadMsg : '通常是签名里没有地图权益')
        .fontSize(11.5)
        .fontColor(Palette.TX_3)
      // 降级成清单 —— 地点信息本身还在，只是不画在地图上
      ForEach(this.points, (p: JobPoint) => {
        Row({ space: 8 }) {
          Text(p.company).fontSize(12.5).fontColor(Palette.TX)
          Blank()
          Text(p.place.name).fontSize(11).fontColor(Palette.TX_3)
        }
        .width('100%')
      }, (p: JobPoint) => `fb-${p.company}`)
    }
    .width('100%')
    .padding(14)
    .height(180)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text('求职地图')
          .fontSize(13)
          .fontColor(Palette.TX_3)
        Blank()
        Text(this.summary)
          .fontSize(11.5)
          .fontColor(Palette.TX_3)
      }
      .width('100%')

      Stack({ alignContent: Alignment.Center }) {
        if (this.mapDead) {
          this.fallbackBody()
        } else {
          MapComponent({ mapOptions: this.mapOptions, mapCallback: this.mapCallback })
            .width('100%')
            .height(200)
            .borderRadius(10)
        }
      }
      .width('100%')
      .height(this.mapDead ? 180 : 200)
      .backgroundColor(Palette.PANEL)
      .borderRadius(Metrics.CARD_RADIUS)
      .clip(true)

      // 城市筛选。横向可滚 —— 用户投的城市多了不该把卡片撑爆
      if (this.cities.length > 1) {
        Scroll() {
          Row({ space: 6 }) {
            this.cityChip(ALL_CITIES)
            ForEach(this.cities, (c: string) => {
              this.cityChip(c)
            }, (c: string) => `city-${c}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Palette.PANEL)
    .borderRadius(Metrics.CARD_RADIUS)
  }
}
