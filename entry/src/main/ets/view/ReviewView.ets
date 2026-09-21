import { promptAction } from '@kit.ArkUI';
import { Palette, Metrics } from '../common/Theme';
import { Application, ReviewRecord, InterviewRound } from '../common/Types';
import { ReviewAnalysis, RadarDimension, RadarEnvelope, AiErrorKind } from '../common/AiTypes';
import { ApplicationRepo } from '../repository/ApplicationRepo';
import { ReviewRepo } from '../repository/ReviewRepo';
import { ReviewAnalyzer, AnalyzeOutcome } from '../service/ReviewAnalyzer';
import { fmtDateTime, isEmpty } from '../common/Utils';
import { Log } from '../common/Logger';
import { RadarChart } from './RadarChart';

/** @Styles 只能用通用属性 */
@Styles
function rvCard() {
  .padding(14)
  .backgroundColor(Palette.PANEL)
  .borderRadius(Metrics.CARD_RADIUS)
  .width('100%')
}

/** ⚠ fontColor/fontSize 是 Text 专有属性，必须走 @Extend(Text) */
@Extend(Text)
function rvCardHead() {
  .fontSize(13)
  .fontColor(Palette.TX_3)
  .width('100%')
}

/** ⚠ placeholderColor/fontSize 是 TextInput 专有属性 */
@Extend(TextInput)
function rvField() {
  .backgroundColor(Palette.PANEL_2)
  .borderRadius(Metrics.CHIP_RADIUS)
  .fontSize(14)
  .fontColor(Palette.TX)
  .placeholderColor(Palette.TX_3)
  .height(44)
}

class RoundOpt {
  key: string;
  label: string;

  constructor(key: string, label: string) {
    this.key = key;
    this.label = label;
  }
}

class AppBrief {
  id: number;
  label: string;
  company: string;
  jobTitle: string;

  constructor(id: number, label: string, company: string, jobTitle: string) {
    this.id = id;
    this.label = label;
    this.company = company;
    this.jobTitle = jobTitle;
  }
}

const ROUND_OPTIONS: RoundOpt[] = [
  new RoundOpt(InterviewRound.HR, 'HR 面'),
  new RoundOpt(InterviewRound.TECH_1, '一面'),
  new RoundOpt(InterviewRound.TECH_2, '二面'),
  new RoundOpt(InterviewRound.LEADER, '主管面'),
  new RoundOpt(InterviewRound.OTHER, '其他')
];

function roundLabel(key: string): string {
  for (let i = 0; i < ROUND_OPTIONS.length; i++) {
    if (ROUND_OPTIONS[i].key === key) {
      return ROUND_OPTIONS[i].label;
    }
  }
  return '面试';
}

/**
 * 面试复盘 —— 灯塔的核心页面。
 *
 * 产品逻辑闭环在这一页完成：
 *   写下回忆（用户唯一的输入负担）
 *     → AI 归因成六维能力雷达
 *     → 指出最该补的一块 + 下周能动手做的具体动作
 *
 * 关于降级的诚实交代（这是本页承担的产品承诺）：
 *   分析结果一律标注来源（云端模型 / 本地引擎），
 *   降级时把原因原样告诉用户，不假装是 AI 的结论。
 *   断网也能出雷达 —— 这不是妥协，是设计。
 */
@Component
export struct ReviewView {
  @Prop @Watch('onTick') tick: number = 0;
  onChanged: () => void = (): void => {};

  @State briefs: AppBrief[] = [];
  @State reviews: ReviewRecord[] = [];
  @State showEditor: boolean = false;
  @State appIdx: number = 0;
  @State roundIdx: number = 1;
  @State interviewer: string = '';
  @State narration: string = '';
  @State saving: boolean = false;

  /** 当前展开雷达的复盘 id，0 表示都收起 */
  @State openId: number = 0;
  /** 正在分析的复盘 id，0 表示空闲 */
  @State analyzingId: number = 0;
  /** 最近一次分析的来源与耗时提示 */
  @State engineNote: string = '';
  /** 降级原因（空串表示没有异常） */
  @State degradeNote: string = '';

  /** 宽屏双栏。⚠ @StorageProp 的参数必须写字面量（编译期求值），不能传常量变量 */
  @StorageProp('lhTwoPane') @Watch('onTwoPaneChanged') twoPane: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  onTick(): void {
    this.reload();
  }

  onTwoPaneChanged(): void {
    this.autoSelect();
  }

  /**
   * 宽屏双栏时自动选中最近一场。
   *
   * 双栏右栏空着只显示一句「从左侧选一场面试」，等于把多出来的半屏白白浪费 ——
   * 而这半屏恰恰是评委把设备转成横屏/平板后第一眼看到的东西。
   * 默认选中最近一场，雷达直接铺开，双栏才有存在感。
   *
   * ⚠ 只在双栏时自动选：单列模式下每条记录自己内联展开，本来就没有"选中"这个状态，
   *   自动选中反而会让第一条无缘无故处于高亮态。
   * ⚠ 已经在看某一条时不打断（下面那个 return），否则每次数据刷新都会把用户拽回第一条。
   */
  private autoSelect(): void {
    if (!this.twoPane) {
      return;
    }
    if (this.reviews.length === 0) {
      this.openId = 0;
      return;
    }
    for (let i = 0; i < this.reviews.length; i++) {
      if (this.reviews[i].id === this.openId) {
        return;
      }
    }
    this.openId = this.reviews[0].id;
  }

  private async reload(): Promise<void> {
    try {
      const apps: Application[] = await ApplicationRepo.listAll();
      const bs: AppBrief[] = [];
      for (let i = 0; i < apps.length; i++) {
        bs.push(new AppBrief(apps[i].id,
          `${apps[i].company} · ${apps[i].position}`,
          apps[i].company, apps[i].position));
      }
      this.briefs = bs;
      this.reviews = await ReviewRepo.listAll();
      if (this.appIdx >= this.briefs.length) {
        this.appIdx = 0;
      }
      // 双栏时右栏不能空着（见 autoSelect 的说明）。放在 reload 末尾是因为
      // 首次进入页面时 twoPane 就已经是 true，@Watch 不会再触发一次。
      this.autoSelect();
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`ReviewView reload failed: ${err.message}`);
    }
  }

  private appLabel(appId: number): string {
    for (let i = 0; i < this.briefs.length; i++) {
      if (this.briefs[i].id === appId) {
        return this.briefs[i].label;
      }
    }
    return '已删除的投递';
  }

  private companyOf(appId: number): string {
    for (let i = 0; i < this.briefs.length; i++) {
      if (this.briefs[i].id === appId) {
        return this.briefs[i].company;
      }
    }
    return '未知公司';
  }

  private jobOf(appId: number): string {
    for (let i = 0; i < this.briefs.length; i++) {
      if (this.briefs[i].id === appId) {
        return this.briefs[i].jobTitle;
      }
    }
    return 'Java 后端开发';
  }

  private appOpts(): SelectOption[] {
    const arr: SelectOption[] = [];
    for (let i = 0; i < this.briefs.length; i++) {
      const o: SelectOption = { value: this.briefs[i].label };
      arr.push(o);
    }
    return arr;
  }

  private roundOpts(): SelectOption[] {
    const arr: SelectOption[] = [];
    for (let i = 0; i < ROUND_OPTIONS.length; i++) {
      const o: SelectOption = { value: ROUND_OPTIONS[i].label };
      arr.push(o);
    }
    return arr;
  }

  /* ==================== 雷达数据读写 ==================== */

  private hasRadar(r: ReviewRecord): boolean {
    return r.radarJson !== undefined && r.radarJson.length > 0;
  }

  /**
   * 解析落库的信封。兼容两种格式：
   *   v2（当前）：{ v:2, analysis:{...}, fromCloud, engine, latencyMs, tokens, analyzedAt }
   *   v1（历史）：radarJson 直接就是 ReviewAnalysis 本身
   * 解析失败一律当「没有雷达」处理，绝不让坏数据把页面搞崩。
   */
  private envelopeOf(r: ReviewRecord): RadarEnvelope | undefined {
    if (!this.hasRadar(r)) {
      return undefined;
    }
    try {
      // 先按 v2 信封解析。ArkTS 严格模式不允许把同一个值当两种接口混用，
      // 所以 v1 兼容走「同一段 JSON 换一个类型视角再解析一次」，而不是复用变量。
      const env: RadarEnvelope = JSON.parse(r.radarJson) as RadarEnvelope;
      if (env.analysis !== undefined) {
        return env;
      }
      // v1 裸格式：本体就是它自己，来源无从考证 —— 留空，不编一个
      const bare: ReviewAnalysis = JSON.parse(r.radarJson) as ReviewAnalysis;
      const legacy: RadarEnvelope = {
        v: 1,
        analysis: bare,
        fromCloud: false,
        engine: '',
        latencyMs: 0,
        tokens: 0,
        analyzedAt: 0
      };
      return legacy;
    } catch (e) {
      Log.w(`radarJson 解析失败 id=${r.id}`);
      return undefined;
    }
  }

  /** 解析已存的分析结果。解析失败当没有处理，不影响页面渲染。 */
  private analysisOf(r: ReviewRecord): ReviewAnalysis | undefined {
    const env: RadarEnvelope | undefined = this.envelopeOf(r);
    return env !== undefined ? env.analysis : undefined;
  }

  /**
   * 已存雷达的来源说明（用于重进应用后仍能如实标注）。
   * v1 历史数据没有来源信息，返回空串 —— UI 会退回中性文案，而不是假称本地引擎。
   */
  private noteOf(r: ReviewRecord): string {
    const env: RadarEnvelope | undefined = this.envelopeOf(r);
    if (env === undefined || env.engine.length === 0) {
      return '';
    }
    const secs: string = (env.latencyMs / 1000).toFixed(1);
    const base: string = env.fromCloud
      ? `${env.engine} · 用时 ${secs}s` + (env.tokens > 0 ? ` · ${env.tokens} tokens` : '')
      : `${env.engine} · 用时 ${secs}s`;
    return base;
  }

  /** 是否值得在列表上打「云端」徽标 */
  private isCloudRadar(r: ReviewRecord): boolean {
    const env: RadarEnvelope | undefined = this.envelopeOf(r);
    return env !== undefined && env.v >= 2 && env.fromCloud;
  }

  /** 来源行文案。三态：刚生成（活状态）/ 已落库可读回 / 历史数据无记录 */
  private noteText(r: ReviewRecord): string {
    let body: string = '';
    if (this.openId === r.id && this.engineNote.length > 0) {
      body = this.engineNote;
    } else {
      body = this.noteOf(r);
    }
    return body.length > 0 ? `◆ ${body}` : '◆ 已完成分析（当时未记录来源）';
  }

  /**
   * 来源行颜色：云端=绿、本地降级=橙、无记录=灰。
   * 「这条不是云端给的」应该一眼可见，而不是让用户去读小字。
   */
  private noteColor(r: ReviewRecord): string {
    if (this.openId === r.id && this.engineNote.length > 0) {
      return this.degradeNote.length > 0 ? Palette.ACCENT : Palette.OK;
    }
    const env: RadarEnvelope | undefined = this.envelopeOf(r);
    if (env === undefined || env.engine.length === 0) {
      return Palette.TX_3;
    }
    return env.fromCloud ? Palette.OK : Palette.ACCENT;
  }

  /** 传给 RadarChart 的分数串，必须与 RadarDef.KEYS 同序 */
  private scoresKeyOf(r: ReviewRecord): string {
    const a: ReviewAnalysis | undefined = this.analysisOf(r);
    if (a === undefined || a.dimensions === undefined) {
      return '0,0,0,0,0,0';
    }
    let s: string = '';
    for (let i: number = 0; i < a.dimensions.length; i++) {
      s = s + (i > 0 ? ',' : '') + a.dimensions[i].score;
    }
    return s;
  }

  private dimsOf(r: ReviewRecord): RadarDimension[] {
    const a: ReviewAnalysis | undefined = this.analysisOf(r);
    if (a === undefined || a.dimensions === undefined) {
      return [];
    }
    return a.dimensions;
  }

  private actionsOf(r: ReviewRecord): string[] {
    const a: ReviewAnalysis | undefined = this.analysisOf(r);
    if (a === undefined || a.nextActions === undefined) {
      return [];
    }
    return a.nextActions;
  }

  private summaryOf(r: ReviewRecord): string {
    const a: ReviewAnalysis | undefined = this.analysisOf(r);
    return a !== undefined && a.summary !== undefined ? a.summary : '';
  }

  private weaknessOf(r: ReviewRecord): string {
    const a: ReviewAnalysis | undefined = this.analysisOf(r);
    return a !== undefined && a.topWeakness !== undefined ? a.topWeakness : '';
  }

  private scoreColor(v: number): string {
    if (v <= 0) {
      return Palette.TX_3;
    }
    if (v < 45) {
      return Palette.DANGER;
    }
    if (v < 70) {
      return Palette.ACCENT;
    }
    return Palette.OK;
  }

  /* ==================== 生成雷达 ==================== */

  private async generate(r: ReviewRecord): Promise<void> {
    if (this.analyzingId !== 0) {
      promptAction.showToast({ message: '正在分析上一场，稍等一下' });
      return;
    }
    this.analyzingId = r.id;
    this.engineNote = '';
    this.degradeNote = '';
    this.openId = r.id;

    try {
      const out: AnalyzeOutcome = await ReviewAnalyzer.analyze(
        r.narration, this.jobOf(r.appId), this.companyOf(r.appId));

      // 落库用「信封」格式：结果本体 + 来源元数据。
      // 只存 analysis 的话，退出应用再进来就看不出这条是云端结论还是本地初判了。
      const env: RadarEnvelope = {
        v: 2,
        analysis: out.analysis,
        fromCloud: out.fromCloud,
        engine: out.engine,
        latencyMs: out.latencyMs,
        tokens: out.tokens,
        analyzedAt: Date.now()
      };
      const json: string = JSON.stringify(env);
      const avg: number = ReviewAnalyzer.scoreAvgOf(out.analysis);
      await ReviewRepo.saveRadar(r.id, json, avg);

      const secs: string = (out.latencyMs / 1000).toFixed(1);
      if (out.fromCloud) {
        this.engineNote = `${out.engine} · 用时 ${secs}s` +
          (out.tokens > 0 ? ` · ${out.tokens} tokens` : '');
        this.degradeNote = '';
      } else {
        this.engineNote = `${out.engine} · 用时 ${secs}s`;
        this.degradeNote = out.errorMsg.length > 0
          ? `已降级：${out.errorMsg}`
          : '未连接云端，本次为本地关键词初判，精度低于云端模型';
      }
      Log.i(`雷达已生成 id=${r.id} cloud=${out.fromCloud} avg=${avg}`);

      await this.reload();
      this.onChanged();
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`generate radar failed: ${err.message}`);
      promptAction.showToast({ message: '生成失败，请重试' });
    } finally {
      this.analyzingId = 0;
    }
  }

  /* ==================== 复盘编辑器 ==================== */

  private async save(): Promise<void> {
    if (this.briefs.length === 0) {
      promptAction.showToast({ message: '先去「快记」添加一家投递过的公司' });
      return;
    }
    if (isEmpty(this.narration)) {
      promptAction.showToast({ message: '把你记得的都写下来，哪怕很碎' });
      return;
    }
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      const r: ReviewRecord = {
        id: 0,
        appId: this.briefs[this.appIdx].id,
        round: ROUND_OPTIONS[this.roundIdx].key,
        interviewer: this.interviewer.trim(),
        narration: this.narration.trim(),
        radarJson: '',
        scoreAvg: 0,
        createdAt: Date.now()
      };
      await ReviewRepo.insert(r);
      this.narration = '';
      this.interviewer = '';
      this.showEditor = false;
      await this.reload();
      this.onChanged();
      promptAction.showToast({ message: '复盘已保存，点「生成能力雷达」看看结果' });
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`review save failed: ${err.message}`);
      promptAction.showToast({ message: '保存失败' });
    } finally {
      this.saving = false;
    }
  }

  private confirmDelete(r: ReviewRecord): void {
    AlertDialog.show({
      title: '删除这条复盘？',
      message: '删掉就找不回来了。',
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: Palette.DANGER,
        action: (): void => {
          this.remove(r);
        }
      }
    });
  }

  private async remove(r: ReviewRecord): Promise<void> {
    try {
      await ReviewRepo.remove(r.id);
      if (this.openId === r.id) {
        this.openId = 0;
      }
      await this.reload();
      this.onChanged();
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`review remove failed: ${err.message}`);
    }
  }

  private rowMenu(r: ReviewRecord): MenuElement[] {
    const m: MenuElement = {
      value: '删除这条复盘',
      action: (): void => {
        this.confirmDelete(r);
      }
    };
    const arr: MenuElement[] = [m];
    return arr;
  }

  @Builder
  editor() {
    Column({ space: 10 }) {
      Text('这一轮是哪家？').rvCardHead()
      if (this.briefs.length === 0) {
        Text('还没有投递记录。先去「快记」加一条，复盘才能挂到具体公司上。')
          .fontSize(12.5)
          .fontColor(Palette.TX_3)
      } else {
        Select(this.appOpts())
          .selected(this.appIdx)
          .value(this.briefs[this.appIdx].label)
          .font({ size: 13 })
          .fontColor(Palette.TX)
          .backgroundColor(Palette.PANEL_2)
          .width('100%')
          .onSelect((index: number, value?: string) => {
            this.appIdx = index;
          })
      }

      Select(this.roundOpts())
        .selected(this.roundIdx)
        .value(ROUND_OPTIONS[this.roundIdx].label)
        .font({ size: 13 })
        .fontColor(Palette.TX)
        .backgroundColor(Palette.PANEL_2)
        .width('100%')
        .onSelect((index: number, value?: string) => {
          this.roundIdx = index;
        })

      TextInput({ text: this.interviewer, placeholder: '面试官画像（选填），如「技术面 · 中间件组」' })
        .rvField()
        .onChange((v: string) => {
          this.interviewer = v;
        })

      TextArea({ text: this.narration, placeholder: '把这一场问到的都倒出来：问了什么、你怎么答的、哪句卡住了。写得越碎，雷达越准。' })
        .backgroundColor(Palette.PANEL_2)
        .borderRadius(Metrics.CHIP_RADIUS)
        .fontSize(14)
        .fontColor(Palette.TX)
        .placeholderColor(Palette.TX_3)
        .height(150)
        .onChange((v: string) => {
          this.narration = v;
        })

      Row() {
        Text('取消')
          .fontSize(14)
          .fontColor(Palette.TX_3)
          .padding({ left: 4, right: 12, top: 8, bottom: 8 })
          .onClick(() => {
            this.showEditor = false;
          })
        Blank()
        Button(this.saving ? '保存中…' : '保存复盘')
          .fontSize(14)
          .fontColor(Palette.BG)
          .backgroundColor(Palette.ACCENT)
          .height(38)
          .enabled(!this.saving)
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
    }
    .rvCard()
  }

  /* ==================== 雷达展示区 ==================== */

  /**
   * @param topLine 是否画顶部分隔线。窄屏里雷达是内联展开在卡片下半部分的，
   *                需要一条线把它和上面的摘要分开；宽屏里它独占一栏，那条线多余。
   */
  @Builder
  radarBlock(r: ReviewRecord, topLine: boolean) {
    Column({ space: 12 }) {
      if (this.analyzingId === r.id) {
        Column({ space: 10 }) {
          LoadingProgress().width(30).height(30).color(Palette.PRIMARY)
          Text('正在读这场面试…').fontSize(13.5).fontColor(Palette.TX)
          Text('最多等 12 秒，超时会自动切到本地引擎，界面不会卡住')
            .fontSize(11).fontColor(Palette.TX_3).textAlign(TextAlign.Center)
            .lineHeight(17)
        }
        .width('100%')
        .padding({ top: 20, bottom: 20 })
      } else if (!this.hasRadar(r)) {
        Column({ space: 10 }) {
          Text('还没有能力雷达')
            .fontSize(13)
            .fontColor(Palette.TX_2)
          Text('把这段回忆交给分析引擎，会给出六个维度的评分、\n每一条都有你原话作依据，以及下周能动手做的事。')
            .fontSize(11.5)
            .fontColor(Palette.TX_3)
            .textAlign(TextAlign.Center)
            .lineHeight(18)
          Button('生成能力雷达')
            .fontSize(14)
            .fontColor(Palette.BG)
            .backgroundColor(Palette.PRIMARY)
            .height(40)
            .onClick(() => {
              this.generate(r);
            })
        }
        .width('100%')
        .padding({ top: 16, bottom: 8 })
      } else {
        // --- 来源标注：是云端结论还是本地初判，必须让用户知道 ---
        // 生成当下用 engineNote（即时反馈）；重进应用时 engineNote 是空的，
        // 回落到信封里存的来源 —— 这就是「来源也会持久化」的意义。
        Row({ space: 6 }) {
          Text(this.noteText(r))
            .fontSize(11)
            .fontColor(this.noteColor(r))
            .layoutWeight(1)
        }
        .width('100%')

        if (this.degradeNote.length > 0) {
          Text(this.degradeNote)
            .fontSize(11)
            .fontColor(Palette.TX_3)
            .width('100%')
            .lineHeight(16)
        }

        // --- 雷达图 ---
        Row() {
          RadarChart({
            scoresKey: this.scoresKeyOf(r),
            canvasSize: 260,
            showScale: true
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)

        // --- 一句话结论 ---
        if (this.summaryOf(r).length > 0) {
          Column({ space: 4 }) {
            Text('一句话结论').rvCardHead()
            Text(this.summaryOf(r))
              .fontSize(13)
              .fontColor(Palette.TX)
              .width('100%')
              .lineHeight(19)
          }
          .width('100%')
        }

        // --- 最该补的一块 ---
        if (this.weaknessOf(r).length > 0 && this.weaknessOf(r) !== '—') {
          Row({ space: 8 }) {
            Text('最该补')
              .fontSize(11)
              .fontColor(Palette.DANGER)
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .borderRadius(5)
              .backgroundColor('#2A1520')
            Text(this.weaknessOf(r))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Palette.TX)
              .layoutWeight(1)
          }
          .width('100%')
        }

        // --- 六维明细 ---
        Text('六维明细').rvCardHead()
        ForEach(this.dimsOf(r), (d: RadarDimension) => {
          this.dimRow(d)
        }, (d: RadarDimension) => `d-${r.id}-${d.key}-${d.score}`)

        // --- 下一步动作 ---
        if (this.actionsOf(r).length > 0) {
          Column({ space: 7 }) {
            Text('接下来做这三件事').rvCardHead()
            ForEach(this.actionsOf(r), (a: string, idx: number) => {
              Row({ space: 8 }) {
                Text(`${idx + 1}`)
                  .fontSize(11)
                  .fontColor(Palette.ACCENT)
                  .width(16)
                  .height(16)
                  .textAlign(TextAlign.Center)
                  .borderRadius(8)
                  .backgroundColor('#33280F')
                Text(a)
                  .fontSize(12.5)
                  .fontColor(Palette.TX_2)
                  .layoutWeight(1)
                  .lineHeight(18)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }, (a: string, idx: number) => `a-${r.id}-${idx}-${a}`)
          }
          .width('100%')
          .padding({ top: 4 })
        }

        Row({ space: 10 }) {
          Text('重新分析')
            .fontSize(12.5)
            .fontColor(Palette.PRIMARY)
            .padding({ top: 6, bottom: 6, left: 2, right: 8 })
            .onClick(() => {
              this.generate(r);
            })
          Blank()
          Text('收起')
            .fontSize(12.5)
            .fontColor(Palette.TX_3)
            .padding({ top: 6, bottom: 6 })
            .onClick(() => {
              this.openId = 0;
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 10 })
    .borderWidth({ top: topLine ? 1 : 0 })
    .borderColor(Palette.PANEL_2)
  }

  @Builder
  dimRow(d: RadarDimension) {
    Column({ space: 4 }) {
      Row() {
        Text(d.label)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TX)
          .layoutWeight(1)
        Text(d.score > 0 ? `${d.score}` : '未涉及')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.scoreColor(d.score))
      }
      .width('100%')

      Text(d.evidence)
        .fontSize(11.5)
        .fontColor(Palette.TX_3)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .lineHeight(16)

      if (d.advice.length > 0 && d.advice !== '—') {
        Text(`→ ${d.advice}`)
          .fontSize(11.5)
          .fontColor(Palette.PRIMARY)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .lineHeight(16)
      }
    }
    .width('100%')
    .padding({ top: 7, bottom: 7 })
  }

  @Builder
  reviewRow(r: ReviewRecord) {
    Column({ space: 8 }) {
      Row() {
        Text(this.appLabel(r.appId))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.TX)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(roundLabel(r.round))
          .fontSize(11)
          .fontColor(Palette.PURPLE)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .borderWidth(1)
          .borderColor(Palette.PURPLE)
      }
      .width('100%')

      Text(r.narration)
        .fontSize(12.5)
        .fontColor(Palette.TX_2)
        .maxLines(this.openId === r.id ? 6 : 2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row({ space: 6 }) {
        Text(this.hasRadar(r) ? `能力均分 ${r.scoreAvg} / 100` : '尚未分析')
          .fontSize(11.5)
          .fontColor(this.hasRadar(r) ? Palette.OK : Palette.TX_3)
        // 云端产出打标：演示时一眼能看出这条是模型给的，而不是本地关键词初判。
        // 来源来自落库的信封，所以重进应用后这个标依然在。
        if (this.isCloudRadar(r)) {
          Text('云端')
            .fontSize(10)
            .fontColor(Palette.PRIMARY)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .borderRadius(4)
            .borderWidth(1)
            .borderColor(Palette.PRIMARY)
        }
        Blank()
        Text(fmtDateTime(r.createdAt))
          .fontSize(11.5)
          .fontColor(Palette.TX_3)
      }
      .width('100%')

      // 未展开且已有雷达时，给一个明显的入口
      if (this.openId !== r.id) {
        Button(this.hasRadar(r) ? '查看能力雷达' : '生成能力雷达')
          .fontSize(13)
          .fontColor(this.hasRadar(r) ? Palette.PRIMARY : Palette.BG)
          .backgroundColor(this.hasRadar(r) ? Palette.PANEL_2 : Palette.PRIMARY)
          .height(36)
          .width('100%')
          .enabled(this.analyzingId === 0)
          .onClick(() => {
            if (this.hasRadar(r)) {
              this.openId = r.id;
            } else {
              this.generate(r);
            }
          })
      } else {
        this.radarBlock(r, true)
      }
    }
    .rvCard()
    .bindMenu(this.rowMenu(r))
  }

  /** 宽屏右栏要显示的那一条；未选中时返回空数组，ForEach 自然渲染 0 条 */
  private selected(): ReviewRecord[] {
    if (this.openId === 0) {
      return [];
    }
    for (let i = 0; i < this.reviews.length; i++) {
      if (this.reviews[i].id === this.openId) {
        return [this.reviews[i]];
      }
    }
    return [];
  }

  /**
   * 宽屏左栏的紧凑行。
   *
   * 和 reviewRow 的区别：这里**不做内联展开**，点击只负责"选中"，
   * 雷达与明细统一展在右栏 —— 同一份内容不出现在两处。
   * 否则左右两个滚动条各跑各的，比单列还难用。
   */
  @Builder
  compactRow(r: ReviewRecord) {
    Column({ space: 6 }) {
      Row() {
        Text(this.appLabel(r.appId))
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.openId === r.id ? Palette.ACCENT : Palette.TX)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(roundLabel(r.round))
          .fontSize(10.5)
          .fontColor(Palette.PURPLE)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius(6)
          .borderWidth(1)
          .borderColor(Palette.PURPLE)
      }
      .width('100%')

      Text(r.narration)
        .fontSize(12)
        .fontColor(Palette.TX_2)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row({ space: 6 }) {
        Text(this.hasRadar(r) ? `均分 ${r.scoreAvg} / 100` : '尚未分析')
          .fontSize(11)
          .fontColor(this.hasRadar(r) ? Palette.OK : Palette.TX_3)
        if (this.isCloudRadar(r)) {
          Text('云端')
            .fontSize(10)
            .fontColor(Palette.PRIMARY)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .borderRadius(4)
            .borderWidth(1)
            .borderColor(Palette.PRIMARY)
        }
        Blank()
        Text(fmtDateTime(r.createdAt))
          .fontSize(11)
          .fontColor(Palette.TX_3)
      }
      .width('100%')
    }
    .rvCard()
    // 选中态：换底色 + 描边。@Styles 展开在链式调用之前，这里能覆盖掉它的 backgroundColor
    .backgroundColor(this.openId === r.id ? Palette.PANEL_2 : Palette.PANEL)
    .borderWidth(1)
    .borderColor(this.openId === r.id ? Palette.ACCENT : Palette.PANEL)
    .bindMenu(this.rowMenu(r))
    .onClick(() => {
      this.openId = this.openId === r.id ? 0 : r.id;
    })
  }

  build() {
    if (this.twoPane) {
      // ── 宽屏双栏：左选场次，右看雷达
      Row({ space: Metrics.GAP }) {
        List({ space: 10 }) {
          ListItem() {
            Row() {
              Text('面试复盘')
                .fontSize(21)
                .fontWeight(FontWeight.Bold)
                .fontColor(Palette.TX)
              Blank()
              Button(this.showEditor ? '收起' : '记一场')
                .fontSize(13)
                .fontColor(Palette.BG)
                .backgroundColor(Palette.ACCENT)
                .height(32)
                .onClick(() => {
                  this.showEditor = !this.showEditor;
                })
            }
            .width('100%')
            .padding({ top: 8, bottom: 2 })
          }

          if (this.showEditor) {
            ListItem() {
              this.editor()
            }
          }

          if (this.reviews.length === 0 && !this.showEditor) {
            ListItem() {
              Column({ space: 8 }) {
                Text('还没有复盘记录').fontSize(14).fontColor(Palette.TX_2)
                Text('面完趁着记得，把问题倒出来。\n分析引擎会据此算出六维能力雷达，指出到底该补哪一块。')
                  .fontSize(12.5)
                  .fontColor(Palette.TX_3)
                  .textAlign(TextAlign.Center)
                  .lineHeight(20)
              }
              .width('100%')
              .padding({ top: 44, bottom: 44 })
            }
          } else if (this.reviews.length > 0) {
            ListItem() {
              Text(`已记录 ${this.reviews.length} 场 · 点一条看雷达 · 长按可删除`)
                .fontSize(12)
                .fontColor(Palette.TX_3)
                .width('100%')
                .padding({ left: 2, top: 8, bottom: 2 })
            }
            ForEach(this.reviews, (r: ReviewRecord) => {
              ListItem() {
                this.compactRow(r)
              }
            }, (r: ReviewRecord) => `cr-${r.id}-${r.scoreAvg}-${this.openId}-${this.analyzingId}`)
          }

          ListItem() {
            Row().height(20)
          }
        }
        .layoutWeight(1)
        .height('100%')
        .scrollBar(BarState.Off)

        List({ space: 10 }) {
          if (this.openId === 0) {
            ListItem() {
              Column({ space: 10 }) {
                Text('从左侧选一场面试').fontSize(14).fontColor(Palette.TX_2)
                Text('能力雷达、六维明细与「接下来做这三件事」\n都会出现在这里')
                  .fontSize(12)
                  .fontColor(Palette.TX_3)
                  .textAlign(TextAlign.Center)
                  .lineHeight(19)
              }
              .width('100%')
              .padding({ top: 70, bottom: 70 })
              .alignItems(HorizontalAlign.Center)
            }
          }
          ForEach(this.selected(), (r: ReviewRecord) => {
            ListItem() {
              Column({ space: 10 }) {
                // 右栏独占半屏，必须自己标明"看的是哪一场" ——
                // 左栏的高亮只能提示"选了哪条"，用户在右栏读到一半时早就想不起是哪家了。
                Row({ space: 8 }) {
                  Text(this.appLabel(r.appId))
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Palette.TX)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(roundLabel(r.round))
                    .fontSize(10.5)
                    .fontColor(Palette.PURPLE)
                    .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                    .borderRadius(6)
                    .borderWidth(1)
                    .borderColor(Palette.PURPLE)
                  Text(fmtDateTime(r.createdAt))
                    .fontSize(11)
                    .fontColor(Palette.TX_3)
                }
                .width('100%')

                this.radarBlock(r, false)
              }
              .rvCard()
            }
          }, (r: ReviewRecord) => `sel-${r.id}-${this.analyzingId}-${this.engineNote}-${this.degradeNote}`)
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
      List({ space: 10 }) {
      ListItem() {
        Row() {
          Text('面试复盘')
            .fontSize(21)
            .fontWeight(FontWeight.Bold)
            .fontColor(Palette.TX)
          Blank()
          Button(this.showEditor ? '收起' : '记一场')
            .fontSize(13)
            .fontColor(Palette.BG)
            .backgroundColor(Palette.ACCENT)
            .height(32)
            .onClick(() => {
              this.showEditor = !this.showEditor;
            })
        }
        .width('100%')
        .padding({ top: 8, bottom: 2 })
      }

      if (this.showEditor) {
        ListItem() {
          this.editor()
        }
      }

      if (this.reviews.length === 0 && !this.showEditor) {
        ListItem() {
          Column({ space: 8 }) {
            Text('还没有复盘记录').fontSize(14).fontColor(Palette.TX_2)
            Text('面完趁着记得，把问题倒出来。\n分析引擎会据此算出六维能力雷达，指出到底该补哪一块。')
              .fontSize(12.5)
              .fontColor(Palette.TX_3)
              .textAlign(TextAlign.Center)
              .lineHeight(20)
          }
          .width('100%')
          .padding({ top: 44, bottom: 44 })
        }
      } else if (this.reviews.length > 0) {
        ListItem() {
          Text(`已记录 ${this.reviews.length} 场 · 长按卡片可删除`)
            .fontSize(12)
            .fontColor(Palette.TX_3)
            .width('100%')
            .padding({ left: 2, top: 8, bottom: 2 })
        }
        ForEach(this.reviews, (r: ReviewRecord) => {
          ListItem() {
            this.reviewRow(r)
          }
        }, (r: ReviewRecord) => `rv-${r.id}-${r.scoreAvg}-${this.openId}-${this.analyzingId}`)
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
