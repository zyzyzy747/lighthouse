import { relationalStore } from '@kit.ArkData';
import { DbHelper, T_EVENT } from '../model/DbHelper';
import { EventNode } from '../common/Types';
import { Log } from '../common/Logger';

function mapRow(rs: relationalStore.ResultSet): EventNode {
  return {
    id: rs.getLong(rs.getColumnIndex('id')),
    appId: rs.getLong(rs.getColumnIndex('app_id')),
    type: rs.getString(rs.getColumnIndex('type')),
    title: rs.getString(rs.getColumnIndex('title')),
    happenAt: rs.getLong(rs.getColumnIndex('happen_at')),
    done: rs.getLong(rs.getColumnIndex('done')) > 0,
    note: rs.getString(rs.getColumnIndex('note'))
  };
}

/** 事件节点：笔试 / 面试 / 投递截止。哨兵与桌面卡片的数据源。 */
export class EventRepo {
  static async insert(e: EventNode): Promise<number> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const bucket: relationalStore.ValuesBucket = {
      'app_id': e.appId,
      'type': e.type,
      'title': e.title,
      'happen_at': e.happenAt,
      'done': e.done ? 1 : 0,
      'note': e.note
    };
    const id: number = await store.insert(T_EVENT, bucket);
    Log.i(`event inserted id=${id} type=${e.type} at=${e.happenAt}`);
    return id;
  }

  static async update(e: EventNode): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const bucket: relationalStore.ValuesBucket = {
      'app_id': e.appId,
      'type': e.type,
      'title': e.title,
      'happen_at': e.happenAt,
      'done': e.done ? 1 : 0,
      'note': e.note
    };
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(T_EVENT);
    p.equalTo('id', e.id);
    await store.update(bucket, p);
  }

  static async markDone(id: number, done: boolean): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const bucket: relationalStore.ValuesBucket = {
      'done': done ? 1 : 0
    };
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(T_EVENT);
    p.equalTo('id', id);
    await store.update(bucket, p);
  }

  static async remove(id: number): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(T_EVENT);
    p.equalTo('id', id);
    await store.delete(p);
  }

  static async listByApp(appId: number): Promise<EventNode[]> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${T_EVENT} WHERE app_id = ? ORDER BY happen_at ASC`, [appId]
    );
    return EventRepo.drain(rs);
  }

  /** 未完成且尚未发生的节点，按时间升序。哨兵只关心这批。 */
  static async upcoming(limit: number): Promise<EventNode[]> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${T_EVENT} WHERE done = 0 AND happen_at >= ? ORDER BY happen_at ASC LIMIT ?`,
      [Date.now(), limit]
    );
    return EventRepo.drain(rs);
  }

  /** 已逾期但未标记完成的节点 —— 这些是真实的「可能错过」风险 */
  static async overdue(): Promise<EventNode[]> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${T_EVENT} WHERE done = 0 AND happen_at < ? ORDER BY happen_at DESC`,
      [Date.now()]
    );
    return EventRepo.drain(rs);
  }

  static async pendingCount(): Promise<number> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) AS c FROM ${T_EVENT} WHERE done = 0 AND happen_at >= ?`, [Date.now()]
    );
    let n: number = 0;
    if (rs.goToNextRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  /** 全部未完成节点（含逾期），按时间升序。哨兵页完整视图。 */
  static async allPending(): Promise<EventNode[]> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${T_EVENT} WHERE done = 0 ORDER BY happen_at ASC`
    );
    return EventRepo.drain(rs);
  }

  private static drain(rs: relationalStore.ResultSet): EventNode[] {
    const out: EventNode[] = [];
    while (rs.goToNextRow()) {
      out.push(mapRow(rs));
    }
    rs.close();
    return out;
  }
}
