import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Application, AppStatus, STATUS_LIST, StatusMeta, EventNode, EventType, EventTypeMeta, getStatusMeta, getEventTypeMeta, emptyApplication } from '../common/Types';
import { JdSkillItem } from '../common/AiTypes';
import { Palette, Metrics, CHANNEL_OPTIONS, CITY_OPTIONS } from '../common/Theme';
import { ApplicationRepo } from '../repository/ApplicationRepo';
import { EventRepo } from '../repository/EventRepo';
import { JdAnalyzer, JdOutcome } from '../service/JdAnalyzer';
import { VoiceMemo, DictState, DictationListener, DictStart } from '../service/VoiceMemo';
import { fmtDate, fmtSalary, isEmpty, humanDeadline, countdownText, dayDiff } from '../common/Utils';
import { Log } from '../common/Logger';

/** @Styles 只能用通用属性 */
@Styles
function panel() {
  .backgroundColor(Palette.PANEL)
  .borderRadius(Metrics.CARD_RADIUS)
}

/** ⚠ @Styles 不能放组件专有属性（fontSize/placeholderColor），必须用 @Extend(TextInput) */
@Extend(TextInput)
function quickField() {
  .backgroundColor(Palette.PANEL_2)
  .borderRadius(Metrics.CHIP_RADIUS)
  .fontSize(14)
  .fontColor(Palette.TX)
  .placeholderColor(Palette.TX_3)
  .height(44)
}

/** 备注框：和输入框同款，但要能多行 */
@Extend(TextArea)
function noteField() {
  .backgroundColor(Palette.PANEL_2)
  .borderRadius(Metrics.CHIP_RADIUS)
  .fontSize(13.5)
  .fontColor(Palette.TX)
  .placeholderColor(Palette.TX_3)
  .height(72)
}

/** 选项下标。找不到返回 -1 —— Select 会视为「没有选中项」，正是我们要的 */
function indexOfOpt(list: string[], v: string): number {
  for (let i = 0; i < list.length; i++) {
    if (list[i] === v) {
      return i;
    }
  }
  return -1;
}

/**
 * 列表项上那行「下一个节点」的摘要。
 *
 * 为什么预先算好、而不是在 @Builder 里现查：
 *   @Builder 里不能 await，也不能声明局部变量，每渲染一行都去查一次库
 *   会让列表滚动卡顿。在 reload() 里一次性算完，@Builder 只读不算。
 */
interface NextNode {
  appId: number;
  type: string;
  label: string;     // 「面试」/「笔试」/「投递截止」/「其他」
  color: string;
  when: string;      // 「明天 14:30」/「已过 2 天 · 09-18」
  countdown: string; // 「3 天 4 小时」/「已开始」
  days: number;      // 自然日差：0=今天，1=明天，负数=逾期
}

/** 筛选栏的一个快捷项。key 为空串表示「不筛」。 */
class FilterDef {
  key: string;
  label: string;

  constructor(key: string, label: string) {
    this.key = key;
    this.label = label;
  }
}

/** 聚合筛选用特殊 key（不是真实的 AppStatus 值，以 # 开头区分） */
const F_ACTIVE: string = '#active';   // 还在流程里：已投递 / 沟通中 / 笔试 / 面试
const F_CLOSED: string = '#closed';   // 已结束 / 已放弃
const F_NODE: string = '#node';       // 挂着未完成节点的（笔试 / 面试 / 截止 / 其他）

const FILTER_DEFS: FilterDef[] = [
  new FilterDef('', '全部'),
  new FilterDef(F_ACTIVE, '进行中'),
  new FilterDef(F_NODE, '有安排'),
  new FilterDef(AppStatus.APPLIED, '已投'),
  new FilterDef(AppStatus.SCREEN, '沟通'),
  new FilterDef(AppStatus.WRITTEN, '笔试'),
  new FilterDef(AppStatus.INTERVIEW, '面试'),
  new FilterDef(AppStatus.OFFER, 'Offer'),
  new FilterDef(F_CLOSED, '已结束')
];

/** 进行中 = 流程未终止、也不含还没投的「想投」 */
function isActiveStatus(s: string): boolean {
  return s === AppStatus.APPLIED || s === AppStatus.SCREEN
    || s === AppStatus.WRITTEN || s === AppStatus.INTERVIEW;
}

/**
 * 投递快记。
 * 设计目标：默认只填公司名就能存 —— 其余字段全部有合理默认值，保证「3 秒一条」。
 */
@Component
export struct QuickRecordView {
  @Prop @Watch('onTick') tick: number = 0;
  onChanged: () => void = (): void => {};

  @State apps: Application[] = [];
  @State company: string = '';
  /** ⚠ 不能叫 position —— 与 CustomComponent 基类的 position() 布局方法冲突 */
  @State job: string = '';
  @State city: string = '武汉';
  @State cityIdx: number = 0;
  @State channel: string = '官网';
  @State channelIdx: number = 0;
  @State status: string = AppStatus.APPLIED;
  @State salaryMin: string = '';
  @State salaryMax: string = '';
  @State deadline: number = 0;
  @State showMore: boolean = false;
  @State saving: boolean = false;

  // ── 语音速记（只服务备注这一个字段） ──
  /** 备注草稿。表单里唯一一个历来没入口的字段，加上它顺便把 note 用起来。 */
  @State note: string = '';
  @State dictState: string = DictState.IDLE;
  /** 麦克风旁边的状态说明（"正在听…"/"听到了"…），失败原因也走这里 */
  @State dictHint: string = '';
  /** 实时识别草稿：只在听的时候显示，定稿后并进 note */
  @State dictLive: string = '';

  /* ---- 列表筛选 ---- */
  @State query: string = '';
  @State statusFilter: string = '';
  /** appId → 下一个节点。reload 时算好，@Builder 只读不算。 */
  @State nextNodes: NextNode[] = [];

  /**
   * 正在编辑的记录 id，0 = 新建。
   * 编辑复用同一张表单，而不是再开一个页面：字段完全一样，
   * 复制一份出来只会让两边以后慢慢长歪。
   */
  @State editingId: number = 0;
  /** 这条记录已存在的「投递截止」节点 id —— 截止时间存在事件表里，改/删都要靠它定位 */
  @State deadlineEvId: number = 0;

  /** 单栏主列表 / 双栏左列。编辑时要把表单滚回视野，否则用户以为点了没反应 */
  private listScroller: Scroller = new Scroller();
  private formScroller: Scroller = new Scroller();

  /** 宽屏双栏。⚠ @StorageProp 的参数必须写字面量（编译期求值），不能传常量变量 */
  @StorageProp('lhTwoPane') twoPane: boolean = false;

  /* ==================== JD 岗位匹配面板 ==================== */

  /**
   * 面板是否打开：用「记录 id + 公司名」而不是一个 Application 对象。
   * 用对象的话，列表 reload 之后引用会变，面板要么闪一下要么显示旧数据。
   */
  @State jdForId: number = 0;
  @State jdForName: string = '';
  @State jdText: string = '';
  @State jdProfile: string = '';
  @State jdEditProfile: boolean = false;
  @State jdBusy: boolean = false;

  /**
   * 结果拆成一组基本类型，而不是存一个 JdOutcome 对象。
   * ⚠ 原因：@Builder 里不能写 `const out = this.jdOutcome`，于是每次访问都得写
   *   `this.jdOutcome!.analysis.gapScore` 这种链式断言，既容易崩也不易读。
   *   拆平之后 @Builder 直接读 this.jdScore，简单可靠。
   */
  @State jdHasResult: boolean = false;
  @State jdScore: number = 0;
  @State jdJobTitle: string = '';
  @State jdItems: JdSkillItem[] = [];
  @State jdFocus: string[] = [];
  @State jdPlan: string[] = [];
  @State jdEngine: string = '';
  @State jdFromCloud: boolean = false;
  @State jdWhy: string = '';
  @State jdLatency: number = 0;
  @State jdTokens: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  /**
   * 页面销毁时如果还在录，把麦克风和引擎收掉。
   *
   * 不收的话录音器会一直抓着麦克风 —— 用户以为退出去了，其实还在采。 
   * 用的是 cancel 而不是 stop：页面都没了，识别结果也没地方放。
   */
  aboutToDisappear(): void {
    if (this.dictBusy() || this.dictState === DictState.FINISHING) {
      VoiceMemo.cancelDictation().catch((err: Error) => {
        Log.w(`语音：页面销毁时取消速记失败 ${err.message}`);
      });
    }
  }

  onTick(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      this.apps = await ApplicationRepo.listAll();
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`QuickRecord reload failed: ${err.message}`);
    }
    await this.reloadNextNodes();
  }

  /**
   * 汇总每条记录「下一个节点」，画在列表卡片上。
   *
   * 「下一个节点」取谁：
   *   未完成里**还没到**的最早那个（最该被提醒的）；
   *   一个都没有、但存在逾期的，退而显示最近那一条逾期（它同样是真实的遗漏）。
   *
   * allPending() 已按 happen_at 升序返回 ⇒ 同一个 appId 第一次出现即「最早」，
   * 逾期组用倒序走一遍即「最近」。
   */
  private async reloadNextNodes(): Promise<void> {
    try {
      const pend: EventNode[] = await EventRepo.allPending();
      const now: number = Date.now();
      const out: NextNode[] = [];
      const seen: Set<number> = new Set<number>();

      // 第一遍：未来最早的未完成节点
      for (let i = 0; i < pend.length; i++) {
        const e: EventNode = pend[i];
        if (e.happenAt < now || seen.has(e.appId)) {
          continue;
        }
        seen.add(e.appId);
        out.push(this.brief(e));
      }
      // 第二遍：只给上面没捞到的记录补一条「最近逾期」
      for (let i = pend.length - 1; i >= 0; i--) {
        const e: EventNode = pend[i];
        if (e.happenAt >= now || seen.has(e.appId)) {
          continue;
        }
        seen.add(e.appId);
        out.push(this.brief(e));
      }
      this.nextNodes = out;
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`reloadNextNodes failed: ${err.message}`);
      this.nextNodes = [];
    }
  }

  private brief(e: EventNode): NextNode {
    const meta: EventTypeMeta = getEventTypeMeta(e.type);
    return {
      appId: e.appId,
      type: e.type,
      label: meta.label,
      color: meta.color,
      when: humanDeadline(e.happenAt),
      countdown: countdownText(e.happenAt),
      days: dayDiff(e.happenAt)
    };
  }

  /* ---- 筛选 ---- */

  /**
   * 当前筛选命中的记录。
   *
   * 「有安排」要查 nextNodes；其余走状态/关键词。
   * 关键词匹配公司、岗位、城市三个字段 —— 用户记得住的就这三样，
   * 连备注一起搜反而容易搜出一堆不相干的。
   */
  private visible(): Application[] {
    const q: string = this.query.trim().toLowerCase();
    const out: Application[] = [];
    for (let i = 0; i < this.apps.length; i++) {
      const a: Application = this.apps[i];
      if (!this.matchFilter(a)) {
        continue;
      }
      if (q.length > 0 && !this.hitKeyword(a, q)) {
        continue;
      }
      out.push(a);
    }
    return out;
  }

  private matchFilter(a: Application): boolean {
    const f: string = this.statusFilter;
    if (f.length === 0) {
      return true;
    }
    if (f === F_ACTIVE) {
      return isActiveStatus(a.status);
    }
    if (f === F_CLOSED) {
      return !isActiveStatus(a.status) && a.status !== AppStatus.WISH;
    }
    if (f === F_NODE) {
      return this.nextOf(a.id) !== undefined;
    }
    return a.status === f;
  }

  /**
   * 这条记录该不该在卡片上显示「下一个节点」。
   *
   * ⚠ 判据只看**有没有未完成的节点**，不看状态。
   *   一开始这里加了「已结束/已放弃就不显示」——想的是"被拒了还提醒你明天面试很蠢"，
   *   但那是错的：**漏掉一个真实面试的代价，远大于多显示一行**。
   *   状态可能标错、也可能标完忘了取消节点；节点自己带 done 标记，
   *   用户在节点页把节点划掉，这行自然就消失了 —— 那才是唯一的真值来源
   *   （桌面卡片与到点提醒也是这么算的，别在这儿另立一套）。
   */
  private hasArrangement(app: Application): boolean {
    return this.nextOf(app.id) !== undefined;
  }

  private hitKeyword(a: Application, q: string): boolean {
    const hay: string = `${a.company} ${a.position} ${a.city}`.toLowerCase();
    return hay.indexOf(q) >= 0;
  }

  private filtering(): boolean {
    return this.query.trim().length > 0 || this.statusFilter.length > 0;
  }

  private clearFilter(): void {
    this.query = '';
    this.statusFilter = '';
  }

  /* ---- 下一个节点 ---- */

  private nextOf(appId: number): NextNode | undefined {
    for (let i = 0; i < this.nextNodes.length; i++) {
      if (this.nextNodes[i].appId === appId) {
        return this.nextNodes[i];
      }
    }
    return undefined;
  }

  /** 卡片上那行节点文字：「面试 · 明天 14:30」，没有节点则返回空串 */
  private nextLine(appId: number): string {
    const n: NextNode | undefined = this.nextOf(appId);
    return n === undefined ? '' : `${n.label} · ${n.when}`;
  }

  private nextColor(appId: number): string {
    const n: NextNode | undefined = this.nextOf(appId);
    return n === undefined ? Palette.TX_3 : n.color;
  }

  /** 倒计时：逾期标红，3 天内标橙，其余灰 —— 一眼扫出「哪几家要来了」 */
  private nextCountdown(appId: number): string {
    const n: NextNode | undefined = this.nextOf(appId);
    if (n === undefined) {
      return '';
    }
    return n.days < 0 ? '已逾期' : `还有 ${n.countdown}`;
  }

  private nextUrgent(appId: number): boolean {
    const n: NextNode | undefined = this.nextOf(appId);
    if (n === undefined) {
      return false;
    }
    return n.days < 0 || n.days <= 3;
  }

  private num(s: string): number {
    const v: number = Number.parseInt(s, 10);
    return Number.isNaN(v) ? 0 : v;
  }

  private resetForm(): void {
    this.company = '';
    this.job = '';
    this.salaryMin = '';
    this.salaryMax = '';
    this.deadline = 0;
    this.status = AppStatus.APPLIED;
    this.showMore = false;
    this.note = '';
    this.dictLive = '';
    this.dictHint = '';
    // ⚠ 这两个必须一起清掉，否则下一次「记一笔」会悄悄变成覆盖上一条记录
    this.editingId = 0;
    this.deadlineEvId = 0;
  }

  /**
   * 把一条已有记录载入表单。
   *
   * ⚠ 截止时间不在投递记录上，而是事件表里的一条 DEADLINE 节点，得一起捞回来 ——
   *   否则表单显示成「设置投递截止时间」（空的），用户以为丢了，
   *   一保存还会顺手把原来那条覆盖掉。
   */
  private async loadForEdit(app: Application): Promise<void> {
    this.editingId = app.id;
    this.company = app.company;
    this.job = app.position;
    this.note = app.note;
    this.city = app.city;
    this.cityIdx = indexOfOpt(CITY_OPTIONS, app.city);
    this.channel = app.channel;
    this.channelIdx = indexOfOpt(CHANNEL_OPTIONS, app.channel);
    this.status = app.status;
    this.salaryMin = app.salaryMin > 0 ? `${app.salaryMin}` : '';
    this.salaryMax = app.salaryMax > 0 ? `${app.salaryMax}` : '';
    // 薪资和截止时间平时折在「更多」里，编辑时必须展开，否则等于没法改
    this.showMore = true;
    this.deadline = 0;
    this.deadlineEvId = 0;
    try {
      const evs: EventNode[] = await EventRepo.listByApp(app.id);
      for (let i = 0; i < evs.length; i++) {
        if (evs[i].type === EventType.DEADLINE && !evs[i].done) {
          this.deadlineEvId = evs[i].id;
          this.deadline = evs[i].happenAt;
          break;
        }
      }
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`loadForEdit 读节点失败: ${err.message}`);
    }
    this.focusForm();
  }

  /** 滚回表单。点「编辑」时视线在列表上，表单多半在屏幕外，不滚等于点了没反应。 */
  private focusForm(): void {
    const sc: Scroller = this.twoPane ? this.formScroller : this.listScroller;
    sc.scrollToIndex(1, true, ScrollAlign.START);
  }

  /**
   * 截止时间的三种同步：新设 / 改时间 / 清空。
   * ⚠ 清空时必须把事件表里那条删掉 —— 否则「地图」页会继续显示一个
   *   用户已经取消掉的截止日，看着有数据，其实是幽灵。
   */
  private async syncDeadline(appId: number, company: string): Promise<void> {
    if (this.deadline > 0) {
      const ev: EventNode = {
        id: this.deadlineEvId,
        appId: appId,
        type: EventType.DEADLINE,
        title: `${company} 投递截止`,
        happenAt: this.deadline,
        done: false,
        note: ''
      };
      if (this.deadlineEvId > 0) {
        await EventRepo.update(ev);
      } else {
        await EventRepo.insert(ev);
      }
    } else if (this.deadlineEvId > 0) {
      await EventRepo.remove(this.deadlineEvId);
    }
  }

  // ────────────────────── 语音速记（备注） ──────────────────────

  /** 正在录（准备中 / 聆听中）—— 按钮显示成"停止"，再点一下就是停 */
  private dictBusy(): boolean {
    return this.dictState === DictState.STARTING || this.dictState === DictState.LISTENING;
  }

  private dictLabel(): string {
    if (this.dictBusy()) {
      return '停止';
    }
    if (this.dictState === DictState.FINISHING) {
      return '出字中';
    }
    return '语音';
  }

  private dictColor(): string {
    if (this.dictBusy()) {
      return Palette.DANGER;
    }
    if (this.dictState === DictState.FINISHING) {
      return Palette.TX_3;
    }
    return Palette.ACCENT;
  }

  /**
   * 点一下麦克风：没在听就开始，在听就停。
   *
   * 识别是**流式**的：说话过程中就会不断回调中间草稿（显示在按钮下方），
   * 用户点停止之后引擎再吐最终结果，那时才并进备注。
   */
  private async toggleDict(): Promise<void> {
    if (this.dictBusy()) {
      await VoiceMemo.stopDictation();
      return;
    }
    if (this.dictState === DictState.FINISHING) {
      // 正在等最终结果。这时再点会清掉 @State，把上一次的字吞了
      return;
    }
    // uiContext() 声明成 common.Context（ArkUI 只保证这么多），
    // 但申请权限必须用 UIAbilityContext —— 按 WidgetRefresher 里同样的方式断言下来
    const host: common.Context | undefined = this.uiContext();
    if (host === undefined) {
      promptAction.showToast({ message: '拿不到页面上下文，稍后再试' });
      return;
    }
    const ctx: common.UIAbilityContext = host as common.UIAbilityContext;
    // 把库里已有的公司名当热词喂进去 —— 通用模型不认识「鼎捷软件」这类名字，
    // 说"投了明源云"很可能识别成"投了名额云"。这是用户自己的数据，不联网。
    const names: string[] = [];
    for (let i = 0; i < this.apps.length; i++) {
      names.push(this.apps[i].company);
    }
    const listener: DictationListener = {
      onState: (st: string, detail: string) => {
        this.dictState = st;
        this.dictHint = detail;
      },
      onText: (text: string, isFinal: boolean) => {
        if (isFinal) {
          this.note = this.appendNote(this.note, text);
          this.dictLive = '';
        } else {
          this.dictLive = text;
        }
      }
    };
    const r: DictStart = await VoiceMemo.startDictation(ctx, VoiceMemo.buildHotwords(names), listener);
    if (!r.ok) {
      promptAction.showToast({ message: r.reason });
    }
  }

  /**
   * 把识别结果并进备注。
   * 已有内容就换行接在后面 —— 用户完全可能先打了两句再说一句，
   * 直接覆盖会把刚打的字吃掉，那是丢数据。
   */
  private appendNote(old: string, add: string): string {
    const a: string = add.trim();
    if (a.length === 0) {
      return old;
    }
    const o: string = old.trim();
    if (o.length === 0) {
      return a;
    }
    return `${o}\n${a}`;
  }

  private async save(): Promise<void> {
    const name: string = this.company.trim();    if (isEmpty(name)) {
      promptAction.showToast({ message: '填个公司名就能记下' });
      return;
    }
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      const isEdit: boolean = this.editingId > 0;

      // 编辑时先把原记录取出来，而不是从空白对象开始 —— 这样 appliedAt（投递时间）
      // 和 jdText 这些「本表单不管」的字段会被原样带过去。改个错别字不该把投递时间改成今天。
      let app: Application = emptyApplication();
      if (isEdit) {
        const found: Application | undefined = await ApplicationRepo.getById(this.editingId);
        if (found === undefined) {
          promptAction.showToast({ message: '这条记录已经不在了' });
          return;
        }
        app = found;
      }

      app.company = name;
      app.position = this.job.trim();
      app.note = this.note.trim();
      app.city = this.city;
      app.channel = this.channel;
      app.status = this.status;
      app.salaryMin = this.num(this.salaryMin);
      app.salaryMax = this.num(this.salaryMax);
      app.updatedAt = Date.now();

      let id: number = this.editingId;
      if (isEdit) {
        await ApplicationRepo.update(app);
      } else {
        app.appliedAt = Date.now();
        id = await ApplicationRepo.insert(app);
      }
      await this.syncDeadline(id, name);

      this.resetForm();
      await this.reload();
      this.onChanged();
      promptAction.showToast({ message: isEdit ? `已更新「${name}」` : `已记下「${name}」` });
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`save failed: ${err.message}`);
      promptAction.showToast({ message: '保存失败，看下日志' });
    } finally {
      this.saving = false;
    }
  }

  private async switchStatus(app: Application, status: string): Promise<void> {
    try {
      await ApplicationRepo.updateStatus(app.id, status);
      await this.reload();
      this.onChanged();
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`switchStatus failed: ${err.message}`);
    }
  }

  private async remove(app: Application): Promise<void> {
    try {
      await ApplicationRepo.remove(app.id);
      // 顺手清掉这条记录的 JD 结论。不清会留下读不到的孤儿键 —— 看不见，
      // 但会一直占着键值表，且如果以后 id 复用还会串到别的记录上。
      await JdAnalyzer.clearResult(app.id);
      await this.reload();
      this.onChanged();
      promptAction.showToast({ message: '已删除' });
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`remove failed: ${err.message}`);
    }
  }

  private confirmDelete(app: Application): void {
    AlertDialog.show({
      title: '删除这条记录？',
      message: `「${app.company}」及其关联的节点、复盘会一起删掉，不可恢复。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: Palette.DANGER,
        action: (): void => {
          this.remove(app);
        }
      }
    });
  }

  /* ==================== JD 岗位匹配：打开 / 分析 / 底牌 ==================== */

  private uiContext(): common.Context | undefined {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    return ctx;
  }

  /** 打开面板：带出这条记录上次粘过的 JD，以及用户技能底牌 */
  private async openJd(app: Application): Promise<void> {
    this.jdForId = app.id;
    this.jdForName = app.position.length > 0 ? `${app.company} · ${app.position}` : app.company;
    this.jdText = app.jdText;
    this.jdHasResult = false;
    this.jdWhy = '';
    this.jdItems = [];
    this.jdFocus = [];
    this.jdPlan = [];
    this.jdEditProfile = false;
    this.jdBusy = false;

    const ctx: common.Context | undefined = this.uiContext();
    if (ctx === undefined) {
      this.jdProfile = JdAnalyzer.defaultProfile();
      return;
    }
    try {
      this.jdProfile = await JdAnalyzer.loadProfile(ctx);
    } catch (e) {
      this.jdProfile = JdAnalyzer.defaultProfile();
    }

    // 把这条记录上次的结论读回来 —— 一次分析一千多个 token，
    // 不该因为"切出去看了一眼地图"就要重跑一遍
    try {
      const cached: JdOutcome | undefined = await JdAnalyzer.loadResult(app.id);
      if (cached !== undefined) {
        this.applyOutcome(cached);
        Log.i(`JD 面板：读回历史结论 ${cached.analysis.items.length} 项`);
      }
    } catch (e) {
      Log.w('JD 面板：历史结论读取失败，按首次分析处理');
    }
  }

  private closeJd(): void {
    this.jdForId = 0;
    this.jdForName = '';
    this.jdHasResult = false;
    this.jdBusy = false;
    this.jdEditProfile = false;
  }

  private async saveJdProfile(): Promise<void> {
    const ctx: common.Context | undefined = this.uiContext();
    if (ctx === undefined) {
      promptAction.showToast({ message: '拿不到应用上下文，重开一次试试' });
      return;
    }
    try {
      await JdAnalyzer.saveProfile(ctx, this.jdProfile);
      this.jdEditProfile = false;
      promptAction.showToast({ message: '技能底牌已保存' });
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`saveJdProfile failed: ${err.message}`);
      promptAction.showToast({ message: '保存失败' });
    }
  }

  private async runJd(): Promise<void> {
    if (this.jdBusy) {
      return;
    }
    if (this.jdText.trim().length < 30) {
      promptAction.showToast({ message: 'JD 太短了，把完整的要求粘进来' });
      return;
    }
    this.jdBusy = true;
    try {
      // 先把 JD 存回记录 —— 这次就算分析失败，下次进来也不用重新粘一遍
      if (this.jdForId > 0) {
        await ApplicationRepo.updateJd(this.jdForId, this.jdText);
      }
      const out: JdOutcome = await JdAnalyzer.analyze(this.jdText, this.jdProfile);
      this.applyOutcome(out);
      // 落库：这份结论用户接下来几天要反复回来看，不能只活在 @State 里
      await JdAnalyzer.saveResult(this.jdForId, out);
      this.reload();
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`runJd failed: ${err.message}`);
      promptAction.showToast({ message: '分析失败，看下日志' });
    } finally {
      this.jdBusy = false;
    }
  }

  /** 把一次分析结果摊平到各个 @State（首次分析与读缓存共用同一条路径） */
  private applyOutcome(out: JdOutcome): void {
    this.jdScore = out.analysis.gapScore;
    this.jdJobTitle = out.analysis.jobTitle;
    this.jdItems = out.analysis.items;
    this.jdFocus = out.analysis.interviewFocus;
    this.jdPlan = out.analysis.prepPlan;
    this.jdEngine = out.engine;
    this.jdFromCloud = out.fromCloud;
    this.jdWhy = out.errorMsg;
    this.jdLatency = out.latencyMs;
    this.jdTokens = out.tokens;
    this.jdHasResult = true;
  }

  /** 匹配度配色：≥75 绿 / ≥50 琥珀 / 其余红。用中国用户的直觉（红=不达标） */
  private scoreColor(): string {
    if (this.jdScore >= 75) {
      return Palette.OK;
    }
    if (this.jdScore >= 50) {
      return Palette.ACCENT;
    }
    return Palette.DANGER;
  }

  private statusColor(s: string): string {
    if (s === '具备') {
      return Palette.OK;
    }
    if (s === '缺失') {
      return Palette.DANGER;
    }
    return Palette.ACCENT;
  }

  /** '#3DD68C' + '22' → '#223DD68C'（ArkUI 是 #AARRGGBB，透明度在前） */
  private tint(color: string, aa: string): string {
    return `#${aa}${color.substring(1)}`;
  }

  /** 「共 N 项 · 待补 M 项」。待补 = 不是「具备」的都算，部分具备也需要补 */
  private jdCountText(): string {
    let miss: number = 0;
    for (let i: number = 0; i < this.jdItems.length; i++) {
      if (this.jdItems[i].myStatus !== '具备') {
        miss++;
      }
    }
    return `共 ${this.jdItems.length} 项 · 待补 ${miss} 项`;
  }

  private menuFor(app: Application): MenuElement[] {
    const out: MenuElement[] = [];
    // 「编辑」放在最前：批量投递之后回头核对时，打错公司名/岗位是高频事，
    // 而原来只能「删了重录」—— 删记录会把关联的节点和复盘一起带走。
    const edit: MenuElement = {
      value: '编辑这条',
      action: (): void => {
        this.loadForEdit(app);
      }
    };
    out.push(edit);

    // JD 匹配分析：放在状态流转之前 —— 它是「看这条投递值不值得花力气」的决策动作，
    // 而改状态是记录动作，用户点开菜单多半先想前者。
    const jd: MenuElement = {
      value: 'JD 匹配分析',
      action: (): void => {
        this.openJd(app);
      }
    };
    out.push(jd);

    for (let i = 0; i < STATUS_LIST.length; i++) {
      const s: StatusMeta = STATUS_LIST[i];
      if (s.key === app.status) {
        continue;
      }
      const item: MenuElement = {
        value: `标记为「${s.label}」`,
        action: (): void => {
          this.switchStatus(app, s.key);
        }
      };
      out.push(item);
    }
    const del: MenuElement = {
      value: '删除这条',
      action: (): void => {
        this.confirmDelete(app);
      }
    };
    out.push(del);
    return out;
  }

  private cityOpts(): SelectOption[] {
    const arr: SelectOption[] = [];
    for (let i = 0; i < CITY_OPTIONS.length; i++) {
      const o: SelectOption = { value: CITY_OPTIONS[i] };
      arr.push(o);
    }
    return arr;
  }

  private channelOpts(): SelectOption[] {
    const arr: SelectOption[] = [];
    for (let i = 0; i < CHANNEL_OPTIONS.length; i++) {
      const o: SelectOption = { value: CHANNEL_OPTIONS[i] };
      arr.push(o);
    }
    return arr;
  }

  private pickDeadline(): void {
    DatePickerDialog.show({
      start: new Date(),
      end: new Date(Date.now() + 200 * 24 * 60 * 60 * 1000),
      selected: this.deadline > 0 ? new Date(this.deadline) : new Date(),
      onDateAccept: (value: Date) => {
        const d: Date = new Date(value.getTime());
        d.setHours(23, 59, 0, 0);
        this.deadline = d.getTime();
      }
    });
  }

  @Builder
  statusChips() {
    // 用 Flex 换行而不是横向滚动 —— 横向滚动会把「Offer」这类关键状态藏在屏幕外
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(STATUS_LIST, (s: StatusMeta) => {
        Text(s.label)
          .fontSize(12.5)
          .fontColor(this.status === s.key ? Palette.BG : Palette.TX_2)
          .fontWeight(this.status === s.key ? FontWeight.Bold : FontWeight.Normal)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.status === s.key ? s.color : Palette.PANEL_2)
          .borderRadius(Metrics.CHIP_RADIUS)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.status = s.key;
          })
      }, (s: StatusMeta) => s.key)
    }
    .width('100%')
  }

  /**
   * 备注 + 语音速记。
   *
   * 备注一直是这条记录上唯一「只能手打」的字段，而投递现场往往是
   * 一只手拿手机、边走边记，打字很别扭。所以配一个语音入口：
   * 说出来就变成字，全程在设备本地转写、录音不上传
   * （只有离线模式，见 VoiceMemo 文件头）。
   */
  @Builder
  noteBox() {
    Column({ space: 7 }) {
      Row() {
        Text('备注')
          .fontSize(12.5)
          .fontColor(Palette.TX_3)
        Blank()
        // 状态说明只在需要时占位，平时不吵
        if (this.dictState !== DictState.IDLE && this.dictHint.length > 0) {
          Text(this.dictHint)
            .fontSize(11)
            .fontColor(this.dictBusy() ? Palette.ACCENT : Palette.TX_3)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .padding({ left: 4, right: 4 })

      Row({ space: 8 }) {
        TextArea({ text: this.note, placeholder: '面试细节 / HR 说了什么 / 要带什么…' })
          .noteField()
          .layoutWeight(1)
          .onChange((v: string) => {
            this.note = v;
          })

        // 语音按钮：录的时候整块变红，"在录"两个字比什么图标都直白
        Column({ space: 2 }) {
          Text(this.dictLabel())
            .fontSize(12.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.dictBusy() ? Palette.BG : this.dictColor())
          Text(this.dictBusy() ? '在录' : '速记')
            .fontSize(9.5)
            .fontColor(this.dictBusy() ? Palette.BG : Palette.TX_3)
        }
        .width(60)
        .height(72)
        .justifyContent(FlexAlign.Center)
        .borderRadius(Metrics.CHIP_RADIUS)
        .backgroundColor(this.dictBusy() ? Palette.DANGER : Palette.PANEL_2)
        .onClick(() => {
          this.toggleDict();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 实时草稿：边听边出字，用户才能确认"它真的在听我说"
      if (this.dictLive.length > 0) {
        Text(this.dictLive)
          .fontSize(12)
          .fontColor(Palette.ACCENT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 4, right: 4 })
      }
    }
    .width('100%')
  }

  @Builder
  inputCard() {
    Column({ space: 10 }) {
      if (this.editingId > 0) {
        Row({ space: 7 }) {
          Text('编辑中')
            .fontSize(11)
            .fontColor(Palette.BG)
            .backgroundColor(Palette.ACCENT)
            .borderRadius(5)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          Text('改完点「保存修改」，投递时间不会变')
            .fontSize(11.5)
            .fontColor(Palette.TX_3)
          Blank()
        }
        .width('100%')
      }

      TextInput({ text: this.company, placeholder: '公司名称（填这个就能存）' })
        .quickField()
        .onChange((v: string) => {
          this.company = v;
        })

      TextInput({ text: this.job, placeholder: '岗位，如 Java 后端开发' })
        .quickField()
        .onChange((v: string) => {
          this.job = v;
        })

      Row({ space: 10 }) {
        Select(this.cityOpts())
          .selected(this.cityIdx)
          .value(this.city)
          .font({ size: 13 })
          .fontColor(Palette.TX)
          .backgroundColor(Palette.PANEL_2)
          .layoutWeight(1)
          .onSelect((index: number, value?: string) => {
            this.cityIdx = index;
            this.city = value !== undefined ? value : CITY_OPTIONS[index];
          })

        Select(this.channelOpts())
          .selected(this.channelIdx)
          .value(this.channel)
          .font({ size: 13 })
          .fontColor(Palette.TX)
          .backgroundColor(Palette.PANEL_2)
          .layoutWeight(1)
          .onSelect((index: number, value?: string) => {
            this.channelIdx = index;
            this.channel = value !== undefined ? value : CHANNEL_OPTIONS[index];
          })
      }
      .width('100%')

      this.statusChips()

      this.noteBox()

      if (this.showMore) {
        Row({ space: 10 }) {
          TextInput({ text: this.salaryMin, placeholder: '最低' })
            .quickField()
            .type(InputType.Number)
            .layoutWeight(1)
            .onChange((v: string) => {
              this.salaryMin = v;
            })

          Text('—').fontSize(14).fontColor(Palette.TX_3)

          TextInput({ text: this.salaryMax, placeholder: '最高' })
            .quickField()
            .type(InputType.Number)
            .layoutWeight(1)
            .onChange((v: string) => {
              this.salaryMax = v;
            })

          // 单位挂在行尾而不是 placeholder 里 —— placeholder 一填值就没了，
          // 看着「20 — 35」不知道是 20k 还是 20 万
          Text('K').fontSize(14).fontColor(Palette.TX_3)
        }
        .width('100%')

        Row() {
          Text(this.deadline > 0 ? `投递截止：${fmtDate(this.deadline)}` : '设置投递截止时间')
            .fontSize(13)
            .fontColor(this.deadline > 0 ? Palette.ACCENT : Palette.TX_3)
          Blank()
          if (this.deadline > 0) {
            Text('清除')
              .fontSize(13)
              .fontColor(Palette.TX_3)
              .padding({ left: 10, right: 4 })
              .onClick(() => {
                this.deadline = 0;
              })
          }
        }
        .width('100%')
        .padding({ left: 4, right: 4, top: 2, bottom: 2 })
        .onClick(() => {
          this.pickDeadline();
        })
      }

      Row({ space: 8 }) {
        Text(this.showMore ? '收起' : '薪资 / 截止时间')
          .fontSize(13)
          .fontColor(Palette.TX_3)
          .padding({ top: 8, bottom: 8, right: 12 })
          .onClick(() => {
            this.showMore = !this.showMore;
          })

        Blank()

        if (this.editingId > 0) {
          Text('取消')
            .fontSize(14)
            .fontColor(Palette.TX_3)
            .padding({ left: 8, right: 4, top: 8, bottom: 8 })
            .onClick(() => {
              this.resetForm();
            })
        }

        Row() {
          Text(this.saving ? '保存中…' : (this.editingId > 0 ? '保存修改' : '记一笔'))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.BG)
        }
        .height(42)
        // 用 minWidth + 自适应内边距，而不是写死宽度 ——
        // 「记一笔」3 个字、「保存修改」4 个字，写死会有一个显得挤
        .constraintSize({ minWidth: 122 })
        .padding({ left: 22, right: 22 })
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Palette.ACCENT)
        .borderRadius(21)
        .onClick(() => {
          this.save();
        })
      }
      .width('100%')
    }
    .padding(14)
    .panel()
    .width('100%')
  }

  /**
   * 列表筛选栏：一行搜索 + 一排快捷筛选。
   *
   * 为什么需要它：演示数据 20 多条，真实用起来一个秋招投 50～100 家，
   * 想找「还在面试中的那几家」得从顶上一直滚到底 —— 那是筛选该干的活。
   */
  @Builder
  filterBar() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.query, placeholder: '搜公司 / 岗位 / 城市' })
          .quickField()
          .height(38)
          .fontSize(13)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.query = v;
          })
        if (this.filtering()) {
          Text('清空')
            .fontSize(12)
            .fontColor(Palette.PRIMARY)
            .padding({ left: 10, right: 6, top: 9, bottom: 9 })
            .onClick(() => {
              this.clearFilter();
            })
        }
      }
      .width('100%')

      Scroll() {
        Row({ space: 6 }) {
          ForEach(FILTER_DEFS, (f: FilterDef) => {
            Text(f.label)
              .fontSize(12)
              .fontColor(this.statusFilter === f.key ? Palette.BG : Palette.TX_2)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(15)
              .backgroundColor(this.statusFilter === f.key ? Palette.PRIMARY : Palette.PANEL_2)
              .onClick(() => {
                // 再点一次同一个 = 取消筛选，省一个「全部」按钮
                this.statusFilter = this.statusFilter === f.key ? '' : f.key;
              })
          }, (f: FilterDef) => `flt-${f.key}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(32)
    }
    .width('100%')
  }

  /** 筛选筛空了 —— 和「一条都没记」是两回事，文案要分开说 */
  @Builder
  emptyByFilter() {
    Column({ space: 10 }) {
      Text('没有符合条件的记录')
        .fontSize(14)
        .fontColor(Palette.TX_2)
      Text(this.query.trim().length > 0
        ? `没找到包含「${this.query.trim()}」的公司 / 岗位 / 城市`
        : '换个筛选条件看看')
        .fontSize(12)
        .fontColor(Palette.TX_3)
        .textAlign(TextAlign.Center)
      Text('清空筛选')
        .fontSize(12.5)
        .fontColor(Palette.PRIMARY)
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .borderRadius(15)
        .backgroundColor(Palette.PANEL_2)
        .onClick(() => {
          this.clearFilter();
        })
    }
    .width('100%')
    .padding({ top: 34, bottom: 34 })
  }

  @Builder
  appRow(app: Application) {
    Column({ space: 8 }) {
      Row() {
        Text(app.company)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TX)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(getStatusMeta(app.status).label)
          .fontSize(11)
          .fontColor(getStatusMeta(app.status).color)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .borderWidth(1)
          .borderColor(getStatusMeta(app.status).color)
      }
      .width('100%')

      if (!isEmpty(app.position)) {
        Text(app.position)
          .fontSize(13)
          .fontColor(Palette.TX_2)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Row({ space: 12 }) {
        Text(app.city).fontSize(11.5).fontColor(Palette.TX_3)
        Text(app.channel).fontSize(11.5).fontColor(Palette.TX_3)
        Text(fmtSalary(app.salaryMin, app.salaryMax)).fontSize(11.5).fontColor(Palette.TX_3)
        Blank()
        Text(fmtDate(app.appliedAt)).fontSize(11.5).fontColor(Palette.TX_3)
      }
      .width('100%')

      // 备注：卡片上只给一行，多了去编辑里看。
      // 语音速记写进来的内容就是靠这一行被看见的，不然录完等于没录。
      if (app.note.length > 0) {
        Text(app.note)
          .fontSize(11.5)
          .fontColor(Palette.TX_2)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      // 下一个节点：这家「接下来什么时候有事」。没有节点的记录不占这一行。
      if (this.hasArrangement(app)) {
        Row({ space: 6 }) {
          Text(this.nextLine(app.id))
            .fontSize(11.5)
            .fontColor(this.nextColor(app.id))
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .borderRadius(5)
            .backgroundColor(this.tint(this.nextColor(app.id), '22'))
          Blank()
          Text(this.nextCountdown(app.id))
            .fontSize(11.5)
            .fontColor(this.nextUrgent(app.id) ? Palette.ACCENT : Palette.TX_3)
        }
        .width('100%')
      }
    }
    .padding(14)
    .panel()
    .width('100%')
    .bindMenu(this.menuFor(app))
  }

  /* ==================== JD 面板 UI ==================== */

  @Builder
  jdPanel() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(14)
          .fontColor(Palette.PRIMARY)
          .padding({ top: 10, bottom: 10, right: 12 })
          .onClick(() => {
            this.closeJd();
          })
        Blank()
        Text('岗位匹配')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Palette.TX)
        Blank()
        // 占位：让标题真正居中（左右等宽）
        Text('').width(56)
      }
      .width('100%')

      Text(this.jdForName)
        .fontSize(12)
        .fontColor(Palette.TX_3)
        .width('100%')
        .padding({ bottom: 8 })

      if (this.twoPane) {
        // 宽屏：左输入右结果 —— 改 JD 时结果不会跳走，方便反复微调措辞
        Row({ space: Metrics.GAP }) {
          Scroll() {
            Column({ space: 10 }) {
              this.jdInputCard()
              this.jdProfileCard()
            }
            .width('100%')
          }
          .layoutWeight(1)
          .height('100%')
          .scrollBar(BarState.Off)

          Scroll() {
            Column({ space: 10 }) {
              this.jdResultBlock()
            }
            .width('100%')
          }
          .layoutWeight(1)
          .height('100%')
          .scrollBar(BarState.Off)
        }
        .layoutWeight(1)
        .width('100%')
        .alignItems(VerticalAlign.Top)
      } else {
        Scroll() {
          Column({ space: 10 }) {
            this.jdInputCard()
            this.jdResultBlock()
            this.jdProfileCard()
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: Metrics.PAGE_PAD, right: Metrics.PAGE_PAD })
    .backgroundColor(Palette.BG)
  }

  @Builder
  jdInputCard() {
    Column({ space: 10 }) {
      Row() {
        Text('JD 原文')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TX)
        Blank()
        Text(`${this.jdText.length} 字`)
          .fontSize(11)
          .fontColor(Palette.TX_3)
      }
      .width('100%')

      TextArea({
        text: this.jdText,
        placeholder: '把招聘要求整段粘进来。本地引擎只认关键词，云端模型会读语义 —— 给得越完整，结论越准。'
      })
        .placeholderColor(Palette.TX_3)
        .fontSize(13)
        .fontColor(Palette.TX)
        .backgroundColor(Palette.PANEL_2)
        .borderRadius(Metrics.CHIP_RADIUS)
        .height(150)
        .width('100%')
        .onChange((v: string) => {
          this.jdText = v;
        })

      Row() {
        Text(this.jdItems.length > 0 ? `已分析 ${this.jdItems.length} 项` : '')
          .fontSize(11)
          .fontColor(Palette.TX_3)
        Blank()
        Row() {
          Text(this.jdBusy ? '分析中…' : (this.jdHasResult ? '重新分析' : '开始分析'))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.BG)
        }
        .height(42)
        .width(126)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.jdBusy ? Palette.TX_3 : Palette.ACCENT)
        .borderRadius(21)
        .onClick(() => {
          this.runJd();
        })
      }
      .width('100%')
    }
    .panel()
    .width('100%')
    .padding(14)
  }

  @Builder
  jdResultBlock() {
    if (!this.jdHasResult) {
      Column({ space: 8 }) {
        Text('还没有分析结果')
          .fontSize(14)
          .fontColor(Palette.TX_2)
        Text('粘上 JD 点「开始分析」，这里会列出\n你缺哪些技能、可能被追问什么、先补哪一块')
          .fontSize(12)
          .fontColor(Palette.TX_3)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding({ top: 36, bottom: 36 })
      .panel()
    } else {
      Column({ space: 10 }) {
        this.jdScoreCard()
        if (this.jdItems.length > 0) {
          this.jdItemsCard()
        }
        if (this.jdFocus.length > 0) {
          this.jdFocusCard()
        }
        if (this.jdPlan.length > 0) {
          this.jdPlanCard()
        }
      }
      .width('100%')
    }
  }

  @Builder
  jdScoreCard() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 2 }) {
          Text('岗位匹配度')
            .fontSize(12)
            .fontColor(Palette.TX_3)
          Row({ space: 4 }) {
            Text(`${this.jdScore}`)
              .fontSize(34)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.scoreColor())
            Text('/100')
              .fontSize(13)
              .fontColor(Palette.TX_3)
              .padding({ bottom: 5 })
          }
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        if (this.jdJobTitle.length > 0) {
          Text(this.jdJobTitle)
            .fontSize(12)
            .fontColor(Palette.TX_2)
            .textAlign(TextAlign.End)
            .layoutWeight(1)
        }
      }
      .width('100%')

      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(8).backgroundColor(Palette.PANEL_2).borderRadius(4)
        Row().width(`${this.jdScore}%`).height(8).backgroundColor(this.scoreColor()).borderRadius(4)
      }
      .width('100%')
      .height(8)

      // 来源标注：这个产品的一条原则 —— 结论是谁给的，必须写在旁边
      Row({ space: 6 }) {
        Text(this.jdFromCloud ? '云端' : '本地')
          .fontSize(10)
          .fontColor(this.jdFromCloud ? Palette.PRIMARY : Palette.PURPLE)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
          .backgroundColor(Palette.PANEL_2)
        Text(this.jdFromCloud
          ? `${this.jdEngine} · ${(this.jdLatency / 1000).toFixed(1)}s · ${this.jdTokens} tokens`
          : `${this.jdEngine} · 只做关键词比对，不读语义`)
          .fontSize(10.5)
          .fontColor(Palette.TX_3)
          .layoutWeight(1)
      }
      .width('100%')

      if (this.jdWhy.length > 0) {
        Text(`降级原因：${this.jdWhy}`)
          .fontSize(10.5)
          .fontColor(Palette.ACCENT)
          .width('100%')
      }
    }
    .panel()
    .width('100%')
    .padding(14)
  }

  @Builder
  jdItemsCard() {
    Column({ space: 8 }) {
      Row() {
        Text('技能差距')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TX)
        Blank()
        Text(this.jdCountText())
          .fontSize(11)
          .fontColor(Palette.TX_3)
      }
      .width('100%')

      ForEach(this.jdItems, (it: JdSkillItem, idx: number) => {
        Row({ space: 8 }) {
          Column({ space: 3 }) {
            Row({ space: 6 }) {
              Text(it.skill)
                .fontSize(13)
                .fontColor(Palette.TX)
              Text(it.level)
                .fontSize(9.5)
                .fontColor(Palette.TX_3)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .borderRadius(4)
                .backgroundColor(Palette.PANEL_2)
            }
            if (it.note.length > 0) {
              Text(it.note)
                .fontSize(11)
                .fontColor(Palette.TX_3)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(it.myStatus)
            .fontSize(11)
            .fontColor(this.statusColor(it.myStatus))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(6)
            .backgroundColor(this.tint(this.statusColor(it.myStatus), '22'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }, (it: JdSkillItem, idx: number) => `jd-${idx}-${it.skill}-${it.myStatus}`)
    }
    .panel()
    .width('100%')
    .padding(14)
  }

  @Builder
  jdFocusCard() {
    Column({ space: 8 }) {
      Text('可能被追问')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.TX)
        .width('100%')
      ForEach(this.jdFocus, (s: string, i: number) => {
        Row({ space: 8 }) {
          Text(`${i + 1}`)
            .fontSize(11)
            .fontColor(Palette.PRIMARY)
            .width(18)
            .height(18)
            .textAlign(TextAlign.Center)
            .borderRadius(9)
            .backgroundColor(Palette.PANEL_2)
          Text(s)
            .fontSize(12.5)
            .fontColor(Palette.TX_2)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (s: string, i: number) => `jf-${i}-${s}`)
    }
    .panel()
    .width('100%')
    .padding(14)
  }

  @Builder
  jdPlanCard() {
    Column({ space: 8 }) {
      Text('先补这几块')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Palette.TX)
        .width('100%')
      ForEach(this.jdPlan, (s: string, i: number) => {
        Row({ space: 8 }) {
          Text(`${i + 1}`)
            .fontSize(11)
            .fontColor(Palette.OK)
            .width(18)
            .height(18)
            .textAlign(TextAlign.Center)
            .borderRadius(9)
            .backgroundColor(Palette.PANEL_2)
          Text(s)
            .fontSize(12.5)
            .fontColor(Palette.TX_2)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (s: string, i: number) => `jp-${i}-${s}`)
    }
    .panel()
    .width('100%')
    .padding(14)
  }

  @Builder
  jdProfileCard() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 2 }) {
          Text('我的技能底牌')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.TX)
          Text('模型据此判断「具备 / 缺失」。底牌里没写的，一律按缺失算')
            .fontSize(11)
            .fontColor(Palette.TX_3)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.jdEditProfile ? '收起' : '编辑')
          .fontSize(12)
          .fontColor(Palette.PRIMARY)
          .padding({ left: 10, top: 6, bottom: 6 })
          .onClick(() => {
            this.jdEditProfile = !this.jdEditProfile;
          })
      }
      .width('100%')

      if (this.jdEditProfile) {
        TextArea({ text: this.jdProfile, placeholder: '写清楚：会什么、做过什么项目、哪一块最弱' })
          .placeholderColor(Palette.TX_3)
          .fontSize(12.5)
          .fontColor(Palette.TX)
          .backgroundColor(Palette.PANEL_2)
          .borderRadius(Metrics.CHIP_RADIUS)
          .height(150)
          .width('100%')
          .onChange((v: string) => {
            this.jdProfile = v;
          })
        Row() {
          Blank()
          Row() {
            Text('保存底牌')
              .fontSize(13)
              .fontColor(Palette.BG)
          }
          .height(34)
          .width(96)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Palette.PRIMARY)
          .borderRadius(17)
          .onClick(() => {
            this.saveJdProfile();
          })
        }
        .width('100%')
      } else {
        Text(this.jdProfile)
          .fontSize(12)
          .fontColor(Palette.TX_2)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .panel()
    .width('100%')
    .padding(14)
  }

  build() {
    if (this.jdForId > 0) {
      // JD 面板是覆盖式的：它要占满整个内容区，留在 Tab 里会变成一列窄条
      this.jdPanel()
    } else if (this.twoPane) {
      // ── 宽屏双栏：左边填、右边看。录一条立刻能在右边看到，不用滚回去确认
      Row({ space: Metrics.GAP }) {
        List({ space: 10, scroller: this.formScroller }) {
          ListItem() {
            Row() {
              Text('投递快记')
                .fontSize(21)
                .fontWeight(FontWeight.Bold)
                .fontColor(Palette.TX)
              Blank()
              Text('左边填 · 右边立刻出现')
                .fontSize(11.5)
                .fontColor(Palette.TX_3)
            }
            .width('100%')
            .padding({ left: 2, right: 2, top: 8, bottom: 2 })
          }

          ListItem() {
            this.inputCard()
          }

          ListItem() {
            Row().height(20)
          }
        }
        .layoutWeight(1)
        .height('100%')
        .scrollBar(BarState.Off)

        List({ space: 10 }) {
          ListItem() {
            Row() {
              Text('全部记录')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(Palette.TX)
              Blank()
              Text(`${this.visible().length} / ${this.apps.length} 条`)
                .fontSize(11.5)
                .fontColor(Palette.TX_3)
            }
            .width('100%')
            .padding({ left: 2, top: 8, bottom: 2 })
          }

          ListItem() {
            this.filterBar()
          }

          if (this.apps.length === 0) {
            ListItem() {
              Column({ space: 8 }) {
                Text('还没有记录').fontSize(14).fontColor(Palette.TX_2)
                Text('填个公司名，点「记一笔」就开始积累你的秋招数据了')
                  .fontSize(12)
                  .fontColor(Palette.TX_3)
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              .padding({ top: 40, bottom: 40 })
            }
          } else if (this.visible().length === 0) {
            ListItem() { this.emptyByFilter() }
          } else {
            ForEach(this.visible(), (app: Application) => {
              ListItem() {
                this.appRow(app)
              }
            }, (app: Application) => `${app.id}-${app.status}-${app.updatedAt}`)
          }

          ListItem() {
            Row().height(20)
          }
        }
        .layoutWeight(1)
        .height('100%')
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .padding({ left: Metrics.PAGE_PAD, right: Metrics.PAGE_PAD })
      .backgroundColor(Palette.BG)
    } else {
      List({ space: 10, scroller: this.listScroller }) {
      ListItem() {
        Row() {
          Text('投递快记')
            .fontSize(21)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TX)
          Blank()
          Text(this.filtering()
            ? `筛出 ${this.visible().length} / ${this.apps.length} 条`
            : `${this.apps.length} 条`)
            .fontSize(13)
            .fontColor(Palette.TX_3)
        }
        .width('100%')
        .padding({ left: 2, right: 2, top: 8, bottom: 2 })
      }

      ListItem() {
        this.inputCard()
      }

      if (this.apps.length === 0) {
        ListItem() {
          Column({ space: 8 }) {
            Text('还没有记录').fontSize(14).fontColor(Palette.TX_2)
            Text('填个公司名，点「记一笔」就开始积累你的秋招数据了')
              .fontSize(12)
              .fontColor(Palette.TX_3)
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding({ top: 40, bottom: 40 })
        }
      } else {
        ListItem() {
          Text('全部记录')
            .fontSize(12)
            .fontColor(Palette.TX_3)
            .width('100%')
            .padding({ left: 2, top: 10, bottom: 2 })
        }
        ListItem() {
          this.filterBar()
        }
        if (this.visible().length === 0) {
          ListItem() { this.emptyByFilter() }
        } else {
          ForEach(this.visible(), (app: Application) => {
            ListItem() {
              this.appRow(app)
            }
          }, (app: Application) => `${app.id}-${app.status}-${app.updatedAt}`)
        }
      }

      ListItem() {
        Row().height(20)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: Metrics.PAGE_PAD, right: Metrics.PAGE_PAD })
    .scrollBar(BarState.Off)
    .backgroundColor(Palette.BG)
    }
  }
}
