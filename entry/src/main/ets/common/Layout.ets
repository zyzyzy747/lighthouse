/**
 * 灯塔 · 多端适配（一次开发，多端部署）
 *
 * ── 断点怎么定的 ────────────────────────────────────────────────
 * 参考华为一多的 sm / md / lg 规范并结合本作品实际会跑的设备：
 *
 *   宽度            档位   导航形态      内容形态
 *   ────────────────────────────────────────────────────────
 *   < 600vp         sm    底部 Tab      单列
 *   [600, 840)      md    左侧栏         单列（限宽居中）
 *   ≥ 840vp         lg    左侧栏         左右双栏
 *
 * ⚠ **侧栏阈值压到 600 是刻意的。** 折叠屏 Mate X7 展开后是 2210px / (500dpi/160) ≈ 707vp，
 *   如果沿用很多模板里那个 840 的阈值，折叠屏展开会被判成"手机"，横向空间白白浪费 ——
 *   而折叠屏展开恰恰是最该展示"多端适配"的场景之一。
 *   600vp 也是华为「分栏导航」的推荐起点，两边正好对齐。
 *
 * ── 为什么状态放 AppStorage 而不是层层传参 ─────────────────────────
 *   四个页面 + 卡片视图都可能要按宽度改布局，从 Index 一层层往下传 props 会污染
 *   每个组件的入参签名。放 AppStorage 里各页面用 @StorageProp 自己订阅即可。
 *
 * ⚠ 坑：@StorageProp / @Watch 这类**装饰器参数在编译期求值**，所以页面里订阅时
 *   必须写字符串字面量（`@StorageProp('lhTwoPane')`），传本文件导出的常量不会被识别。
 *   下面这些常量只用于运行时的 AppStorage.setOrCreate。
 */

import { display } from '@kit.ArkUI';
import { Log } from './Logger';

/** 宽度档位 */
export enum WinSize {
  SM = 0,
  MD = 1,
  LG = 2
}

// ---------------------------------------------------------------- AppStorage 键
/** 当前窗口宽度（vp） */
export const LK_WIDTH: string = 'lhWinWidth';
/** 当前窗口高度（vp） */
export const LK_HEIGHT: string = 'lhWinHeight';
/** 是否用左侧栏导航（宽 ≥ 600vp） */
export const LK_SIDE: string = 'lhSideNav';
/** 内容是否左右双栏（宽 ≥ 840vp） */
export const LK_TWO: string = 'lhTwoPane';
/** 是否处于折叠屏半折叠（悬停）状态 */
export const LK_HOVER: string = 'lhHover';
/** 可用高度偏矮，页面内部要收紧留白 */
export const LK_COMPACT: string = 'lhCompact';
/** 本机是否折叠屏 */
export const LK_FOLDABLE: string = 'lhFoldable';
/** 侧栏宽度（vp），随档位变化 */
export const LK_SIDE_W: string = 'lhSideW';
/**
 * 演示 / 自检开关：强制当作"悬停中"。
 * 只由 EntryAbility 从 want 参数写入（`aa start ... --ps lh_hover_preview true`），
 * 正常启动永远不会有这个参数。用途见 FoldWatcher.start()。
 */
export const LK_FORCE_HOVER: string = 'lhHoverForced';
/**
 * 演示 / 自检开关：临时覆盖「内容双栏」的宽度阈值（vp）。
 * 只在带参拉起时生效，进程重启即恢复默认，不污染正常形态。
 */
export const LK_BP_TWO: string = 'lhBpTwo';


export class Layout {
  /** ≥600vp：左侧栏导航 */
  static readonly BP_SIDE: number = 600;
  /** ≥840vp：内容左右双栏 */
  static readonly BP_TWO: number = 840;
  /** ≥1200vp：超宽，双栏可以更宽松（平板 / 2in1） */
  static readonly BP_LG: number = 1200;
  /** 可用高度低于此值认为"矮屏"，页面收紧留白（横屏手机、悬停后的上半屏） */
  static readonly COMPACT_H: number = 640;
  /** 悬停分栏时上半区占比 */
  static readonly HOVER_TOP_RATIO: number = 0.46;
  /** 折痕两侧额外留的空白，内容不贴着折痕放 */
  static readonly CREASE_GAP: number = 14;

  static sizeOf(w: number): WinSize {
    if (w >= Layout.BP_TWO) {
      return WinSize.LG;
    }
    if (w >= Layout.BP_SIDE) {
      return WinSize.MD;
    }
    return WinSize.SM;
  }

  /**
   * 双栏断点。默认 BP_TWO；自检时可由 want 参数临时调小。
   * 为什么允许覆盖：手上只有手机模拟器时，横屏（≈789vp）也到不了 840vp，
   * 双栏那段布局就成了「写完没法看」的死角。
   */
  static twoBreakpoint(): number {
    const v: number | undefined = AppStorage.get<number>(LK_BP_TWO);
    if (v !== undefined && v > 0) {
      return v;
    }
    return Layout.BP_TWO;
  }

  static labelOf(w: number): string {
    const s: WinSize = Layout.sizeOf(w);
    if (s === WinSize.LG) {
      return 'lg';
    }
    if (s === WinSize.MD) {
      return 'md';
    }
    return 'sm';
  }

  /** 侧栏宽度：宽屏给宽一点，能放下四个字的中文标签 */
  static sideWidth(w: number): number {
    return w >= Layout.BP_LG ? 132 : 104;
  }

  /**
   * 把当前窗口尺寸折算成各项布局开关写进 AppStorage。
   *
   * 各维度是**相互独立**的，别把它们耦合起来：
   *   - 侧栏只看宽度（侧栏是竖排的，矮屏也放得下四个 tab）
   *   - 双栏看宽度（左右分栏在矮屏上依然成立，横屏手机就是典型场景）
   *   - compact 只看高度（只影响页面内部的留白与卡片密度）
   * 早期版本把"矮屏"直接当成"不启用侧栏"，结果手机横屏（920×419）会被判回手机布局，
   * 横向空间全废 —— 这是把两个正交的维度绑在一起造成的。
   */
  static publish(w: number, h: number): void {
    const compact: boolean = h > 0 && h < Layout.COMPACT_H;
    const side: boolean = w >= Layout.BP_SIDE;
    // ⚠ 双栏**只**看宽度，不要加高度条件。
    //   这里曾经写成 `w >= twoBreakpoint() && h >= COMPACT_H`，结果手机横屏（788×359vp）
    //   被高度一票否决，横向多出来的 400 多 vp 白白空着 —— 而"横屏手机摆两栏"
    //   恰恰是普通用户不买平板也能看到的多端形态。矮屏只会让每栏少显示几行，
    //   两栏各自滚动本来就是为这件事准备的，不需要禁用它。
    const bp: number = Layout.twoBreakpoint();
    const two: boolean = w >= bp;

    // 只在结果变化时打一行。一多最难查的就是"看着没生效"：
    // 没有这行日志，「没跑到 publish」和「算出来就是 false」在 hilog 里长得一模一样。
    const pw: number | undefined = AppStorage.get<number>(LK_WIDTH);
    const ph: number | undefined = AppStorage.get<number>(LK_HEIGHT);
    const ps: boolean | undefined = AppStorage.get<boolean>(LK_SIDE);
    const pt: boolean | undefined = AppStorage.get<boolean>(LK_TWO);
    if (pw !== w || ph !== h || ps !== side || pt !== two) {
      Log.i(`多端：窗口 ${w.toFixed(0)}×${h.toFixed(0)}vp → 侧栏=${side} 双栏=${two}`
        + `（双栏断点 ${bp}vp） 紧凑=${compact}`);
    }

    AppStorage.setOrCreate(LK_WIDTH, w);
    AppStorage.setOrCreate(LK_HEIGHT, h);
    AppStorage.setOrCreate(LK_COMPACT, compact);
    AppStorage.setOrCreate(LK_SIDE, side);
    AppStorage.setOrCreate(LK_SIDE_W, Layout.sideWidth(w));
    AppStorage.setOrCreate(LK_TWO, two);
  }

  /**
   * 悬停分栏是否可用：处在半折叠状态，且系统把整屏给了应用
   * （如果系统只给了上半屏，可用高度会明显变小，这时上下再分栏就是两条都挤，不如不做）。
   */
  static hoverSplitOn(h: number): boolean {
    const hv: boolean | undefined = AppStorage.get<boolean>(LK_HOVER);
    return (hv !== undefined && hv) && h >= Layout.COMPACT_H;
  }
}


/**
 * 折叠屏监听。
 *
 * 为什么值得单独做：
 *   折叠屏悬停（半折叠）是鸿蒙一多里最能体现"为折叠形态做过设计"的场景，
 *   也是评委一眼能看出来的差异点。悬停时手机能自己立住，用户不拿手，
 *   所以此时**最该放大的是"下一件事还有多久"**，而不是等比例地拉大整个页面。
 *
 * ⚠ 非折叠设备上 display.isFoldable() 为 false，整个模块静默不启用。
 *   这里必须留一条日志说明"为什么没走悬停分支" —— 否则在手机上调试时，
 *   "悬停布局没生效"会被误判成代码没跑到（这类静默分支最容易浪费排查时间）。
 */
export class FoldWatcher {
  private static watching: boolean = false;

  static start(): void {
    if (FoldWatcher.watching) {
      return;
    }
    FoldWatcher.watching = true;

    // 自检开关优先于设备判定：手机模拟器上也要能看到悬停分栏长什么样。
    // ⚠ 这段必须在 isFoldable() 之前 —— 否则非折叠机会直接 return，开关形同虚设。
    if (FoldWatcher.applyForced()) {
      return;
    }

    try {
      const foldable: boolean = display.isFoldable();
      AppStorage.setOrCreate(LK_FOLDABLE, foldable);
      if (!foldable) {
        AppStorage.setOrCreate(LK_HOVER, false);
        Log.i('多端：非折叠设备，悬停布局不启用');
        return;
      }
      display.on('foldStatusChange', onFoldStatusChange);
      FoldWatcher.applyStatus(display.getFoldStatus());
      Log.i('多端：折叠屏状态监听已注册');
    } catch (e) {
      const err: Error = e as Error;
      // 注册失败绝不能让应用起不来：悬停只是增强，不是必需品
      Log.e(`多端：折叠状态监听注册失败（不影响其它布局）：${err.message}`);
    }
  }

  static applyStatus(status: display.FoldStatus): void {
    const hover: boolean = status === display.FoldStatus.FOLD_STATUS_HALF_FOLDED;
    AppStorage.setOrCreate(LK_HOVER, hover);
    Log.i(`多端：折叠状态=${status}，悬停分栏=${hover}`);
  }

  /**
   * 预览开关是否把悬停强行打开了。
   *
   * start()（冷启动）和 applyLayoutPreview()（热启动重新带参拉起）共用同一段判断 ——
   * 冷启动时 onCreate 先写开关、aboutToAppear 里的 start() 才读得到；
   * 而热启动时 start() 因为 watching 标志早退，必须由 applyLayoutPreview 再调一次。
   */
  static applyForced(): boolean {
    const forced: boolean | undefined = AppStorage.get<boolean>(LK_FORCE_HOVER);
    if (forced !== undefined && forced) {
      AppStorage.setOrCreate(LK_FOLDABLE, false);
      AppStorage.setOrCreate(LK_HOVER, true);
      Log.i('多端：悬停由预览开关强制开启（跳过折叠设备判定）');
      return true;
    }
    return false;
  }
}

function onFoldStatusChange(status: display.FoldStatus): void {
  FoldWatcher.applyStatus(status);
}

/**
 * 从 want 参数里读「悬停预览」开关并强制开启悬停布局。
 *
 * 为什么需要它：悬停分栏只在折叠屏半折叠时才会出现，而开发机上通常只有手机模拟器，
 * 于是这段布局**写完就没法验证**——"没生效"和"根本没跑到"在日志上看起来一样。
 * 有了这个开关，就能用一条命令行把那段 UI 真的渲染出来截图检查。
 *
 * ⚠ 只有 `aa start ... --ps lh_hover_preview true` 这种带参拉起才会命中，
 *   用户从桌面正常点图标进来永远不会有这个参数，不影响真实形态。
 */
export function applyLayoutPreview(params: Record<string, Object> | undefined): void {
  if (params === undefined) {
    return;
  }

  let touched: boolean = false;

  const hover: Object | undefined = params['lh_hover_preview'];
  if (hover !== undefined && hover !== null && `${hover}` === 'true') {
    AppStorage.setOrCreate(LK_FORCE_HOVER, true);
    Log.i('多端：收到悬停预览开关，强制启用悬停分栏');
    touched = true;
  }

  // 临时调小双栏断点，把双栏布局渲染出来检查（没有大屏设备时的自检手段）
  const bp: Object | undefined = params['lh_bp_two'];
  if (bp !== undefined && bp !== null) {
    const n: number = Number.parseInt(`${bp}`, 10);
    if (!Number.isNaN(n) && n > 0) {
      AppStorage.setOrCreate(LK_BP_TWO, n);
      Log.i(`多端：双栏断点本次临时改为 ${n}vp（自检用）`);
      touched = true;
    }
  }

  if (!touched) {
    return;
  }

  // ⚠ 这一段是"热启动带参"能不能生效的关键。
  //   应用已经活着时再 `aa start --ps ...` 走的是 onNewWant：aboutToAppear 不再执行、
  //   onAreaChange 也不会因为参数变化而触发，光把开关写进 AppStorage 没有任何人读它。
  //   必须在这里手动把开关重新折算一次。
  FoldWatcher.applyForced();

  const w: number | undefined = AppStorage.get<number>(LK_WIDTH);
  const h: number | undefined = AppStorage.get<number>(LK_HEIGHT);
  if (w !== undefined && h !== undefined && w > 0 && h > 0) {
    Layout.publish(w, h);
    Log.i(`多端：按新开关重算布局（${w.toFixed(0)}×${h.toFixed(0)}vp）`);
  }
}
