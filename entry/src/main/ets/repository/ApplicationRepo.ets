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

/**
 * 把 Application 转成入库的 ValuesBucket。
 *
 * ⚠ isInsert 的含义是「这次写入是不是新建一行」，它同时决定两个时间戳的取法：
 *   - 新建：尊重调用方给的时间戳（导入/演示数据要能伪造"几天前投的"），
 *           调用方没给（=0）才用 now 兜底。
 *   - 更新：一律盖成 now，编辑过就说明有新动静。
 *
 * ⛔ 早先这里把 applied_at 和 updated_at 都硬写成 now，后果是
 *   `staleApplied()`（按 updated_at < 截止时间 找"投出去 N 天没动静"）在
 *   演示数据下永远查不出任何记录 —— 因为每条的 updated_at 都是刚装 App 的那一刻。
 *   这个 bug 表面上只影响一张卡，实际是"库里的历史"被抹平成了"全是刚刚"。
 */
function toBucket(app: Application, now: number, isInsert: boolean): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {
    'company': app.company,
    'position': app.position,
    'city': app.city,
    'channel': app.channel,
    'status': app.status,
    'salary_min': app.salaryMin,
    'salary_max': app.salaryMax,
    'jd_text': app.jdText,
    'applied_at': isInsert && app.appliedAt > 0 ? app.appliedAt : now,
    'updated_at': isInsert && app.updatedAt > 0 ? app.updatedAt : now,
    'note': app.note
  };
  return bucket;
}

export class ApplicationRepo {
  /**
   * 新增一条投递，返回自增 id。
   *
   * isInsert=true ⇒ app.appliedAt / app.updatedAt 会被原样写进去，
   * 演示数据与批量导入靠这个伪造"几天前投的、之后一直没动"。
   */
  static async insert(app: Application): Promise<number> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const now: number = Date.now();
    const id: number = await store.insert(T_APP, toBucket(app, now, true));
    Log.i(`app inserted id=${id} company=${app.company}`);
    return id;
  }

  /** 全量更新。appliedAt 为 0 时不覆盖原值；updated_at 一律盖成 now（编辑过 = 有新动静）。 */
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
