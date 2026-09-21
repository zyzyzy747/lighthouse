import { relationalStore } from '@kit.ArkData';
import { DbHelper, T_APP, T_EVENT } from '../model/DbHelper';
import { Application, AppStatus, getStatusMeta } from '../common/Types';
import { Log } from '../common/Logger';

/** 某状态下的投递数量 */
export class StatusCount {
  status: string = '';
  count: number = 0;

  constructor(status: string, count: number) {
    this.status = status;
    this.count = count;
  }
}

/** 漏斗整体概览：作战地图首屏要的全部数字，一次查完 */
export class FunnelStat {
  total: number = 0;
  active: number = 0;          // 仍在推进中（未结束/未放弃）
  interview: number = 0;       // 进到面试及以后的
  offer: number = 0;
  /** 面试转化率：进入面试 / 已投递，0-1 */
  interviewRate: number = 0;
  /** offer 转化率 */
  offerRate: number = 0;
  byStatus: StatusCount[] = [];
}

function mapRow(rs: relationalStore.ResultSet): Application {
  return {
    id: rs.getLong(rs.getColumnIndex('id')),
    company: rs.getString(rs.getColumnIndex('company')),
    position: rs.getString(rs.getColumnIndex('position')),
    city: rs.getString(rs.getColumnIndex('city')),
    channel: rs.getString(rs.getColumnIndex('channel')),
    status: rs.getString(rs.getColumnIndex('status')),
    salaryMin: rs.getLong(rs.getColumnIndex('salary_min')),
    salaryMax: rs.getLong(rs.getColumnIndex('salary_max')),
    jdText: rs.getString(rs.getColumnIndex('jd_text')),
    appliedAt: rs.getLong(rs.getColumnIndex('applied_at')),
    updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
    note: rs.getString(rs.getColumnIndex('note'))
  };
}

function toBucket(app: Application, now: number, keepAppliedAt: boolean): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {
    'company': app.company,
    'position': app.position,
    'city': app.city,
    'channel': app.channel,
    'status': app.status,
    'salary_min': app.salaryMin,
    'salary_max': app.salaryMax,
    'jd_text': app.jdText,
    'applied_at': keepAppliedAt && app.appliedAt > 0 ? app.appliedAt : now,
    'updated_at': now,
    'note': app.note
  };
  return bucket;
}

export class ApplicationRepo {
  /** 新增一条投递，返回自增 id */
  static async insert(app: Application): Promise<number> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const now: number = Date.now();
    const id: number = await store.insert(T_APP, toBucket(app, now, true));
    Log.i(`app inserted id=${id} company=${app.company}`);
    return id;
  }

  /** 全量更新。appliedAt 为 0 时不覆盖原值。 */
  static async update(app: Application): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const bucket: relationalStore.ValuesBucket = toBucket(app, Date.now(), false);
    if (app.appliedAt > 0) {
      bucket['applied_at'] = app.appliedAt;
    }
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(T_APP);
    p.equalTo('id', app.id);
    const n: number = await store.update(bucket, p);
    Log.i(`app updated id=${app.id} rows=${n}`);
  }

  /** 只改状态，状态流转是高频操作，避免整行回写 */
  static async updateStatus(id: number, status: string): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const bucket: relationalStore.ValuesBucket = {
      'status': status,
      'updated_at': Date.now()
    };
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(T_APP);
    p.equalTo('id', id);
    await store.update(bucket, p);
  }

  /**
   * 只写 JD 原文。
   *
   * ⚠ 不复用 update()：那个是全量回写，调用方得先把整条记录读出来再改一个字段再写回去，
   *   中间任何一次读失败或并发改动都会把别的字段一起覆盖掉。JD 是长文本、写入时机独立，
   *   单独一条 UPDATE 最稳。
   */
  static async updateJd(id: number, jdText: string): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const bucket: relationalStore.ValuesBucket = {
      'jd_text': jdText,
      'updated_at': Date.now()
    };
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(T_APP);
    p.equalTo('id', id);
    const n: number = await store.update(bucket, p);
    Log.i(`app jd saved id=${id} len=${jdText.length} rows=${n}`);
  }

  /** 删除投递，连带清掉它的节点与复盘，避免留孤儿数据 */
  static async remove(id: number): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const p: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(T_APP);
    p.equalTo('id', id);
    await store.delete(p);
    const pe: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(T_EVENT);
    pe.equalTo('app_id', id);
    await store.delete(pe);
    Log.i(`app removed id=${id}`);
  }

  static async listAll(): Promise<Application[]> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${T_APP} ORDER BY updated_at DESC`
    );
    const out: Application[] = [];
    while (rs.goToNextRow()) {
      out.push(mapRow(rs));
    }
    rs.close();
    return out;
  }

  static async listByStatus(status: string): Promise<Application[]> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${T_APP} WHERE status = ? ORDER BY updated_at DESC`, [status]
    );
    const out: Application[] = [];
    while (rs.goToNextRow()) {
      out.push(mapRow(rs));
    }
    rs.close();
    return out;
  }

  static async getById(id: number): Promise<Application | undefined> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${T_APP} WHERE id = ? LIMIT 1`, [id]
    );
    let found: Application | undefined = undefined;
    if (rs.goToNextRow()) {
      found = mapRow(rs);
    }
    rs.close();
    return found;
  }

  /** 漏斗概览。地图页和卡片都吃这一份数据，保证两处数字一致。 */
  static async funnel(): Promise<FunnelStat> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT status, COUNT(*) AS c FROM ${T_APP} GROUP BY status`
    );
    const byStatus: StatusCount[] = [];
    let total: number = 0;
    let offer: number = 0;
    let interview: number = 0;
    let active: number = 0;
    let delivered: number = 0;
    while (rs.goToNextRow()) {
      const st: string = rs.getString(rs.getColumnIndex('status'));
      const c: number = rs.getLong(rs.getColumnIndex('c'));
      byStatus.push(new StatusCount(st, c));
      total += c;
      if (!getStatusMeta(st).inFunnel) {
        continue;
      }
      active += c;
      if (st === AppStatus.OFFER) {
        offer += c;
      }
      // 面试转化率分母是「真正投出去并推进过的」，想投阶段不算
      const ord: number = getStatusMeta(st).order;
      if (ord >= getStatusMeta(AppStatus.APPLIED).order) {
        delivered += c;
      }
      if (ord >= getStatusMeta(AppStatus.INTERVIEW).order) {
        interview += c;
      }
    }
    rs.close();
    const f: FunnelStat = new FunnelStat();
    f.total = total;
    f.active = active;
    f.offer = offer;
    f.interview = interview;
    f.byStatus = byStatus;
    f.interviewRate = delivered > 0 ? interview / delivered : 0;
    f.offerRate = delivered > 0 ? offer / delivered : 0;
    return f;
  }

  static async countByStatus(status: string): Promise<number> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) AS c FROM ${T_APP} WHERE status = ?`, [status]
    );
    let n: number = 0;
    if (rs.goToNextRow()) {
      n = rs.getLong(rs.getColumnIndex('c'));
    }
    rs.close();
    return n;
  }

  /** 取「最近该跟进」的记录：投出去超过 N 天还没动静的 */
  static async staleApplied(days: number): Promise<Application[]> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const cut: number = Date.now() - days * 24 * 60 * 60 * 1000;
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${T_APP} WHERE status IN (?, ?) AND updated_at < ? ORDER BY updated_at ASC`,
      [AppStatus.APPLIED, AppStatus.SCREEN, cut]
    );
    const out: Application[] = [];
    while (rs.goToNextRow()) {
      out.push(mapRow(rs));
    }
    rs.close();
    return out;
  }
}
