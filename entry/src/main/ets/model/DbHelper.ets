import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Log } from '../common/Logger';

/**
 * 表结构 DDL。
 * ⚠ 改这里的任何一列，必须同时：① 升 DB_VERSION ② 在 DbHelper.migrate 里写对应 ALTER。
 */
export const DB_NAME: string = 'lighthouse.db';
/**
 * ⚠ v2：加 app_kv —— 哨兵配置与去重记录要从 Preferences 挪进库，因为卡片进程也要读它。
 * ⚠ v3：加 account —— 本地档案（用户名 + 盐 + 派生密钥）。
 */
export const DB_VERSION: number = 3;

export const T_APP: string = 'application';
export const T_EVENT: string = 'event_node';
export const T_REVIEW: string = 'review';
/**
 * 键值表。
 *
 * 为什么哨兵配置不放 Preferences 而放这里：**卡片进程也要读它**。
 * 卡片跑在独立的 FormExtension 进程里，而 Preferences 在 ArkData 里是
 * 「按进程持有缓存」的，应用进程改了设置，卡片进程不一定看得到；
 * 两个进程各写一份还会互相覆盖。RDB 是同一个文件 + WAL，天然跨进程一致 ——
 * 卡片本来就在读这个库，把配置放进来是顺路的事。
 */
export const T_KV: string = 'app_kv';

/**
 * 本地档案表。
 *
 * 为什么值得单独一张表（而不是塞进 app_kv）：
 *   ① 它是有结构的行数据（用户名 / 盐 / 派生密钥 / 迭代轮数），不是配置项；
 *   ② **密码永远不落明文**，落的是 PBKDF2 派生密钥 + 每账户独立的随机盐。
 *      将来要换算法或提轮数时，`rounds` 一列能让旧记录继续可校验（见 Auth.login），
 *      不会把老用户锁在门外。
 *
 * ⚠ 这张表**不参与 DbHelper.wipe()**：wipe 是"清业务数据"的调试口，
 *   把档案一起清掉的话，每清一次数据都要重建账号，验收脚本没法用。
 *   （要连档案一起重置走 Auth.resetAll —— 那里是刻意两者都清的。）
 */
export const T_ACCOUNT: string = 'account';

/**
 * 会话解锁标记（app_kv 的键）。
 *
 * 为什么放在这里而不是 service/Auth：
 *   **卡片进程要读它**（未解锁 → 卡片脱敏）。而卡片只需要一个字符串常量，
 *   没必要为了它把整个 CryptoArchitectureKit 拖进卡片进程的依赖图。
 */
export const K_UNLOCKED: string = 'auth_unlocked';
/** 当前档案的称呼。卡片脱敏后仍需要它来回答"这是谁的卡片"。 */
export const K_USER: string = 'auth_user';

export const DDL_CREATE: string[] = [
  `CREATE TABLE IF NOT EXISTS ${T_APP} (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    company TEXT NOT NULL DEFAULT '',
    position TEXT NOT NULL DEFAULT '',
    city TEXT NOT NULL DEFAULT '',
    channel TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'applied',
    salary_min INTEGER NOT NULL DEFAULT 0,
    salary_max INTEGER NOT NULL DEFAULT 0,
    jd_text TEXT NOT NULL DEFAULT '',
    applied_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    note TEXT NOT NULL DEFAULT ''
  )`,
  `CREATE TABLE IF NOT EXISTS ${T_EVENT} (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id INTEGER NOT NULL DEFAULT 0,
    type TEXT NOT NULL DEFAULT 'other',
    title TEXT NOT NULL DEFAULT '',
    happen_at INTEGER NOT NULL DEFAULT 0,
    done INTEGER NOT NULL DEFAULT 0,
    note TEXT NOT NULL DEFAULT ''
  )`,
  `CREATE TABLE IF NOT EXISTS ${T_REVIEW} (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id INTEGER NOT NULL DEFAULT 0,
    round TEXT NOT NULL DEFAULT 'other',
    interviewer TEXT NOT NULL DEFAULT '',
    narration TEXT NOT NULL DEFAULT '',
    radar_json TEXT NOT NULL DEFAULT '',
    score_avg INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT 0
  )`,
  `CREATE TABLE IF NOT EXISTS ${T_KV} (
    k TEXT PRIMARY KEY,
    v TEXT NOT NULL DEFAULT ''
  )`,
  `CREATE TABLE IF NOT EXISTS ${T_ACCOUNT} (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL DEFAULT '',
    salt TEXT NOT NULL DEFAULT '',
    hash TEXT NOT NULL DEFAULT '',
    rounds INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT 0,
    last_login_at INTEGER NOT NULL DEFAULT 0
  )`,
  `CREATE INDEX IF NOT EXISTS idx_app_status ON ${T_APP} (status)`,
  `CREATE INDEX IF NOT EXISTS idx_app_applied ON ${T_APP} (applied_at)`,
  `CREATE INDEX IF NOT EXISTS idx_event_happen ON ${T_EVENT} (happen_at)`,
  `CREATE INDEX IF NOT EXISTS idx_event_app ON ${T_EVENT} (app_id)`,
  `CREATE INDEX IF NOT EXISTS idx_review_app ON ${T_REVIEW} (app_id)`
];

/**
 * 数据库单例。
 * 生命周期：EntryAbility.onCreate 里 init 一次，之后所有 Repo 通过 get() 拿同一个 store。
 */
export class DbHelper {
  private static store: relationalStore.RdbStore | undefined = undefined;
  private static pending: Promise<relationalStore.RdbStore> | undefined = undefined;

  static init(context: common.Context): Promise<relationalStore.RdbStore> {
    if (DbHelper.store !== undefined) {
      return Promise.resolve(DbHelper.store);
    }
    if (DbHelper.pending !== undefined) {
      return DbHelper.pending;
    }
    const cfg: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    DbHelper.pending = relationalStore.getRdbStore(context, cfg)
      .then((s: relationalStore.RdbStore): Promise<relationalStore.RdbStore> => {
        return DbHelper.bootstrap(s);
      })
      .catch((e: Error) => {
        Log.e(`DbHelper.init failed: ${e.message}`);
        DbHelper.pending = undefined;
        throw e as Error;
      });
    return DbHelper.pending;
  }

  private static async bootstrap(s: relationalStore.RdbStore): Promise<relationalStore.RdbStore> {
    for (let i = 0; i < DDL_CREATE.length; i++) {
      await s.executeSql(DDL_CREATE[i]);
    }
    if (s.version < DB_VERSION) {
      await DbHelper.migrate(s, s.version);
      s.version = DB_VERSION;
    }
    DbHelper.store = s;
    Log.i(`db ready, version=${s.version}`);
    return s;
  }

  /**
   * 存量数据迁移。
   * 目前只有 v1，没有历史包袱；后续加列时在这里按 fromVersion 分支补 ALTER TABLE。
   */
  private static async migrate(s: relationalStore.RdbStore, fromVersion: number): Promise<void> {
    Log.i(`migrate db from v${fromVersion} to v${DB_VERSION}`);
    // v0 -> v1 是首次建库，DDL_CREATE 已用 IF NOT EXISTS 兜住，无需额外动作。
    // v1 -> v2 加 app_kv 表：同样是纯新建表，IF NOT EXISTS 已覆盖，不需要 ALTER。
    // v2 -> v3 加 account 表：同上，纯新建表。
    // ⚠ 以后加**列**就必须在这里按 fromVersion 分支写 ALTER TABLE —— IF NOT EXISTS 只管建表。
  }

  /** 取 store。未初始化时抛错，调用方需保证 init 已完成。 */
  static get(): Promise<relationalStore.RdbStore> {
    if (DbHelper.store !== undefined) {
      return Promise.resolve(DbHelper.store);
    }
    if (DbHelper.pending !== undefined) {
      return DbHelper.pending;
    }
    return Promise.reject(new Error('DbHelper 未初始化：请在 EntryAbility.onCreate 调用 DbHelper.init(context)'));
  }

  static isReady(): boolean {
    return DbHelper.store !== undefined;
  }

  /** 仅供调试：清空全部业务数据（保留表结构） */
  static async wipe(): Promise<void> {
    const s: relationalStore.RdbStore = await DbHelper.get();
    await s.executeSql(`DELETE FROM ${T_APP}`);
    await s.executeSql(`DELETE FROM ${T_EVENT}`);
    await s.executeSql(`DELETE FROM ${T_REVIEW}`);
    Log.w('all business data wiped');
  }
}
