/**
 * 灯塔 · 视觉规范
 * 深海暗色底 + 灯塔暖光。所有颜色只从这里取，禁止页面里硬编码色值。
 *
 * ⚠ 色值**不在代码里**，全部走资源限定词：
 *   `resources/base/element/color.json`   浅色（日间）
 *   `resources/dark/element/color.json`   深色（夜间，"深海"原色）
 *
 * 为什么不让 Palette 自己存两套 string 再按开关取：
 *   那样每次切换都得靠 @State 手动重建整棵树，任何一处漏订阅就出现"一半深一半浅"。
 *   走资源后由**系统**在深浅色变化时重新解析 `$r()` 并重建，卡片进程也自动跟随
 *   （桌面卡片本来就是独立进程，靠 AppStorage 传不过去）。
 *   代价只是类型从 `string` 变 `Resource` —— 页面里的 `Palette.XX` 一个字都不用改。
 *
 * 切换深浅走 `Appearance.set()`（内部 `ApplicationContext.setColorMode`），
 * 不要试图在这里自己判模式。
 */

export class Palette {
  /** 页面底色：深夜海面 */
  static readonly BG: Resource = $r('app.color.lh_bg');
  /** 卡片/面板 */
  static readonly PANEL: Resource = $r('app.color.lh_panel');
  /** 次级面板（输入框、列表自定义底） */
  static readonly PANEL_2: Resource = $r('app.color.lh_panel_2');
  /** 分隔线 */
  static readonly LINE: Resource = $r('app.color.lh_line');

  /** 主色：海面反光蓝 */
  static readonly PRIMARY: Resource = $r('app.color.lh_primary');
  /** 强调色：灯塔光 */
  static readonly ACCENT: Resource = $r('app.color.lh_accent');
  /** 成功 */
  static readonly OK: Resource = $r('app.color.lh_ok');
  /** 危险 */
  static readonly DANGER: Resource = $r('app.color.lh_danger');
  /** 辅助紫 */
  static readonly PURPLE: Resource = $r('app.color.lh_purple');

  /** 文字 */
  static readonly TX: Resource = $r('app.color.lh_tx');
  static readonly TX_2: Resource = $r('app.color.lh_tx_2');
  static readonly TX_3: Resource = $r('app.color.lh_tx_3');
}

/**
 * 半透明"文字底衬"色：红字配淡红底那种。
 *
 * ⚠ 为什么不能像以前那样 `#${alpha}${色值.substring(1)}` 拼出来：
 *   拼字符串要求色值是 `string`，而走资源后拿到的是 `Resource`，没法截前缀。
 *   所以每种色调各自准备一份已带透明度的资源 —— 多写 6 行 json，换来的仍是
 *   "深浅色各自正确"（浅色底上的淡红和深色底上的淡红本来就该是两个 alpha）。
 *
 * 深色下 alpha 取 0x22（约 13%），浅色下取 0x1A（约 10%）：
 * 白底吸光少，同样的 alpha 会比深色底看着更重，所以浅色要再淡一点。
 */
export class Tint {
  static readonly PRIMARY: Resource = $r('app.color.lh_tint_primary');
  static readonly ACCENT: Resource = $r('app.color.lh_tint_accent');
  static readonly OK: Resource = $r('app.color.lh_tint_ok');
  static readonly DANGER: Resource = $r('app.color.lh_tint_danger');
  static readonly PURPLE: Resource = $r('app.color.lh_tint_purple');
  /** 灰色调（无节点 / 中性文字的底衬） */
  static readonly NEUTRAL: Resource = $r('app.color.lh_tint_neutral');
}

export class Metrics {
  static readonly PAGE_PAD: number = 16;
  static readonly CARD_RADIUS: number = 14;
  static readonly CHIP_RADIUS: number = 8;
  static readonly GAP: number = 12;
  static readonly GAP_S: number = 8;
  static readonly TAB_H: number = 58;
  /** 平板断点：宽度 ≥ 此值时启用侧栏布局 */
  static readonly BREAKPOINT_TABLET: number = 840;
}

/** 渠道候选，快记页的快捷选择 */
export const CHANNEL_OPTIONS: string[] = ['官网', 'BOSS', '牛客', '内推', '实习僧', '宣讲会', '其他'];

/**
 * 城市候选。
 *
 * 排序 = 求职实际热度：武汉（主场）→ 一线 → 新一线/热门二线 → 远程。
 * ⚠ 别只留几个：选项里没有的城市，用户只能挑个最近的凑数，
 *   之后按城市看分布时整列数据就都是错的 —— 这比"多几行选项"贵得多。
 */
export const CITY_OPTIONS: string[] = [
  '武汉', '北京', '上海', '深圳', '广州',
  '杭州', '南京', '成都', '西安', '苏州',
  '长沙', '重庆', '天津', '合肥', '郑州',
  '青岛', '厦门', '济南', '宁波', '无锡',
  '福州', '远程'
];
