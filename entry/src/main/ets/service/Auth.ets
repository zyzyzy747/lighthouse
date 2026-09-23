import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper, T_ACCOUNT, K_UNLOCKED, K_USER } from '../model/DbHelper';
import { KvRepo } from '../repository/KvRepo';
import { Log } from '../common/Logger';

/**
 * 本地档案 / 解锁。
 *
 * ══════════════════════════════════════════════════════════════════════
 * 为什么要有它（这决定了实现方式，不是"加个登录页"那么简单）
 * ══════════════════════════════════════════════════════════════════════
 *
 * 求职数据是这台设备上最敏感的东西之一：投了哪些公司、每场面试被怎么评价、
 * 期望薪资多少。这个应用**全程不联网**，所以它不需要云端账号 ——
 * 需要的是"**这把锁**"：把上面那些东西挡在别人（和家人/同学共用电脑时）眼皮之外。
 *
 * 因此三件事是硬约束：
 *
 * ① **密码永不落明文。** 库里只有 PBKDF2|SHA256 派生密钥 + 每账户独立随机盐。
 *    即便有人把 lighthouse.db 拷走，也拿不到密码原文，更推导不出别的账户。
 *
 * ② **锁只拦界面，不拦数据层。** 桌面卡片走的是
 *    `EntryFormAbility → WidgetData → EventRepo`，**完全不经过 UI**。
 *    所以这张锁必须挂在 UI 层（Index 的渲染分支）。一旦有人图省事把它挂到
 *    数据层（未解锁就读不到数据），卡片在未解锁时就直接废掉 ——
 *    而验收脚本全跑在已解锁态，这个错误永远不会被发现。
 *
 * ③ **解锁态必须落库**（app_kv），因为卡片进程要读它来决定脱敏。
 *    放内存的话，卡片进程根本不知道应用解锁了没有。
 *
 * ══════════════════════════════════════════════════════════════════════
 * 单账户 + 只验密码
 * ══════════════════════════════════════════════════════════════════════
 * 这是"设备锁屏"的模型：用户名只是给界面显示用的称呼（头像首字），
 * 登录时**只校验密码**。理由：用户可能过两周忘了自己当初填的是"小曾"还是"曾有"，
 * 但密码一定记得 —— 让人因为想不起称呼而被自己的数据挡在门外，是纯粹的坏事。
 */

/**
 * ⚠ K_UNLOCKED / K_USER 定义在 model/DbHelper（卡片进程也要读，但不该被拖进密码学依赖）。
 */

const SALT_BYTES: number = 16;
const KEY_BYTES: number = 32;
/**
 * 迭代轮数。取值权衡：手机上解锁要"感觉是即时的"，
 * 而 12000 轮 PBKDF2|SHA256 在模拟器上实测是可感知但不烦人的量级。
 * ⚠ 这个数字会写进 account.rounds 存档 —— 以后要提高轮数，
 *   老记录照旧用自己那一轮校验（见 verify），不会把老用户锁在门外。
 */
const ROUNDS: number = 12000;
const ALGO: string = 'PBKDF2|SHA256';

export const USER_MIN: number = 1;
export const USER_MAX: number = 12;
export const PASS_MIN: number = 6;
export const PASS_MAX: number = 32;

/**
 * 自检档案的凭据。
 *
 * ⚠ 这是**公开的**：任何能执行 `hdc shell aa start` 的人都能带 `lh_autologin`
 *   进来，所以这个密码不构成额外的安全边界，它只是让验收脚本能走完
 *   **真实的**注册/登录链路（而不是"跳过登录"那种旁路）。
 *   真正的保护来自"设备在你自己手上"—— 与所有本地明文数据库的应用同一个模型。
 */
export const SELFTEST_USER: string = 'selftest';
export const SELFTEST_PASS: string = 'selftest-2026';

export interface AuthResult {
  ok: boolean;
  /** 直接给用户看的一句话。失败时不许泄露"这个用户名存在/不存在"这类信息。 */
  reason: string;
}

/** 档案摘要（界面只需要称呼和创建时间，不需要盐和密钥） */
export interface AccountInfo {
  username: string;
  createdAt: number;
  lastLoginAt: number;
}

/** 账户行（含敏感列）。只在 Auth 内部流转，绝不出这个类。 */
interface AccountRow {
  username: string;
  salt: string;
  hash: string;
  rounds: number;
  createdAt: number;
  lastLoginAt: number;
}

export class Auth {
  /**
   * 本次启动要做的会话初始化（锁定 + 可选自检自动登录）。
   *
   * ⚠ 存成 promise 而不是直接 await 的原因：
   *   EntryAbility.onCreate 里不能阻塞（会把冷启动拖慢），
   *   而 Index 的 aboutToAppear 必须**等它做完**再读解锁态 ——
   *   否则会读到锁定前的旧值，自检登录就白做了。
   *   `settle()` 就是给界面用的那个汇合点。
   */
  private static pending: Promise<void> | undefined = undefined;

  /* ------------------------------------------------------------------ 口令学 */

  private static toHex(b: Uint8Array): string {
    let s: string = '';
    for (let i: number = 0; i < b.length; i++) {
      const h: string = b[i].toString(16);
      s += h.length === 1 ? `0${h}` : h;
    }
    return s;
  }

  private static fromHex(s: string): Uint8Array {
    const n: number = Math.floor(s.length / 2);
    const out: Uint8Array = new Uint8Array(n);
    for (let i: number = 0; i < n; i++) {
      out[i] = parseInt(s.substring(i * 2, i * 2 + 2), 16);
    }
    return out;
  }

  private static newSalt(): Uint8Array {
    const rnd: cryptoFramework.Random = cryptoFramework.createRandom();
    const blob: cryptoFramework.DataBlob = rnd.generateRandomSync(SALT_BYTES);
    return blob.data;
  }

  /** 口令 → 派生密钥（hex）。走平台 CryptoArchitectureKit，不自己搓哈希。 */
  private static derive(pass: string, salt: Uint8Array, rounds: number): string {
    const kdf: cryptoFramework.Kdf = cryptoFramework.createKdf(ALGO);
    const spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: pass,
      salt: salt,
      iterations: rounds,
      keySize: KEY_BYTES
    };
    const out: cryptoFramework.DataBlob = kdf.generateSecretSync(spec);
    return Auth.toHex(out.data);
  }

  /* ------------------------------------------------------------------ 校验规则 */

  /**
   * 输入校验。返回空串 = 通过，否则是给用户看的错误。
   *
   * ⚠ 这些规则同时被界面（即时提示）和 Auth（兜底）用，只写一份。
   */
  static validateNew(user: string, pass: string, confirm: string): string {
    const u: string = user.trim();
    if (u.length < USER_MIN || u.length > USER_MAX) {
      return `称呼请填 ${USER_MIN}~${USER_MAX} 个字`;
    }
    if (pass.length < PASS_MIN) {
      return `密码至少 ${PASS_MIN} 位`;
    }
    if (pass.length > PASS_MAX) {
      return `密码最多 ${PASS_MAX} 位`;
    }
    if (pass !== confirm) {
      return '两次输入的密码不一样';
    }
    return '';
  }

  /* ------------------------------------------------------------------ 档案读写 */

  private static async firstRow(): Promise<AccountRow | undefined> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT username, salt, hash, rounds, created_at, last_login_at FROM ${T_ACCOUNT} ORDER BY id LIMIT 1`);
    if (!rs.goToNextRow()) {
      rs.close();
      return undefined;
    }
    const row: AccountRow = {
      'username': rs.getString(rs.getColumnIndex('username')),
      'salt': rs.getString(rs.getColumnIndex('salt')),
      'hash': rs.getString(rs.getColumnIndex('hash')),
      'rounds': rs.getLong(rs.getColumnIndex('rounds')),
      'createdAt': rs.getLong(rs.getColumnIndex('created_at')),
      'lastLoginAt': rs.getLong(rs.getColumnIndex('last_login_at'))
    };
    rs.close();
    return row;
  }

  /** 这台设备上是否已经建过档案。首次启动据此决定显示"创建"还是"解锁"。 */
  static async hasAccount(): Promise<boolean> {
    try {
      const row: AccountRow | undefined = await Auth.firstRow();
      return row !== undefined;
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`档案查询失败：${err.message}`);
      return false;
    }
  }

  static async info(): Promise<AccountInfo | undefined> {
    const row: AccountRow | undefined = await Auth.firstRow();
    if (row === undefined) {
      return undefined;
    }
    const info: AccountInfo = {
      username: row.username,
      createdAt: row.createdAt,
      lastLoginAt: row.lastLoginAt
    };
    return info;
  }

  /** 创建档案。已存在则拒绝（不会静默覆盖别人的档案）。 */
  static async createAccount(user: string, pass: string): Promise<AuthResult> {
    const name: string = user.trim();
    if (name.length < USER_MIN || name.length > USER_MAX) {
      return { ok: false, reason: `称呼请填 ${USER_MIN}~${USER_MAX} 个字` };
    }
    if (pass.length < PASS_MIN) {
      return { ok: false, reason: `密码至少 ${PASS_MIN} 位` };
    }
    try {
      if (await Auth.hasAccount()) {
        return { ok: false, reason: '这台设备上已经有档案了，直接解锁就行' };
      }
      const salt: Uint8Array = Auth.newSalt();
      const hash: string = Auth.derive(pass, salt, ROUNDS);
      const now: number = Date.now();
      const store: relationalStore.RdbStore = await DbHelper.get();
      const bucket: relationalStore.ValuesBucket = {
        'username': name,
        'salt': Auth.toHex(salt),
        'hash': hash,
        'rounds': ROUNDS,
        'created_at': now,
        'last_login_at': now
      };
      await store.insert(T_ACCOUNT, bucket);
      // 建完就直接进去 —— 刚设的密码没必要让用户再输一遍
      await Auth.markUnlocked(name);
      Log.i(`本地档案已创建：${name}（盐 ${SALT_BYTES}B / ${ROUNDS} 轮 PBKDF2）`);
      return { ok: true, reason: '档案已创建' };
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`创建档案失败：${err.message}`);
      return { ok: false, reason: '创建失败，请重试' };
    }
  }

  /**
   * 用密码解锁。
   *
   * ⚠ 失败原因一律是同一句话，不区分"没档案 / 密码错"——
   *   虽然本地单账户场景泄露这个信息危害有限，但这是口令接口该有的肌肉记忆，
   *   而且这里将来若要支持多账户，不改就会真的泄露。
   */
  static async login(pass: string): Promise<AuthResult> {
    try {
      const row: AccountRow | undefined = await Auth.firstRow();
      if (row === undefined) {
        return { ok: false, reason: '这台设备上还没有档案' };
      }
      // ⚠ 用记录里存的轮数，而不是当前的常量 —— 这样以后提高 ROUNDS
      //   也不会把老档案锁在门外（旧记录照旧用自己那一轮校验）。
      const rounds: number = row.rounds > 0 ? row.rounds : ROUNDS;
      const salt: Uint8Array = Auth.fromHex(row.salt);
      const got: string = Auth.derive(pass, salt, rounds);

      if (got !== row.hash) {
        Log.w('解锁失败：口令不符');
        return { ok: false, reason: '密码不对' };
      }
      const name: string = row.username;
      await Auth.markUnlocked(name);
      await Auth.touchLogin();
      Log.i(`已解锁：${name}`);
      return { ok: true, reason: '已解锁' };
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`解锁异常：${err.message}`);
      return { ok: false, reason: '解锁失败，请重试' };
    }
  }

  private static async touchLogin(): Promise<void> {
    const store: relationalStore.RdbStore = await DbHelper.get();
    await store.executeSql(
      `UPDATE ${T_ACCOUNT} SET last_login_at = ? WHERE id = (SELECT id FROM ${T_ACCOUNT} ORDER BY id LIMIT 1)`,
      [Date.now()]);
  }

  private static async markUnlocked(name: string): Promise<void> {
    const map: Record<string, string> = {};
    map[K_UNLOCKED] = '1';
    map[K_USER] = name;
    await KvRepo.putAll(map);
  }

  /* ------------------------------------------------------------------ 会话状态 */

  /**
   * 冷启动时把会话置回"未解锁"。
   *
   * 为什么每次冷启动都要锁：这台应用的价值就在"数据只在这台设备上"，
   * 那"谁都能打开看"就等于保护不存在。锁屏式的每次启动验证是这个模型的标准做法。
   *
   * ⚠ 注意它**只影响界面**：卡片进程读到的 '0' 会让卡片进入脱敏，
   *   但不会让卡片没数据 —— 见 WidgetData。
   */
  static async lockSession(): Promise<void> {
    try {
      await KvRepo.put(K_UNLOCKED, '0');
      Log.i('会话已锁定（本次启动需要解锁）');
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`会话锁定失败：${err.message}`);
    }
  }

  static async isUnlocked(): Promise<boolean> {
    try {
      const v: string | undefined = await KvRepo.get(K_UNLOCKED);
      return v === '1';
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`解锁态读取失败：${err.message}`);
      return false;
    }
  }

  static async currentUser(): Promise<string> {
    try {
      const v: string | undefined = await KvRepo.get(K_USER);
      return v === undefined ? '' : v;
    } catch (e) {
      return '';
    }
  }

  /* ------------------------------------------------------------------ 重置 */

  /**
   * 清空档案与全部业务数据，回到"第一次启动"的状态。
   *
   * ⚠⚠ **必须连业务数据一起清**，这不是顺手做的事：
   *   只删 account 表的话，"忘记密码"立刻变成一条绕过密码看数据的后门 ——
   *   重置一下就能读到全部投递记录和面试评价，那这把锁就是摆设。
   *   要么一起清，要么就别提供这个入口（让用户去卸载重装，效果一样但体验差）。
   */
  static async resetAll(): Promise<void> {
    try {
      const store: relationalStore.RdbStore = await DbHelper.get();
      await store.executeSql(`DELETE FROM ${T_ACCOUNT}`);
      await DbHelper.wipe();
      const map: Record<string, string> = {};
      map[K_UNLOCKED] = '0';
      map[K_USER] = '';
      await KvRepo.putAll(map);
      Log.w('本地档案与业务数据已重置');
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`重置失败：${err.message}`);
    }
  }

  /* ------------------------------------------------------------------ 自检通道 */

  /**
   * 自检：把档案表里**实际存了什么**打进日志 —— 用来证明"密码没有落明文"。
   *
   * 为什么非要有它：设备的应用私有目录（`/data/app/el2/...`）对 shell 用户是
   * `Permission denied`，而模拟器上连 `run-as` 都没有 —— 脚本**捞不到库文件**去 grep。
   * 既然捞不出来，就让应用自己把存的东西念出来：脚本拿密码原文去搜日志，
   * **搜得到就是漏洞，搜不到才算过**。
   *
   * ⚠ 只打 hash 的前 8 位 + 总长度：够看出"存的是 64 位 hex 派生值"、
   *   够看出"每行都有独立的盐"，又不至于把完整派生值留在日志里 ——
   *   日志本身就是最容易泄露的地方，能少写就少写。
   */
  static async selfTestDump(): Promise<void> {
    try {
      const store: relationalStore.RdbStore = await DbHelper.get();
      const rs: relationalStore.ResultSet = await store.querySql(
        `SELECT username, salt, hash, rounds FROM ${T_ACCOUNT}`);
      let n: number = 0;
      while (rs.goToNextRow()) {
        n++;
        const u: string = rs.getString(rs.getColumnIndex('username'));
        const salt: string = rs.getString(rs.getColumnIndex('salt'));
        const hash: string = rs.getString(rs.getColumnIndex('hash'));
        const rounds: number = rs.getLong(rs.getColumnIndex('rounds'));
        const head: string = hash.length > 8 ? hash.substring(0, 8) : hash;
        Log.i(`档案自检：user=${u} saltLen=${salt.length} hash=${head}..len=${hash.length} rounds=${rounds}`);
      }
      rs.close();
      Log.i(`档案自检：档案表共 ${n} 行`);
      // 顺带把 kv 表也念一遍：万一有人图省事把凭据塞进了配置表，这里要能抓到
      const kv: Record<string, string> = await KvRepo.getAll();
      const keys: string[] = Object.keys(kv);
      for (let i: number = 0; i < keys.length; i++) {
        Log.i(`档案自检：kv ${keys[i]}=${kv[keys[i]]}`);
      }
      Log.i('档案自检：完成');
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`档案自检失败：${err.message}`);
    }
  }

  /**
   * 自检自动登录：`aa start ... --pi lh_autologin 1`。
   *
   * ★ 这条通道**不跳过登录**，而是把真实的注册/登录链路完整跑一遍 ——
   *   这正是它比一个 `lh_skip_login` 开关值钱的地方：
   *     ① 冷启动（脚本每次卸载重装）= 走 `createAccount`，
   *     ② 保留数据再启动（--keep / 同一安装内再跑）= 走 `login`，
   *   两条真实分支都被覆盖，而不是把它们绕过去。
   *
   * ⚠ 它必须在 `lh_load_demo` **之前**生效：载入数据是写业务表，
   *   而界面此时还被登录门挡着的话，脚本会看到"数据载入了但界面是空的"。
   */
  static async selfTestLogin(): Promise<AuthResult> {
    if (await Auth.hasAccount()) {
      return await Auth.login(SELFTEST_PASS);
    }
    return await Auth.createAccount(SELFTEST_USER, SELFTEST_PASS);
  }

  /** 由 EntryAbility 在 onCreate 调用一次：锁定本次会话，并按需跑自检登录。 */
  static bootstrapSession(autoLogin: boolean): void {
    Auth.pending = Auth.runBootstrap(autoLogin);
  }

  private static async runBootstrap(autoLogin: boolean): Promise<void> {
    try {
      await Auth.lockSession();
      if (!autoLogin) {
        return;
      }
      const r: AuthResult = await Auth.selfTestLogin();
      Log.i(`自检：自动登录${r.ok ? '成功' : '失败'}（${r.reason}）`);
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`自检：会话初始化异常：${err.message}`);
    }
  }

  /** 热启动路径（`onNewWant`）上的自检登录：不重新锁定当前会话。 */
  static applySelfTestLogin(flag: boolean): void {
    Auth.pending = Auth.runSelfLoginOnly(flag);
  }

  private static async runSelfLoginOnly(flag: boolean): Promise<void> {
    if (!flag) {
      return;
    }
    try {
      const r: AuthResult = await Auth.selfTestLogin();
      Log.i(`自检：自动登录${r.ok ? '成功' : '失败'}（${r.reason}）`);
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`自检：自动登录异常：${err.message}`);
    }
  }

  /**
   * 界面读取解锁态前必须先过这里。
   *
   * ⚠ 不这么做就是竞态：EntryAbility.onCreate 里的自检登录是异步的，
   *   而 Index.aboutToAppear 可能先跑完 —— 它会读到锁定时的 '0'，
   *   于是自检启动也会停在登录页，脚本红得莫名其妙。
   */
  static async settle(): Promise<void> {
    const p: Promise<void> | undefined = Auth.pending;
    if (p === undefined) {
      return;
    }
    try {
      await p;
    } catch (e) {
      // runBootstrap 内部已吞异常，这里只防御性兜底
    }
    if (Auth.pending === p) {
      Auth.pending = undefined;
    }
  }
}
