/**
 * 灯塔 Lighthouse · 助手
 * 目标路径：entry/src/main/ets/view/AssistantView.ets
 * ------------------------------------------------------------------
 * 端侧智能体的界面。**这一页的重点不是聊天气泡，而是「工具轨迹」。**
 *
 * 普通 AI 聊天界面把推理过程藏起来，用户只能选择相信。灯塔反过来：
 * 每一条回答下面都原样列出"调了什么工具、查到了什么" —— 你说"最近要准备什么"，
 * 界面就显示 推算下一个节点 → 倒计时，以及它读到的那一行原始记录。
 * 这样即使分析有误，用户也能一眼看出是"按哪条数据得出的"。
 *
 * ⚠ ArkUI V1 的 @Builder **按值传参不建立响应式依赖**：
 *   形如 `this.row(label, value)` 的写法，@State 变了 Builder 内文字不刷新。
 *   所以本页一律用 ForEach + @Extend 属性 + 内联节点（这条坑在本工程踩过不止一次）。
 *
 * 布局取舍（2026-09-22 实测后重做）：
 *   改前的结构是「一个大 Scroll，输入区排在内容最后」。内容本来只有 361vp，而可视区 663vp ——
 *   于是输入框浮在屏幕中间，上下各空 151vp（实测 529px / 530px，差 1px，即**被居中**了）。
 *   两个原因叠在一起，得分别治：
 *     ① `Scroll` 在内容不足一屏时**默认垂直居中** ⇒ 显式 `.align(Alignment.Top)` 钉死；
 *     ② 输入区就不该在滚动流里 ⇒ 挪到 Scroll 外面吸底（聊天界面的通行做法）。
 *   剩下真正要做的是**把空态做厚**：概览条 + 四条带注脚的示范问句。
 *   ⛔ 别用 SpaceBetween / 拉大卡片"填满"：用空白填空白只会让内容更稀。
 */

import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Palette, Metrics, Tint } from '../common/Theme';
import { AgentAnswer, AgentStepView, LighthouseAgent, AGENT_SUGGESTIONS } from '../service/LighthouseAgent';
import { VoiceMemo, DictState, DictationListener, DictStart } from '../service/VoiceMemo';
import { ApplicationRepo, FunnelStat } from '../repository/ApplicationRepo';
import { EventRepo } from '../repository/EventRepo';
import { ReviewRepo } from '../repository/ReviewRepo';
import { Log } from '../common/Logger';

/**
 * 每条建议问句「会去查什么」。
 *
 * ⚠ 顺序必须与 `AGENT_SUGGESTIONS` 一一对应 —— 问句本身只有一份来源，
 *   这里只补注脚，别把问句抄第二遍（抄了就会两边不一致）。
 */
const ASK_HINTS: string[] = ['查节点日历', '查投递库', '查能力雷达', '查岗位库'];

/** 一条对话。role: 'q' 提问 / 'a' 回答 */
class ChatItem {
  role: string = '';
  text: string = '';
  answer: AgentAnswer | undefined = undefined;
  /** 用于 ForEach 的 key（每次追加自增） */
  seq: number = 0;
}

/**
 * 追加一条并返回新数组。
 *
 * ⚠ 为什么非要新数组：@State 数组直接 push 不触发变更通知**，界面会停在旧内容上。
 *   这类"数据对了但界面不动"的假故障在本工程已经踩过好几轮，所以这里一次到位。
 */
class ChatList {
  static append(old: ChatItem[], add: ChatItem): ChatItem[] {
    const next: ChatItem[] = [];
    for (let i: number = 0; i < old.length; i++) {
      next.push(old[i]);
    }
    next.push(add);
    return next;
  }
}

@Styles
function panel() {
  .padding(14)
  .backgroundColor(Palette.PANEL)
  .borderRadius(Metrics.CARD_RADIUS)
  .width('100%')
}

@Extend(Text)
function cardHead() {
  .fontSize(13)
  .fontColor(Palette.TX_3)
  .width('100%')
}

@Extend(Text)
function bodyText() {
  .fontSize(14.5)
  .fontColor(Palette.TX)
  .lineHeight(22)
}

@Extend(Text)
function evidenceText() {
  .fontSize(11.5)
  .fontColor(Palette.TX_2)
  .lineHeight(17)
}

@Component
export struct AssistantView {
  @Prop @Watch('onTick') tick: number = 0;
  onChanged: () => void = (): void => {};

  @State items: ChatItem[] = [];
  @State input: string = '';
  @State busy: boolean = false;
  @State cloudReady: boolean = false;
  private seq: number = 0;

  /**
   * 库里的家底，显示在空态的概览条里。
   * 目的很直接：让人（和评委）一眼看到"这个助手真的有数据可查"，而不是一个空壳输入框。
   * ⚠ 只在**没有对话时**显示 —— 聊天过程中再占一条，会把消息挤下去。
   */
  @State libApplied: number = 0;
  @State libNodes: number = 0;
  @State libReviews: number = 0;
  @State libRadar: number = 0;

  /** 语音输入（复用已有的端侧识别引擎，录音不出设备） */
  @State dictState: string = DictState.IDLE;
  @State dictHint: string = '';
  @State dictLive: string = '';

  @StorageProp('lhTwoPane') twoPane: boolean = false;

  /**
   * 自检提问通道（`aa start --ps lh_ask "最近要准备什么"`）。
   *
   * 为什么需要：智能体要能用**任意问话**验证，而验收脚本没有可靠的中文输入法
   * （`uinput` 只能注入坐标，输不了字）。没有这条通道就只剩点预设 chip，
   * 于是"库里查不到时不许编"这条最该测的断言一条都跑不了。
   *
   * ⚠ 订阅的是**序号**而不是问句本身：@Watch 只对值变化触发，
   *   连问两次同一句话时文本没变，界面会纹丝不动（假故障）。
   */
  @StorageProp('lhAskSeq') @Watch('onAskSignal') askSeq: number = 0;
  @StorageProp('lhAsk') askText: string = '';
  private lastAskSeq: number = 0;

  aboutToAppear(): void {
    // 如实标注：这一格回答 stories 里有没有云端参与，是用户判断"要不要联网"的依据
    this.cloudReady = LighthouseAgent.cloudAvailable();
    const ctx: common.Context | undefined = this.hostContext();
    if (ctx !== undefined) {
      LighthouseAgent.bindContext(ctx);
    }
    // ⚠ 冷启动带参提问时，信号早于界面创建（onCreate 写 AppStorage → 之后才 loadContent），
    //   而 @Watch 不会为"构造时的初值"补触发 ⇒ 必须在 aboutToAppear 里手工消费一次。
    //   这一条和 common/Nav 的 lhNavTarget 是同一个坑，那边也是这么补的。
    if (this.askSeq > 0) {
      this.onAskSignal();
    }
    this.loadLib();
  }

  /** 读一遍库里的家底。失败就算了 —— 概览条不该拖垮整个页面 */
  private async loadLib(): Promise<void> {
    try {
      const f: FunnelStat = await ApplicationRepo.funnel();
      this.libApplied = f.total;
      this.libNodes = await EventRepo.pendingCount();
      this.libReviews = await ReviewRepo.count();
      this.libRadar = await ReviewRepo.analyzedCount();
    } catch (e) {
      const err: Error = e as Error;
      Log.w(`助手读取库家底失败：${err.message}`);
    }
  }

  /** 收到自检提问 → 当成用户手打的问题跑一遍完整链路 */
  onAskSignal(): void {
    if (this.askSeq === this.lastAskSeq) {
      return;
    }
    this.lastAskSeq = this.askSeq;
    const q: string = this.askText;
    if (q.length === 0) {
      return;
    }
    Log.i(`自检提问：${q}`);
    this.ask(q);
  }

  onTick(): void {
    this.cloudReady = LighthouseAgent.cloudAvailable();
    this.loadLib();
  }

  private hostContext(): common.Context | undefined {
    return this.getUIContext().getHostContext();
  }

  /** 上面的标签：让人第一眼知道"这个助手会不会联网" */
  private sourceNote(): string {
    return this.cloudReady ? '云端兜底已就绪 · 看不懂的问题会请模型帮忙解析' : '当前纯本地运转 · 断网也能答';
  }

  /* ============================ 提问 ============================ */

  private async ask(q: string): Promise<void> {
    const question: string = q.trim();
    if (question.length === 0) {
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.input = '';

    this.seq = this.seq + 1;
    const ask: ChatItem = new ChatItem();
    ask.role = 'q';
    ask.text = question;
    ask.seq = this.seq;
    // ⚠ 必须换一个新数组：直接 push 不会触发 @State 的变更通知（界面纹丝不动，
    //   而日志里数据是对的 —— 这类假故障本工程踩过好几次）。
    this.items = ChatList.append(this.items, ask);

    try {
      const ans: AgentAnswer = await LighthouseAgent.ask(question);
      this.seq = this.seq + 1;
      const rep: ChatItem = new ChatItem();
      rep.role = 'a';
      rep.text = ans.text;
      rep.answer = ans;
      rep.seq = this.seq;
      this.items = ChatList.append(this.items, rep);
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`助手执行异常：${err.message}`);
      promptAction.showToast({ message: '助手没能给出回答，看下日志' });
    } finally {
      this.busy = false;
    }
  }

  /* ============================ 语音 ============================ */

  /** 是否正在录音 */
  private dictBusy(): boolean {
    return this.dictState === DictState.STARTING || this.dictState === DictState.LISTENING;
  }

  private async toggleVoice(): Promise<void> {
    if (this.dictBusy() || this.dictState === DictState.FINISHING) {
      await VoiceMemo.stopDictation();
      return;
    }
    const host: common.Context | undefined = this.hostContext();
    if (host === undefined) {
      promptAction.showToast({ message: '拿不到页面上下文，稍后再试' });
      return;
    }
    const ctx: common.UIAbilityContext = host as common.UIAbilityContext;
    // 公司名当热词：通用模型不认识「鼎捷软件」这类名字，喂进去识别才准。
    // 这份数据来自用户自己的库，全程在本机 —— 语音这一块不联网。
    const apps = await ApplicationRepo.listAll();
    const names: string[] = [];
    for (let i: number = 0; i < apps.length; i++) {
      names.push(apps[i].company);
    }
    const listener: DictationListener = {
      onState: (st: string, detail: string) => {
        this.dictState = st;
        this.dictHint = detail;
      },
      onText: (text: string, isFinal: boolean) => {
        if (isFinal) {
          this.input = this.mergeInput(this.input, text);
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

  /** 追加而不是覆盖：用户可能先打了半句再说下半句，覆盖等于丢数据 */
  private mergeInput(old: string, add: string): string {
    const a: string = add.trim();
    if (a.length === 0) {
      return old;
    }
    const o: string = old.trim();
    if (o.length === 0) {
      return a;
    }
    return `${o}${a}`;
  }

  /* ============================ UI ============================ */

  @Builder
  headerRow() {
    Row() {
      Text('助手')
        .fontSize(21)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TX)
      Blank()
      Text('Agent')
        .fontSize(11)
        .fontColor(Palette.PRIMARY)
        .backgroundColor(Tint.PRIMARY)
        .borderRadius(Metrics.CHIP_RADIUS)
        .padding({ left: 7, right: 7, top: 3, bottom: 3 })
    }
    .width('100%')
    .padding({ top: 8 })

    Text('问一句话，它去翻你自己的投递库、节点日历和能力雷达来回答 —— ' +
      '每条结论下面都列了依据，不存在凭空编出来的部分。')
      .fontSize(12)
      .fontColor(Palette.TX_3)
      .width('100%')
      .lineHeight(18)

    Row({ space: 6 }) {
      Text(this.cloudReady ? '●' : '○')
        .fontSize(11)
        .fontColor(this.cloudReady ? Palette.OK : Palette.TX_3)
      Text(this.sourceNote())
        .fontSize(11)
        .fontColor(Palette.TX_3)
    }
    .width('100%')
    .padding({ top: 2 })
  }

  /**
   * 库里的家底 —— 空态才有。
   * 不放任何"假数据"：数字全部现查，所以它同时也是一个"这助手是不是真的接了你的库"的证据。
   */
  @Builder
  libraryStrip() {
    Row({ space: 8 }) {
      Column({ space: 3 }) {
        Text(`${this.libApplied}`).fontSize(20).fontWeight(FontWeight.Bold).fontColor(Palette.TX)
        Text('投递').fontSize(11).fontColor(Palette.TX_3)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      Column({ space: 3 }) {
        Text(`${this.libNodes}`).fontSize(20).fontWeight(FontWeight.Bold).fontColor(Palette.ACCENT)
        Text('待办节点').fontSize(11).fontColor(Palette.TX_3)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      Column({ space: 3 }) {
        Text(`${this.libReviews}`).fontSize(20).fontWeight(FontWeight.Bold).fontColor(Palette.TX)
        Text('面试复盘').fontSize(11).fontColor(Palette.TX_3)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      Column({ space: 3 }) {
        Text(`${this.libRadar}`).fontSize(20).fontWeight(FontWeight.Bold).fontColor(Palette.OK)
        Text('能力雷达').fontSize(11).fontColor(Palette.TX_3)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .panel()
  }

  /**
   * 没开始对话时给几个可点的示范 —— 同时也是给评委看的"能问什么"。
   *
   * 从「一排小 chip」改成「四条通栏行」：chip 只写得出问句，写不出**它会去查什么**；
   * 而"每条结论都能追到依据"正是这一页最想让人看到的东西。注脚因此不是装饰。
   */
  @Builder
  suggestionRow() {
    Column({ space: 8 }) {
      Text('可以这样问 · 点一下就查').cardHead()

      ForEach(AGENT_SUGGESTIONS, (s: string, i: number) => {
        Row({ space: 10 }) {
          Column({ space: 4 }) {
            Text(s)
              .fontSize(13.5)
              .fontColor(Palette.TX)
              .width('100%')
            Text(i < ASK_HINTS.length ? ASK_HINTS[i] : '')
              .fontSize(11)
              .fontColor(Palette.TX_3)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('›')
            .fontSize(18)
            .fontColor(Palette.TX_3)
        }
        .width('100%')
        .padding(11)
        .backgroundColor(Palette.PANEL_2)
        .borderRadius(Metrics.CHIP_RADIUS)
        .enabled(!this.busy)
        .onClick(() => {
          this.ask(s);
        })
      }, (s: string) => `sg-${s}`)

      Text('每条回答下面都会列「调了什么工具、读到哪一行原始记录」—— 结论对不对，你自己能判断。')
        .fontSize(11)
        .fontColor(Palette.TX_3)
        .lineHeight(16)
        .width('100%')
    }
    .panel()
  }

  /* ---- 给 @Builder 用的取值方法（Builder 内不允许声明局部变量） ---- */

  private stepsOf(item: ChatItem): AgentStepView[] {
    const ans: AgentAnswer | undefined = item.answer;
    if (ans === undefined) {
      return [];
    }
    return ans.steps;
  }

  private sourceOf(item: ChatItem): string {
    const ans: AgentAnswer | undefined = item.answer;
    return ans === undefined ? '' : ans.source;
  }

  /** 回答卡片 —— 本页的主角：答案在上，工具轨迹在下 */
  @Builder
  answerCard(item: ChatItem) {
    Column({ space: 10 }) {
      Text(item.text).bodyText().width('100%')

      // ⚠ @Builder 里不能写 `const ans = item.answer` 这类语句（只能放 UI 描述），
      //   所以取值一律走成员方法 —— 顺带把 undefined 的情况收敛成"空"。
      if (item.answer !== undefined) {
        Row({ space: 6 }) {
          Text(this.sourceOf(item))
            .fontSize(10.5)
            .fontColor(Palette.PRIMARY)
            .backgroundColor(Tint.PRIMARY)
            .borderRadius(Metrics.CHIP_RADIUS)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          Text(`${this.stepsOf(item).length} 步`)
            .fontSize(10.5)
            .fontColor(Palette.TX_3)
        }
        .width('100%')

        Column({ space: 6 }) {
          ForEach(this.stepsOf(item), (st: AgentStepView, idx: number) => {
            Column({ space: 3 }) {
              Row({ space: 6 }) {
                Text(st.ok ? '✓' : '!')
                  .fontSize(11)
                  .fontColor(st.ok ? Palette.OK : Palette.ACCENT)
                Text(st.label)
                  .fontSize(11.5)
                  .fontColor(Palette.TX_2)
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')

              ForEach(st.lines, (line: string, k: number) => {
                Text(line).evidenceText().width('100%')
              }, (line: string, k: number) => `ln-${idx}-${k}-${line}`)
            }
            .width('100%')
            .padding(9)
            .backgroundColor(Palette.PANEL_2)
            .borderRadius(Metrics.CHIP_RADIUS)
          }, (st: AgentStepView, idx: number) => `st-${item.seq}-${idx}-${st.tool}`)
        }
        .width('100%')
      }
    }
    .panel()
  }

  @Builder
  conversation() {
    Column({ space: 10 }) {
      ForEach(this.items, (item: ChatItem) => {
        if (item.role === 'q') {
          Row() {
            Blank()
            Text(item.text)
              .fontSize(14)
              .fontColor(Palette.BG)
              .backgroundColor(Palette.PRIMARY)
              .borderRadius(Metrics.CHIP_RADIUS)
              .padding({ left: 11, right: 11, top: 8, bottom: 8 })
              .constraintSize({ maxWidth: '80%' })
          }
          .width('100%')
        } else {
          this.answerCard(item)
        }
      }, (item: ChatItem) => `it-${item.seq}-${item.role}`)
    }
    .width('100%')
  }

  @Builder
  inputRow() {
    Row({ space: 8 }) {
      Row({ space: 6 }) {
        TextInput({ text: this.input, placeholder: '问点什么，比如「最近要准备什么」' })
          .backgroundColor(Palette.PANEL)
          .borderRadius(Metrics.CHIP_RADIUS)
          .fontSize(14)
          .fontColor(Palette.TX)
          .placeholderColor(Palette.TX_3)
          .layoutWeight(1)
          .height(44)
          .onChange((v: string) => {
            this.input = v;
          })
        Text(this.dictBusy() ? '停' : '语音')
          .fontSize(13)
          .fontColor(this.dictBusy() ? Palette.BG : Palette.ACCENT)
          .backgroundColor(this.dictBusy() ? Palette.ACCENT : Tint.ACCENT)
          .borderRadius(Metrics.CHIP_RADIUS)
          .textAlign(TextAlign.Center)
          .height(44)
          .width(58)
          .onClick(() => {
            this.toggleVoice();
          })
      }
      .layoutWeight(1)

      Text(this.busy ? '…' : '发送')
        .fontSize(14)
        .fontColor(Palette.BG)
        .backgroundColor(Palette.PRIMARY)
        .borderRadius(Metrics.CHIP_RADIUS)
        .textAlign(TextAlign.Center)
        .height(44)
        .width(64)
        .enabled(!this.busy)
        .opacity(this.busy ? 0.5 : 1)
        .onClick(() => {
          this.ask(this.input);
        })
    }
    .width('100%')

    if (this.dictState !== DictState.IDLE && this.dictHint.length > 0) {
      Text(this.dictHint)
        .fontSize(11)
        .fontColor(Palette.TX_3)
        .width('100%')
    }
    if (this.dictLive.length > 0) {
      Text(`正在听：${this.dictLive}`)
        .fontSize(11.5)
        .fontColor(Palette.ACCENT)
        .width('100%')
    }
  }

  build() {
    Column() {
      // ⚠ 输入区必须**在 Scroll 外面**（见文件头）：挂在里面会跟着内容走，
      //   内容短的时候整块浮在屏幕中间，上下各留一大片空白。
      Scroll() {
        Column({ space: Metrics.GAP }) {
          this.headerRow()

          // 概览条与示范问句只在空态出现 —— 有对话之后它们只会把消息往下挤
          if (this.items.length === 0) {
            this.libraryStrip()
            this.suggestionRow()
          }

          this.conversation()

          if (this.busy) {
            Row({ space: 8 }) {
              Text('·').fontSize(18).fontColor(Palette.PRIMARY)
              Text('正在查你的数据…')
                .fontSize(12.5)
                .fontColor(Palette.TX_3)
            }
            .width('100%')
          }

          Row().height(4)
        }
        .width('100%')
        .padding({ left: Metrics.PAGE_PAD, right: Metrics.PAGE_PAD })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // ⚠ 显式钉顶部：Scroll 内容不足一屏时**默认垂直居中**（详见文件头）
      .align(Alignment.Top)

      // 吸底输入区。自己带底色，免得和滚上来的内容糊在一起
      Column() {
        this.inputRow()
      }
      .width('100%')
      .padding({ left: Metrics.PAGE_PAD, right: Metrics.PAGE_PAD, top: Metrics.GAP_S, bottom: Metrics.GAP_S })
      .backgroundColor(Palette.BG)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG)
  }
}
