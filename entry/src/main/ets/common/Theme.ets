/**
 * 灯塔 · 视觉规范
 * 深海暗色底 + 灯塔暖光。所有颜色只从这里取，禁止页面里硬编码色值。
 */

export class Palette {
  /** 页面底色：深夜海面 */
  static readonly BG: string = '#0A1120';
  /** 卡片/面板 */
  static readonly PANEL: string = '#131E33';
  /** 次级面板（输入框、列表自定义底） */
  static readonly PANEL_2: string = '#1B2942';
  /** 分隔线 */
  static readonly LINE: string = '#243553';

  /** 主色：海面反光蓝 */
  static readonly PRIMARY: string = '#4A9EFF';
  /** 强调色：灯塔光 */
  static readonly ACCENT: string = '#FFB020';
  /** 成功 */
  static readonly OK: string = '#3DD68C';
  /** 危险 */
  static readonly DANGER: string = '#FF5C5C';
  /** 辅助紫 */
  static readonly PURPLE: string = '#A78BFA';

  /** 文字 */
  static readonly TX: string = '#E8EEF9';
  static readonly TX_2: string = '#93A7C6';
  static readonly TX_3: string = '#5B6E8C';
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
