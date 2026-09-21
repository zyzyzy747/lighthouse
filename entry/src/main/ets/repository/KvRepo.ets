import { relationalStore } from '@kit.ArkData';
import { DbHelper, T_KV } from '../model/DbHelper';
import { Log } from '../common/Logger';

/**
 * 键值表读写。
 *
 * 存在的理由只有一个：**跨进程一致**。
 * 卡片进程（FormExtension）和应用进程（UIAbility）都要读哨兵的配置，
 * 去重记录还要两边都写。Preferences 在 ArkData 里是按进程持缓存的，
 * 两边各读各的、各写各的会互相覆盖；RDB 是同一个文件 + WAL，谁写谁读都对得上。
 */
export class KvRepo {
  static async get(k: string): Promise<string | undefined> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT v FROM ${T_KV} WHERE k = ?`, [k]);
    let out: string | undefined = undefined;
    if (rs.goToNextRow()) {
      out = rs.getString(rs.getColumnIndex('v'));
    }
    rs.close();
    return out;
  }

  /** 一次读回整张表。哨兵要读 6 个键，一次查询比来回 6 次便宜。 */
  static async getAll(): Promise<Record<string, string>> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(`SELECT k, v FROM ${T_KV}`);
    const out: Record<string, string> = {};
    const ki: number = rs.getColumnIndex('k');
    const vi: number = rs.getColumnIndex('v');
    while (rs.goToNextRow()) {
      out[rs.getString(ki)] = rs.getString(vi);
    }
    rs.close();
    return out;
  }

  static async put(k: string, v: string): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const bucket: relationalStore.ValuesBucket = { 'k': k, 'v': v };
    await store.insert(T_KV, bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  }

  static async del(k: string): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    await store.executeSql(`DELETE FROM ${T_KV} WHERE k = ?`, [k]);
  }

  /** 批量写。写在一次事务里，避免卡片进程读到"改了一半"的配置。 */
  static async putAll(map: Record<string, string>): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    try {
      store.beginTransaction();
      const keys: string[] = Object.keys(map);
      for (let i: number = 0; i < keys.length; i++) {
        const bucket: relationalStore.ValuesBucket = { 'k': keys[i], 'v': map[keys[i]] };
        await store.insert(T_KV, bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      }
      store.commit();
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`kv 批量写失败，回滚：${err.message}`);
      store.rollBack();
    }
  }
}
