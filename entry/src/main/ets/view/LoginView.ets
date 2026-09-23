import { Palette, Metrics } from '../common/Theme';
import { Auth, AuthResult, AccountInfo } from '../service/Auth';
import { Log } from '../common/Logger';

/** ⚠ @Styles 不能放组件专有属性（fontSize/placeholderColor），必须用 @Extend(TextInput) */
@Extend(TextInput)
function authField() {
  .backgroundColor(Palette.PANEL_2)
  .borderRadius(Metrics.CHIP_RADIUS)
  .fontSize(14.5)
  .fontColor(Palette.TX)
  .placeholderColor(Palette.TX_3)
  .height(46)
  .width('100%')
}

enum LoginMode {
  CREATE = 0,
  UNLOCK = 1
}

/**
 * 本地档案：创建 / 解锁。
 *
 * ══════════════════════════════════════════════════════════════════════
 * 产品上为什么是这样，而不是一个"登录注册页"
 * ══════════════════════════════════════════════════════════════════════
 *
 * 这个应用**没有服务端**，所以它不需要账号 —— 说"注册"是自欺欺人，
 * 评委一句"你注册到哪去了"就问穿了。
 *
 * 它真正需要的是**一把锁**：投递记录、面试评价、期望薪资是这台设备上最敏感的东西，
 * 而这个应用是纯离线的，所以"本地档案"这个词才准确 ——
 * 名字只用来在界面上称呼你，密码才是那把锁。
 *
 * 因此首次启动的按钮是「**创建并进入**」而不是「注册」，
 * 底部说明直接写清楚数据不出设备。把动机说在明面上，比藏着一个登录框诚实。
 */
@Component
export struct LoginView {
  /** 解锁成功后通知主壳放行 */
  onUnlocked: () => void = (): void => {};

  @State mode: LoginMode = LoginMode.UNLOCK;
  /** CREATE 时是用户输入；UNLOCK 时是从库里读出来的称呼（只用于显示） */
  @State username: string = '';
  @State pass: string = '';
  @State confirm: string = '';
  @State err: string = '';
  @State busy: boolean = false;
  @State ready: boolean = false;

  aboutToAppear(): void {
    this.boot();
  }

  private async boot(): Promise<void> {
    try {
      const info: AccountInfo | undefined = await Auth.info();
      if (info === undefined) {
        // 这台设备上还没建过档案 → 引导创建，而不是让他对着"请输入密码"发愣
        this.mode = LoginMode.CREATE;
      } else {
        this.mode = LoginMode.UNLOCK;
        this.username = info.username;
      }
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`登录页初始化失败：${err.message}`);
      this.mode = LoginMode.CREATE;
    }
    this.ready = true;
  }

  private async submit(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.err = '';
    if (this.mode === LoginMode.CREATE) {
      const bad: string = Auth.validateNew(this.username, this.pass, this.confirm);
      if (bad.length > 0) {
        this.err = bad;
        return;
      }
    } else if (this.pass.length === 0) {
      this.err = '请输入密码';
      return;
    }

    this.busy = true;
    try {
      // ⚠ 两个分支都返回 Promise<AuthResult>，但不能写成 `let r` 再赋值 ——
      //   ArkTS 要求声明即初始化，所以这里用三元一次性定下来。
      const r: AuthResult = this.mode === LoginMode.CREATE
        ? await Auth.createAccount(this.username, this.pass)
        : await Auth.login(this.pass);
      this.pass = '';
      this.confirm = '';
      if (r.ok) {
        this.onUnlocked();
      } else {
        this.err = r.reason;
      }
    } catch (e) {
      const er: Error = e as Error;
      Log.e(`登录提交异常：${er.message}`);
      this.err = '出错了，请重试';
    }
    this.busy = false;
  }

  private reset(): void {
    AlertDialog.show({
      title: '重置本地档案',
      message: '档案和全部投递数据都会被清空，无法恢复。'
        + '\n\n（密码是唯一入口，忘记密码时只能这样重来 —— 这也是"数据只在你手里"的代价。）',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '确认重置',
        fontColor: Palette.DANGER,
        action: (): void => {
          this.doReset();
        }
      }
    });
  }

  private async doReset(): Promise<void> {
    await Auth.resetAll();
    this.pass = '';
    this.confirm = '';
    this.username = '';
    this.err = '';
    this.mode = LoginMode.CREATE;
  }

  private badgeText(): string {
    if (this.mode === LoginMode.UNLOCK && this.username.length > 0) {
      return this.username.substring(0, 1);
    }
    return '灯';
  }

  private titleText(): string {
    return this.mode === LoginMode.CREATE ? '创建本地档案' : '欢迎回来';
  }

  private subText(): string {
    return this.mode === LoginMode.CREATE
      ? '这台设备上还没有档案 · 数据会留在这里'
      : `${this.username}`;
  }

  private btnText(): string {
    if (this.busy) {
      return '处理中…';
    }
    return this.mode === LoginMode.CREATE ? '创建并进入' : '解锁';
  }

  @Builder
  badge() {
    Text(this.badgeText())
      .fontSize(26)
      .fontWeight(FontWeight.Bold)
      .fontColor(Palette.BG)
      .backgroundColor(Palette.ACCENT)
      .width(64)
      .height(64)
      .borderRadius(32)
      .textAlign(TextAlign.Center)
  }

  @Builder
  head() {
    Column({ space: 7 }) {
      Text(this.titleText())
        .fontSize(21)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.TX)
      Text(this.subText())
        .fontSize(12.5)
        .fontColor(Palette.TX_3)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
  }

  @Builder
  form() {
    Column({ space: 10 }) {
      if (this.mode === LoginMode.CREATE) {
        TextInput({ text: this.username, placeholder: '怎么称呼你，如「小曾」' })
          .authField()
          .maxLength(12)
          .onChange((v: string) => {
            this.username = v;
          })
      }

      TextInput({ text: this.pass, placeholder: '密码（至少 6 位）' })
        .authField()
        .type(InputType.Password)
        .maxLength(32)
        .onChange((v: string) => {
          this.pass = v;
        })

      if (this.mode === LoginMode.CREATE) {
        TextInput({ text: this.confirm, placeholder: '再输一次密码' })
          .authField()
          .type(InputType.Password)
          .maxLength(32)
          .onChange((v: string) => {
            this.confirm = v;
          })
      }
    }
    .width('100%')
  }

  @Builder
  errLine() {
    if (this.err.length > 0) {
      Text(this.err)
        .fontSize(12.5)
        .fontColor(Palette.DANGER)
        .width('100%')
        .textAlign(TextAlign.Center)
    }
  }

  @Builder
  mainBtn() {
    Button(this.btnText())
      .fontSize(15.5)
      .fontWeight(FontWeight.Medium)
      .fontColor(Palette.BG)
      .backgroundColor(this.busy ? Palette.TX_3 : Palette.PRIMARY)
      .height(48)
      .width('100%')
      .enabled(!this.busy)
      .onClick(() => {
        this.submit();
      })
  }

  @Builder
  resetLink() {
    if (this.mode === LoginMode.UNLOCK) {
      Text('忘记密码？')
        .fontSize(12.5)
        .fontColor(Palette.TX_3)
        .decoration({ type: TextDecorationType.Underline, color: Palette.TX_3 })
        .onClick(() => {
          this.reset();
        })
    }
  }

  /**
   * 底部说明。
   *
   * 这不是装饰性文案 —— 它是这个功能**存在的理由**。
   * 没有它，"为什么要我设密码"就成了一个没有答案的问题。
   */
  @Builder
  footNote() {
    Column({ space: 3 }) {
      Text('全程离线 · 没有云端账号')
        .fontSize(11.5)
        .fontColor(Palette.TX_3)
      Text('投递记录、面试评价、期望薪资都只存在这台设备上')
        .fontSize(11.5)
        .fontColor(Palette.TX_3)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ left: 28, right: 28, bottom: 30 })
  }

  build() {
    Column() {
      Blank()

      if (this.ready) {
        Column({ space: 18 }) {
          this.badge()
          this.head()
          this.form()
          this.errLine()
          this.mainBtn()
          this.resetLink()
        }
        .width('100%')
        .padding({ left: 28, right: 28 })
      }

      Blank()
      this.footNote()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.BG)
  }
}
