import { relationalStore } from '@kit.ArkData';
import { DbHelper, T_REVIEW } from '../model/DbHelper';
import { ReviewRecord } from '../common/Types';
import { Log } from '../common/Logger';

function mapRow(rs: relationalStore.ResultSet): ReviewRecord {
  return {
    id: rs.getLong(rs.getColumnIndex('id')),
    appId: rs.getLong(rs.getColumnIndex('app_id')),
    round: rs.getString(rs.getColumnIndex('round')),
    interviewer: rs.getString(rs.getColumnIndex('interviewer')),
    narration: rs.getString(rs.getColumnIndex('narration')),
    radarJson: rs.getString(rs.getColumnIndex('radar_json')),
    scoreAvg: rs.getLong(rs.getColumnIndex('score_avg')),
    createdAt: rs.getLong(rs.getColumnIndex('created_at'))
  };
}

/** 面试复盘存储。narration 是用户原文，radarJson 是 AI 产出的六维打分。 */
export class ReviewRepo {
  static async insert(r: ReviewRecord): Promise<number> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const bucket: relationalStore.ValuesBucket = {
      'app_id': r.appId,
      'round': r.round,
      'interviewer': r.interviewer,
      'narration': r.narration,
      'radar_json': r.radarJson,
      'score_avg': r.scoreAvg,
      'created_at': r.createdAt > 0 ? r.createdAt : Date.now()
    };
    const id: number = await store.insert(T_REVIEW, bucket);
    Log.i(`review inserted id=${id} appId=${r.appId}`);
    return id;
  }

  /** 分析完成后回写分数。只动这两列，避免整行覆盖丢掉用户原文。 */
  static async saveRadar(id: number, radarJson: string, scoreAvg: number): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const bucket: relationalStore.ValuesBucket = {
      'radar_json': radarJson,
      'score_avg': scoreAvg
    };
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(T_REVIEW);
    p.equalTo('id', id);
    await store.update(bucket, p);
  }

  static async updateNarration(id: number, narration: string): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const bucket: relationalStore.ValuesBucket = {
      'narration': narration
    };
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(T_REVIEW);
    p.equalTo('id', id);
    await store.update(bucket, p);
  }

  static async remove(id: number): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(T_REVIEW);
    p.equalTo('id', id);
    await store.delete(p);
  }

  static async listAll(): Promise<ReviewRecord[]> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${T_REVIEW} ORDER BY created_at DESC`
    );
    const out: ReviewRecord[] = [];
    while (rs.goToNextRow()) {
      out.push(mapRow(rs));
    }
    rs.close();
    return out;
  }

  static async listByApp(appId: number): Promise<ReviewRecord[]> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${T_REVIEW} WHERE app_id = ? ORDER BY created_at DESC`, [appId]
    );
    const out: ReviewRecord[] = [];
    while (rs.goToNextRow()) {
      out.push(mapRow(rs));
    }
    rs.close();
    return out;
  }

  static async getById(id: number): Promise<ReviewRecord | undefined> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${T_REVIEW} WHERE id = ? LIMIT 1`, [id]
    );
    let found: ReviewRecord | undefined = undefined;
    if (rs.goToNextRow()) {
      found = mapRow(rs);
    }
    rs.close();
    return found;
  }

  static async count(): Promise<number> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) AS c FROM ${T_REVIEW}`
    );
    let n: number = 0;
    if (rs.goToNextRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  /** 已分析过的复盘条数（radar_json 非空），用于「我的」页展示 AI 使用量 */
  static async analyzedCount(): Promise<number> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) AS c FROM ${T_REVIEW} WHERE radar_json <> ''`
    );
    let n: number = 0;
    if (rs.goToNextRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }
}
