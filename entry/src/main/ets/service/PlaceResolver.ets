import { site, mapCommon } from '@kit.MapKit';
import { common } from '@kit.AbilityKit';
import { Log } from '../common/Logger';

/**
 * 一个「求职地点」：公司名 + 真实经纬度 + 来源。
 *
 * 为什么要记 source：地图上同一个点，可能是华为地点搜索查出来的真 POI，
 * 也可能是断网时退回的园区级近似坐标。**答辩被人问「这坐标准不准」时必须能
 * 一句话答上来**，所以来源要跟着数据走，UI 上也要区分显示（见 JobMapCard）。
 */
export class Place {
  name: string = '';
  address: string = '';
  lat: number = 0;
  lng: number = 0;
  /** 'search' = 华为地点搜索返回的真 POI；'seed' = 内置园区级近似；'city' = 只落到城市中心 */
  source: string = '';

  constructor(name: string, address: string, lat: number, lng: number, source: string) {
    this.name = name;
    this.address = address;
    this.lat = lat;
    this.lng = lng;
    this.source = source;
  }
}

/** 城市中心（搜索没结果时的最后兜底，保证地图永远有东西可画） */
class CityCenter {
  name: string;
  lat: number;
  lng: number;

  constructor(name: string, lat: number, lng: number) {
    this.name = name;
    this.lat = lat;
    this.lng = lng;
  }
}

const CITY_CENTERS: CityCenter[] = [
  new CityCenter('武汉', 30.5928, 114.3055),
  new CityCenter('北京', 39.9042, 116.4074),
  new CityCenter('上海', 31.2304, 121.4737),
  new CityCenter('广州', 23.1291, 113.2644),
  new CityCenter('深圳', 22.5431, 114.0579),
  new CityCenter('杭州', 30.2741, 120.1551),
  new CityCenter('成都', 30.5728, 104.0668),
  new CityCenter('南京', 32.0603, 118.7969),
  new CityCenter('西安', 34.3416, 108.9398),
  new CityCenter('长沙', 28.2282, 112.9388),
  new CityCenter('郑州', 34.7466, 113.6254),
  new CityCenter('合肥', 31.8206, 117.2272)
];

/**
 * 离线种子库（园区 / 地标级）。
 *
 * ⚠ 这里存的是**园区级近似坐标，不是门牌级**。前提是「演示现场可能没网」——
 *   没有它，一断网地图就是空的，整个功能当场失效。有了它，至少点还在武汉该在的地方。
 * ⚠ 联网时**不会**用它：PlaceResolver 先查华为地点搜索，拿不到才回头找种子。
 *
 * key 是关键词，公司名里包含即命中（所以写「精测」而不是「精测电子股份有限公司」）。
 */
class SeedPlace {
  key: string;
  name: string;
  address: string;
  lat: number;
  lng: number;

  constructor(key: string, name: string, address: string, lat: number, lng: number) {
    this.key = key;
    this.name = name;
    this.address = address;
    this.lat = lat;
    this.lng = lng;
  }
}

const SEED_PLACES: SeedPlace[] = [
  // ── 演示数据里那几家武汉公司（园区级，联网时会被真 POI 覆盖）
  new SeedPlace('精测电子', '光谷 · 东湖高新区', '武汉市东湖新技术开发区', 30.5056, 114.4300),
  new SeedPlace('光庭信息', '光谷软件园', '武汉市东湖新技术开发区软件园路', 30.4803, 114.4186),
  new SeedPlace('金山办公', '光谷金融港', '武汉市东湖新技术开发区金融港', 30.4905, 114.4348),
  new SeedPlace('达梦数据库', '光谷中心城', '武汉市东湖新技术开发区光谷中心城', 30.5056, 114.5042),
  // ── 武汉主要 IT 聚集区 / 高校（用户自己填公司名时也能沾上）
  new SeedPlace('光谷软件园', '光谷软件园', '武汉市东湖新技术开发区软件园路', 30.4803, 114.4186),
  new SeedPlace('光谷金融港', '光谷金融港', '武汉市东湖新技术开发区金融港', 30.4905, 114.4348),
  new SeedPlace('光谷生物城', '光谷生物城', '武汉市东湖新技术开发区高新大道', 30.4728, 114.4712),
  new SeedPlace('未来科技城', '未来科技城', '武汉市东湖新技术开发区未来三路', 30.5083, 114.6012),
  new SeedPlace('武汉大学', '武汉大学', '武汉市武昌区八一路', 30.5375, 114.3650),
  new SeedPlace('华中科技大学', '华中科技大学', '武汉市洪山区珞喻路', 30.5120, 114.4120),
  new SeedPlace('武汉理工大学', '武汉理工大学', '武汉市洪山区珞狮路', 30.5200, 114.3400)
];

/**
 * 把「公司名」变成「地图上的一个点」。
 *
 * 三级降级，从准到糙：
 *   ① 华为地点搜索（site.searchByText）—— 真 POI，最准，但要网
 *   ② 内置种子库 —— 园区级近似，断网也能用
 *   ③ 城市中心 —— 至少点落在对的城市，不会画到海里
 *
 * ⚠ 三级都要有，缺任何一级演示都会出事：
 *   只有 ① → 断网就空白；只有 ② → 用户填个种子库没有的公司就查不到；
 *   没有 ③ → 解析失败时不知道画哪，整块地图得藏起来。
 */
export class PlaceResolver {
  /**
   * 结果缓存。
   * ⚠ 必须是**进程内静态**而不是每次 new：一个 8 家公司的列表会在 reload 时
   *   被解析好几遍（进页面一次、tick 一次、切 tab 回来一次），
   *   不缓存就是几十次重复网络请求，模拟器上能明显感觉到卡。
   * ⚠ 同时缓存**失败**（存 undefined 的占位见下），否则查不到公司会每次都重试。
   */
  private static cache: Map<string, Place> = new Map<string, Place>();

  /** 城市中心表查不到时的默认值（武汉 —— 本项目默认城市） */
  private static fallbackCity(): CityCenter {
    return CITY_CENTERS[0];
  }

  static cityCenter(city: string): Place {
    for (let i: number = 0; i < CITY_CENTERS.length; i++) {
      if (CITY_CENTERS[i].name === city) {
        return new Place(city, `${city}市中心`, CITY_CENTERS[i].lat, CITY_CENTERS[i].lng, 'city');
      }
    }
    const f: CityCenter = PlaceResolver.fallbackCity();
    return new Place(city, `${f.name}市中心`, f.lat, f.lng, 'city');
  }

  /** 种子库命中（公司名包含关键词即中） */
  private static seedOf(company: string): Place | undefined {
    for (let i: number = 0; i < SEED_PLACES.length; i++) {
      const s: SeedPlace = SEED_PLACES[i];
      if (company.indexOf(s.key) >= 0) {
        return new Place(s.name, s.address, s.lat, s.lng, 'seed');
      }
    }
    return undefined;
  }

  /**
   * 解析一家公司。永远不会抛异常，最差返回城市中心。
   *
   * @param ctx 需要 AbilityContext —— site 的重载里带 context 的那个才稳，
   *            不带 context 的版本依赖全局上下文，在某些时机下拿不到。
   */
  static async resolve(ctx: common.Context, company: string, city: string): Promise<Place> {
    const key: string = `${city}#${company}`;

    // ① 缓存
    const hit: Place | undefined = PlaceResolver.cache.get(key);
    if (hit !== undefined) {
      return hit;
    }

    const center: Place = PlaceResolver.cityCenter(city);

    // ② 联网查真 POI
    try {
      const params: site.SearchByTextParams = {
        query: company,
        location: { latitude: center.lat, longitude: center.lng },
        radius: 50000,
        language: 'zh',
        isCityLimit: true,
        pageIndex: 1,
        pageSize: 5
      };
      const res: site.SearchByTextResult = await site.searchByText(ctx, params);
      if (res.sites !== undefined && res.sites.length > 0) {
        const s: site.Site = res.sites[0];
        if (s.location !== undefined) {
          const p: Place = new Place(
            s.name !== undefined ? s.name : company,
            s.formatAddress !== undefined ? s.formatAddress : city,
            s.location.latitude,
            s.location.longitude,
            'search'
          );
          Log.i(`地点解析 search「${company}」→ ${p.name} (${p.lat.toFixed(4)}, ${p.lng.toFixed(4)})`);
          PlaceResolver.cache.set(key, p);
          return p;
        }
      }
      Log.w(`地点解析：「${company}」搜索无结果，退回种子库`);
    } catch (e) {
      const err: Error = e as Error;
      // 断网 / 服务不可用都会走到这里 —— 这正是种子库存在的意义
      Log.w(`地点解析：「${company}」搜索失败(${err.message})，退回种子库`);
    }

    // ③ 种子库
    const seed: Place | undefined = PlaceResolver.seedOf(company);
    if (seed !== undefined) {
      Log.i(`地点解析 seed「${company}」→ ${seed.name}`);
      PlaceResolver.cache.set(key, seed);
      return seed;
    }

    // ④ 城市中心
    Log.i(`地点解析 city「${company}」→ ${center.name}`);
    PlaceResolver.cache.set(key, center);
    return center;
  }

  /** 自检 / 换账号时清缓存 */
  static clearCache(): void {
    PlaceResolver.cache.clear();
  }
}
