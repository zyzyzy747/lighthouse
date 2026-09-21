/**
 * 无副作用的小工具。全部纯函数，便于单测。
 */

const ONE_DAY: number = 24 * 60 * 60 * 1000;

export function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/**
 * 09-18；跨年时补上年份 → 2025-12-30
 *
 * 秋招横跨 9 月到次年 1 月。只给「月-日」的话，1 月回头看一条「09-18」
 * 根本分不清是去年还是今年的 —— 所以跨年才补年份，同年保持简洁。
 */
export function fmtDate(ts: number): string {
  if (ts <= 0) {
    return '--';
  }
  const d: Date = new Date(ts);
  const md: string = `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  return d.getFullYear() === new Date().getFullYear() ? md : `${d.getFullYear()}-${md}`;
}

/** 09-18 14:30；跨年时补上年份，理由同 fmtDate */
export function fmtDateTime(ts: number): string {
  if (ts <= 0) {
    return '未设置';
  }
  const d: Date = new Date(ts);
  const md: string = `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  const hm: string = `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  return d.getFullYear() === new Date().getFullYear() ? `${md} ${hm}` : `${d.getFullYear()}-${md} ${hm}`;
}

/** HH:mm */
export function fmtTime(ts: number): string {
  const d: Date = new Date(ts);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** 把时间戳归零到当天 00:00，用于「差几天」比较 */
export function startOfDay(ts: number): number {
  const d: Date = new Date(ts);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** 自然日差：正数=还有几天，0=今天，负数=已过几天 */
export function dayDiff(target: number, now: number = Date.now()): number {
  return Math.round((startOfDay(target) - startOfDay(now)) / ONE_DAY);
}

/** 「今天 14:30」「明天」「3 天后」「已过 2 天」 */
export function humanDeadline(ts: number): string {
  if (ts <= 0) {
    return '未设置';
  }
  const diff: number = dayDiff(ts);
  if (diff === 0) {
    return `今天 ${fmtTime(ts)}`;
  }
  if (diff === 1) {
    return `明天 ${fmtTime(ts)}`;
  }
  if (diff === -1) {
    return '昨天';
  }
  if (diff > 1) {
    return `${diff} 天后 · ${fmtDate(ts)}`;
  }
  return `已过 ${-diff} 天 · ${fmtDate(ts)}`;
}

/** 距今小时数，卡片倒计时用 */
export function hoursUntil(ts: number, now: number = Date.now()): number {
  return Math.floor((ts - now) / (60 * 60 * 1000));
}

/**
 * 倒计时文案：「3 小时 12 分」/「1 天 4 小时」/「已开始」
 * 桌面卡片与实况降级通知共用同一套文案，避免两处数字对不上。
 */
export function countdownText(ts: number, now: number = Date.now()): string {
  const ms: number = ts - now;
  if (ms <= 0) {
    return '已开始';
  }
  const days: number = Math.floor(ms / ONE_DAY);
  const hours: number = Math.floor((ms % ONE_DAY) / (60 * 60 * 1000));
  const mins: number = Math.floor((ms % (60 * 60 * 1000)) / (60 * 1000));
  if (days > 0) {
    return `${days} 天 ${hours} 小时`;
  }
  if (hours > 0) {
    return `${hours} 小时 ${mins} 分`;
  }
  return `${mins} 分`;
}

/** 薪资区间文案：15-25K / 15K / 面议 */
export function fmtSalary(min: number, max: number): string {
  if (min <= 0 && max <= 0) {
    return '面议';
  }
  if (min > 0 && max > 0) {
    return `${min}-${max}K`;
  }
  return `${min > 0 ? min : max}K`;
}

/** 安全取字符串，防空指针 */
export function safeStr(s: string | undefined | null): string {
  return s === undefined || s === null ? '' : s;
}

/** 生成 id 用的时间戳（毫秒）+ 随机尾数，避免同毫秒冲突 */
export function uid(): number {
  return Date.now() * 100 + Math.floor(Math.random() * 100);
}

/** 空集合判断，代替 ArkTS 里不推荐的隐式转换 */
export function isEmpty(s: string): boolean {
  return s === undefined || s === null || s.trim().length === 0;
}
