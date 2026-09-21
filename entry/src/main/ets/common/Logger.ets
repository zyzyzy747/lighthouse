import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x1001;
const TAG: string = 'Lighthouse';

/** 统一日志出口，方便上线前一次性关掉 */
export class Log {
  static d(msg: string): void {
    hilog.debug(DOMAIN, TAG, '%{public}s', msg);
  }

  static i(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
  }

  static w(msg: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', msg);
  }

  static e(msg: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
  }
}
