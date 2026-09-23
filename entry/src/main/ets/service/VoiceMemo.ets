/**
 * 灯塔 Lighthouse · 语音速记
 * 目标路径：entry/src/main/ets/service/VoiceMemo.ets
 * ------------------------------------------------------------------
 * 端侧离线语音转文字（Core Speech Kit / speechRecognizer）。
 *
 * ⚠ 硬约束全部来自 API 定义（别凭记忆改）：
 *   ① 引擎**不自己录音**。`writeAudio(sessionId, audio)` 说明音频要我们自己采、
 *      再一段段喂进去 —— 所以 AudioCapturer 这段是必须的，不是可选优化。
 *      （反过来说这也是个好性质：喂什么音频就能识别什么，
 *        selfTestClip 正是靠这一点把识别链路变成可自动化的测试。）
 *   ② 音频格式被写死：pcm / 16000Hz / 单声道 / 16bit。
 *      采样率对不上识别率会断崖式下跌，而且不报错，只是"识别不出来"。
 *   ③ **writeAudio 每次只接受 640 或 1280 字节**，推荐间隔 20ms（640B）/ 40ms（1280B）。
 *      采集回调给的长度是任意的，必须自己攒够整块再喂，见 feed()。
 *   ④ 单次会话音频上限 60000ms，超了报 1002200003。
 *   ⑤ `online: 1` = 离线模式，当前 SDK 只支持离线。
 *      ⇒ 「声音不出设备」这句话是**真的**，不是宣传话术。
 *
 * 麦克风通路已实测可用（模拟器 x86 镜像走 `express_mic` 桥接宿主机麦克风），
 * 但**模拟器启动采集有明显延迟**，见 probe() 的注释 —— 那是本模块最容易踩的坑。
 */

import { speechRecognizer } from '@kit.CoreSpeechKit';
import { audio } from '@kit.AudioKit';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';

/** 采样率必须与 speechRecognizer 的 AudioInfo 一致，改一处就要改另一处 */
const SAMPLE_RATE: number = 16000;
/** 16000Hz × 16bit × 单声道 = 32 字节/毫秒。音频长度全靠它换算。 */
const BYTES_PER_MS: number = SAMPLE_RATE * 2 / 1000;
/** writeAudio 只收 640 / 1280 字节；选 1280（40ms）少一半调用次数 */
const CHUNK_BYTES: number = 1280;
const CHUNK_MS: number = CHUNK_BYTES / BYTES_PER_MS;
/** 引擎硬上限 60000ms，留 1 秒余量，免得最后一块踩线报 1002200003 */
const MAX_MS: number = 59000;
/** finish() 之后等 onComplete 的上限。等不到就先用已有结果收尾，别把 UI 卡在"正在出字" */
const COMPLETE_TIMEOUT_MS: number = 3000;

/**
 * 起引擎失败后的重试间隔（毫秒）。数组长度 = 额外重试次数。
 *
 * ⚠ 这不是"防抖动"式的乐观重试，而是**针对一个已查实的系统行为**：
 *   识别引擎是**系统级单例**，实际跑在 `com.huawei.hmsapp.hiai.voice` 进程里，
 *   任何应用占着它，我们的 createEngine 就会失败（code 1002200001，
 *   真实 message 是 `asr engine init failed with other process has initialized`）。
 *
 *   实测最常见的占用者是**系统输入法**：它在自己的语音输入被用到时会预初始化引擎。
 *   2026-09-21 01:12 的实机日志完整记录了这条路径 ——
 *       01:12:49.287  我们 createEngine 失败（被占用）
 *       01:12:49.360  输入法侧才 shutdown（`bundleName: com.huawei.hmos.inputmethod`）
 *       01:12:49.362  initEngineList length:0
 *   也就是说引擎在**我们失败后 ~70ms** 才被释放。一次失败就报错，
 *   会让用户看到"设备没装语音模型"这种**根本不成立的诊断**。
 */
const ENGINE_RETRY_MS: number[] = [250, 500, 1000, 1500];

/**
 * 值得重试的错误码：
 *   1002200001 Create engine failed（被别的进程初始化/初始化失败）
 *   1002200006 The engine is busy
 *   1002200008 The engine is being destroyed
 * 其余错误（比如参数非法 401）重试一万次也没用，直接失败更快把原因暴露出来。
 */
const ENGINE_RETRY_CODES: number[] = [1002200001, 1002200006, 1002200008];

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/** 速记状态。UI 直接拿它决定按钮长什么样。 */
export class DictState {
  static readonly IDLE: string = 'idle';           // 没在录
  static readonly STARTING: string = 'starting';   // 引擎/录音器在起，还没听到东西
  static readonly LISTENING: string = 'listening'; // 正在听
  static readonly FINISHING: string = 'finishing'; // 已停麦，等引擎吐最终结果
  static readonly ERROR: string = 'error';
}

/** UI 回调。onText 的 text 在 isFinal=false 时是"当前这句的草稿"，可能会变。 */
export interface DictationListener {
  onState: (state: string, detail: string) => void;
  onText: (text: string, isFinal: boolean) => void;
}

export interface DictStart {
  ok: boolean;
  reason: string;
}

/**
 * buildEngine 的结果。
 *
 * ⚠ 为什么用返回值表达失败而**不是 throw**：ArkTS 禁止抛任意类型
 *   （`arkts-limited-throw`），实测 `throw lastErr as BusinessError` 直接编译不过
 *   （"throw statements cannot accept values of arbitrary types"）。
 *   顺带也更诚实：`err` 原封不动带出来，调用方才能拿到**真实的 message** 去解释原因，
 *   而不是自己编一个。见 explainEngineError。
 */
interface EngineBuild {
  engine: speechRecognizer.SpeechRecognitionEngine | undefined;
  err: BusinessError | undefined;
}

export class VoiceMemo {
  /** 引擎与录音器都是重资源，一次会话用完就 shutdown / release，不跨会话复用 */
  private static engine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
  private static capturer: audio.AudioCapturer | undefined = undefined;
  private static sessionId: string = '';
  private static listening: boolean = false;
  private static finishing: boolean = false;
  /**
   * 引擎是否已就绪、可以接受音频。
   *
   * ⚠ 这个标志是必须的，别省。`startListening()` 是**同步返回**的，但它只表示
   *   "请求已受理"，引擎真正准备好的信号是 **onStart 回调**。
   *   在 onStart 之前调 writeAudio 会被拒（1002200010
   *   "Write audio failed because the start listening is failed"），
   *   而且这条错误会在 onStart 之前就回调进来 ——
   *   不小心就会把一次正常的会话判成失败，开头那截话也一起丢掉。
   *   实测踩过：日志里 onError 出现在 onStart 之前。
   */
  private static ready: boolean = false;
  private static cb: DictationListener | undefined = undefined;
  /** 攒不够一块的零头 */
  private static pending: Uint8Array = new Uint8Array(0);
  private static fedBytes: number = 0;
  private static frames: number = 0;
  private static peak: number = 0;
  private static writeErrors: number = 0;
  private static finishTimer: number = 0;
  /** 已定稿的句子。中间结果要拼在它后面显示，否则说完第二句第一句就没了。 */
  private static finalText: string = '';
  private static partialText: string = '';

  // ────────────────────────────── 权限 ──────────────────────────────

  /**
   * 申请麦克风权限。
   * ⚠ 必须是 user_grant 动态申请 —— 只写进 module.json5 的话，运行时静默失败，
   *   录音器照样能创建成功（createAudioCapturer 不报错），但 readData 一帧都不来。
   *   这种"看起来正常、实际没声音"是最难查的，所以第一次就显式问一次。
   */
  static async ensureMic(context: common.UIAbilityContext): Promise<boolean> {
    const perms: Permissions[] = ['ohos.permission.MICROPHONE'];
    try {
      const at: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const res: PermissionRequestResult =
        await at.requestPermissionsFromUser(context, perms);
      const granted: boolean = res.authResults.length > 0 && res.authResults[0] === 0;
      Log.i(`语音：麦克风权限 ${granted ? '已授予' : '被拒绝'}`);
      return granted;
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`语音：申请麦克风权限失败 ${err.message}`);
      return false;
    }
  }

  // ────────────────────────────── 引擎 ──────────────────────────────

  /** 引擎参数。自检要直接调 createEngine，所以单独抽出来，避免两处各写一份。 */
  private static engineParams(hotwords: string[]): speechRecognizer.CreateEngineParams {
    const extra: Record<string, Object> = {
      'locate': 'CN',
      'recognizerMode': 'short'
    };
    // 空数组别传：引擎对空热词表的处理没在文档里写死，索性不给
    if (hotwords.length > 0) {
      extra['sysGeneralLexicon'] = hotwords;
    }
    return {
      language: 'zh-CN',
      online: 1,
      extraParams: extra
    };
  }

  /**
   * 起离线识别引擎（带占用重试）。
   *
   * hotwords 是系统热词（最多 200 个、每个 2~20 字），能在识别阶段把专有名词
   * 往正确方向掰。秋招语境里最值得喂的是**公司名**和岗位名 ——
   * 那些词通用模型基本不认识，不喂就是一堆同音字。
   */
  private static async buildEngine(hotwords: string[]): Promise<EngineBuild> {
    const params: speechRecognizer.CreateEngineParams = VoiceMemo.engineParams(hotwords);

    // 引擎被别的进程占着时，它往往**很快**就放手（实测 70ms）——
    // 所以这里短重试几次，而不是一次失败就把功能判死。见 ENGINE_RETRY_MS 的注释。
    let lastErr: BusinessError | undefined = undefined;
    for (let attempt: number = 0; attempt <= ENGINE_RETRY_MS.length; attempt++) {
      if (attempt > 0) {
        const wait: number = ENGINE_RETRY_MS[attempt - 1];
        Log.w(`语音：引擎被占用，${wait}ms 后第 ${attempt + 1} 次尝试`);
        // 提示文案要短：这行渲染在「备注」右侧，maxLines(1) + 省略号
        VoiceMemo.emit(DictState.STARTING, '引擎被占用，正在重试…');
        await sleep(wait);
      }
      try {
        const eng: speechRecognizer.SpeechRecognitionEngine =
          await speechRecognizer.createEngine(params);
        if (attempt > 0) {
          // 这条日志是"重试真的救回来了"的唯一正面证据
          Log.i(`语音：第 ${attempt + 1} 次尝试拿到引擎（前 ${attempt} 次被占用）`);
        }
        const won: EngineBuild = { engine: eng, err: undefined };
        return won;
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        lastErr = err;
        Log.w(`语音：createEngine 失败（第 ${attempt + 1} 次）code=${err.code} ${err.message}`);
        if (ENGINE_RETRY_CODES.indexOf(err.code) < 0) {
          break;
        }
      }
    }
    const lost: EngineBuild = { engine: undefined, err: lastErr };
    return lost;
  }

  /** 失败详情拼成一行日志用的文本。原始 message 只进日志，不进界面。 */
  private static errText(err: BusinessError | undefined): string {
    if (err === undefined) {
      return '未知错误';
    }
    return `code=${err.code} ${err.message}`;
  }

  /**
   * 把"引擎起不来"翻译成**成立的原因**。返回的这句话直接显示给用户。
   *
   * ⚠ 两条约束，都踩过：
   *   ① **别拿泛化的 code 去猜原因**。1002200001 的官方描述只有一句
   *      "Create engine failed"，真正的信息在 message 里：
   *      `... other process has initialized` 是"被别人占着"，
   *      跟"这台设备没装语音模型"完全是两码事。
   *      第一版看到 1002200001 就写「这台设备可能没装语音模型」，结果用户截图里
   *      挂着一句**错误的诊断** —— 比报错本身更糟，它会把用户往
   *      "去下载语音包"这种完全没用的方向引。
   *   ② **必须短**。这行字渲染在「备注」标签右侧，`maxLines(1)` + 省略号，
   *      长了就被截成"这台设备可…"，等于没说。
   *      原始 message 一律由调用方写进 hilog（可查），不往界面上塞。
   */
  private static explainEngineError(err: BusinessError | undefined): string {
    if (err === undefined) {
      return '离线语音引擎起不来';
    }
    const m: string = err.message === undefined ? '' : err.message;
    if (m.indexOf('other process') >= 0 || err.code === 1002200006) {
      return '引擎被别的应用占着，再点一次';
    }
    return `离线语音引擎起不来（code ${err.code}）`;
  }

  /**
   * 组装热词：内置秋招高频词 + 用户自己库里的公司名。
   *
   * 为什么要把用户的公司名当热词：通用模型不认识"鼎捷软件""明源云"这类名字，
   * 说"投了明源云"很可能识别成"投了名额云"。把库里已有的名字喂进去，
   * 识别率提升是立竿见影的，而且是**用户自己的数据**，不需要任何网络。
   *
   * ⚠ 长度限制 2~20 字，超了整个参数会被判非法（401），所以必须过滤后再截断到 200 个。
   */
  static buildHotwords(companies: string[]): string[] {
    const base: string[] = [
      '笔试', '面试', '初面', '复面', '二面', '三面', '终面', '群面', '单面',
      '技术面', 'HR面', '主管面', '意向书', '三方协议', '背调', '体检', '实习', '转正',
      '秋招', '春招', '补录', '内推', '简历', '作品集', '成绩单', '薪资', '年包',
      '五险一金', '双休', '加班', '试用期', '沟通', '投递', '截止', '录用',
      '前端', '后端', '全栈', '算法', '测试', '运维', '产品', '运营', '设计',
      '客户端', '安卓', '鸿蒙', '嵌入式', '上位机'
    ];
    const out: string[] = [];
    const seen: string[] = [];
    const push = (w: string): void => {
      const t: string = w.trim();
      if (t.length < 2 || t.length > 20) {
        return;
      }
      if (seen.indexOf(t) >= 0) {
        return;
      }
      if (out.length >= 200) {
        return;
      }
      seen.push(t);
      out.push(t);
    };
    // 公司名放前面：热词表被截断时优先保住"用户自己的词"
    for (let i = 0; i < companies.length; i++) {
      push(companies[i]);
    }
    for (let i = 0; i < base.length; i++) {
      push(base[i]);
    }
    return out;
  }

  // ─────────────────────────── 实时速记 ───────────────────────────

  /**
   * 开始边听边转。成功只代表"引擎起来了、麦克风在采"，
   * 真正听到内容要等 onState 变 LISTENING 之后的 onText 回调。
   */
  static async startDictation(context: common.UIAbilityContext,
                              hotwords: string[],
                              listener: DictationListener): Promise<DictStart> {
    if (VoiceMemo.listening) {
      return { ok: false, reason: '已经在听了' };
    }
    VoiceMemo.cb = listener;
    VoiceMemo.sessionId = `lh${Date.now()}`;
    VoiceMemo.pending = new Uint8Array(0);
    VoiceMemo.fedBytes = 0;
    VoiceMemo.frames = 0;
    VoiceMemo.peak = 0;
    VoiceMemo.writeErrors = 0;
    VoiceMemo.finishTimer = 0;
    VoiceMemo.finalText = '';
    VoiceMemo.partialText = '';
    VoiceMemo.finishing = false;
    VoiceMemo.ready = false;
    VoiceMemo.listening = true;

    listener.onState(DictState.STARTING, '正在准备麦克风…');

    const granted: boolean = await VoiceMemo.ensureMic(context);
    if (!granted) {
      VoiceMemo.listening = false;
      const why: string = '没有麦克风权限，弹窗里点「允许」才能录音';
      listener.onState(DictState.ERROR, why);
      return { ok: false, reason: why };
    }

    const built: EngineBuild = await VoiceMemo.buildEngine(hotwords);
    const eng: speechRecognizer.SpeechRecognitionEngine | undefined = built.engine;
    if (eng === undefined) {
      Log.e(`语音：创建识别引擎失败（重试已用尽）${VoiceMemo.errText(built.err)}`);
      VoiceMemo.listening = false;
      const why: string = VoiceMemo.explainEngineError(built.err);
      listener.onState(DictState.ERROR, why);
      return { ok: false, reason: why };
    }

    // ⚠ 引擎到手之后**必须再确认这次会话还活着**。
    //   拿引擎最多要等 3.25 秒（重试窗口），这期间用户完全可能已经点了「停止」：
    //   那时 stopDictation 已经把状态清干净了，我们却继续往下建录音器、开始听 ——
    //   结果是"用户按了停止，它还在录"，而且引擎从此挂着不释放。
    //   （重试把这段窗口从毫秒级拉到了秒级，才让这个竞态变得现实。）
    if (!VoiceMemo.listening || VoiceMemo.finishing) {
      Log.w('语音：引擎起来时这次会话已被停掉，丢弃并释放引擎');
      VoiceMemo.shutdownEngine(eng);
      return { ok: false, reason: '已取消' };
    }
    VoiceMemo.engine = eng;

    eng.setListener({
      onStart: (sid: string, msg: string) => {
        Log.i(`语音：onStart ${msg}`);
        // 引擎就绪的门在这里才打开。在 onStart 之前采到的音频都堆在 pending 里，
        // 这里补一次 drain 把它们喂进去 —— 否则开头那截（"明天下午"）就白采了。
        VoiceMemo.ready = true;
        VoiceMemo.drain();
        VoiceMemo.emit(DictState.LISTENING, '正在听，说完点一下停止');
      },
      onEvent: (sid: string, code: number, msg: string) => {
        // 1 = 检测到人开始说话，3 = 检测到说话结束。
        // 这两个事件正好可以当"我到底有没有被听到"的即时反馈 ——
        // 模拟器上麦克风起流慢，用户按了没反应会以为功能坏了。
        Log.i(`语音：onEvent code=${code} ${msg}`);
        if (VoiceMemo.finishing) {
          return;
        }
        if (code === 1) {
          VoiceMemo.emit(DictState.LISTENING, '听到了，继续说…');
        } else if (code === 3) {
          VoiceMemo.emit(DictState.LISTENING, '这一段说完了，接着说要停就点停止');
        }
      },
      onResult: (sid: string, result: speechRecognizer.SpeechRecognitionResult) => {
        VoiceMemo.onResult(result);
      },
      onComplete: (sid: string, msg: string) => {
        Log.i(`语音：onComplete ${msg}`);
        VoiceMemo.finishSession();
      },
      onError: (sid: string, code: number, msg: string) => {
        // 1002200010 有两副面孔：
        //   · 引擎还没 onStart 就收到音频 —— 是我们抢跑，忽略即可（pending 会补喂）；
        //   · 就绪之后还报 —— 那是真出错，得收场。
        // 不区分的话，正常会话会在开头就被这条错误误杀。
        if (code === 1002200010 && !VoiceMemo.ready) {
          Log.w(`语音：引擎尚未就绪，暂缓喂音频（${msg}）`);
          return;
        }
        Log.e(`语音：onError code=${code} ${msg}`);
        VoiceMemo.emit(DictState.ERROR, `识别出错（code ${code}）`);
        VoiceMemo.abortCapturer();
        VoiceMemo.cleanup();
      }
    });

    try {
      eng.startListening({
        sessionId: VoiceMemo.sessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: SAMPLE_RATE,
          soundChannel: 1,
          sampleBit: 16
        }
      });
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.e(`语音：startListening 失败 code=${err.code} ${err.message}`);
      VoiceMemo.cleanup();
      const why: string = `启动识别失败（code ${err.code}）`;
      listener.onState(DictState.ERROR, why);
      return { ok: false, reason: why };
    }

    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };

    let cap: audio.AudioCapturer | undefined = undefined;
    try {
      cap = await audio.createAudioCapturer({ streamInfo, capturerInfo });
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.e(`语音：创建录音器失败 code=${err.code} ${err.message}`);
      VoiceMemo.cleanup();
      const why: string = `麦克风打不开（code ${err.code}）`;
      listener.onState(DictState.ERROR, why);
      return { ok: false, reason: why };
    }
    VoiceMemo.capturer = cap;
    cap.on('readData', (buf: ArrayBuffer) => {
      VoiceMemo.feed(buf);
    });
    try {
      await cap.start();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.e(`语音：麦克风启动失败 code=${err.code} ${err.message}`);
      VoiceMemo.abortCapturer();
      VoiceMemo.cleanup();
      const why: string = `麦克风启动失败（code ${err.code}）`;
      listener.onState(DictState.ERROR, why);
      return { ok: false, reason: why };
    }

    Log.i(`语音：开始速记 session=${VoiceMemo.sessionId} 热词 ${hotwords.length} 个`);
    return { ok: true, reason: '' };
  }

  /** 用户主动结束。停麦 → 把引擎里剩的音频吐完 → 拿最终结果。 */
  static async stopDictation(): Promise<void> {
    if (!VoiceMemo.listening || VoiceMemo.finishing) {
      return;
    }
    VoiceMemo.finishing = true;
    await VoiceMemo.stopCapturer();

    const eng: speechRecognizer.SpeechRecognitionEngine | undefined = VoiceMemo.engine;
    if (eng === undefined) {
      // ⚠ 引擎都还没起来 ⇒ 这一轮**压根没开始听**（可能还在等权限弹窗，
      //   也可能卡在引擎占用重试的窗口里，最长 3.25 秒）。
      //   这种情况不能走 finishSession —— 它会报「没听清，再说一次试试」，
      //   把人引到"是不是麦克风坏了"上去。如实收场，什么都不说。
      const cb: DictationListener | undefined = VoiceMemo.cb;
      VoiceMemo.cleanup();
      VoiceMemo.cb = undefined;
      Log.i('语音：还没开始听就被停掉了（引擎未就绪）');
      if (cb !== undefined) {
        cb.onState(DictState.IDLE, '');
      }
      return;
    }
    VoiceMemo.emit(DictState.FINISHING, '正在出字…');
    try {
      eng.finish(VoiceMemo.sessionId);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.w(`语音：finish 失败 code=${err.code}，直接用已有结果收尾`);
      VoiceMemo.finishSession();
      return;
    }
    // 看门狗：正常几毫秒就该回调 onComplete，等不到就别把 UI 挂住
    VoiceMemo.finishTimer = setTimeout(() => {
      Log.w(`语音：等 onComplete 超过 ${COMPLETE_TIMEOUT_MS}ms，用已有结果收尾`);
      VoiceMemo.finishSession();
    }, COMPLETE_TIMEOUT_MS);
  }

  /** 放弃这次速记（用户点了取消）。结果直接丢掉，不写进备注。 */
  static async cancelDictation(): Promise<void> {
    if (!VoiceMemo.listening) {
      return;
    }
    VoiceMemo.finishing = true;
    await VoiceMemo.stopCapturer();
    const eng: speechRecognizer.SpeechRecognitionEngine | undefined = VoiceMemo.engine;
    if (eng !== undefined) {
      try {
        eng.cancel(VoiceMemo.sessionId);
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        Log.w(`语音：cancel 失败 ${err.message}`);
      }
    }
    // 取消路径上不该再有 onText 出去，先把回调摘掉
    VoiceMemo.cb = undefined;
    VoiceMemo.cleanup();
    Log.i('语音：已取消本次速记');
  }

  // ─────────────────────────── 内部管线 ───────────────────────────

  private static emit(state: string, detail: string): void {
    const cb: DictationListener | undefined = VoiceMemo.cb;
    if (cb !== undefined) {
      cb.onState(state, detail);
    }
  }

  /**
   * 把引擎给的识别结果拼成人话。
   *
   * ⚠ 中间结果（isFinal=false）是**当前这句的整句草稿**，不是增量，
   *   所以不能往累积文本里加，只能替换"当前草稿"。
   *   而 final 结果有两种可能的引擎行为：给这一句、或给全文。
   *   这里用前缀比对兼容两者 —— 实测过正文才知道走哪条，但兼容写法两种都对。
   */
  private static onResult(result: speechRecognizer.SpeechRecognitionResult): void {
    const text: string = result.result;
    if (text.length === 0) {
      return;
    }
    const cb: DictationListener | undefined = VoiceMemo.cb;
    if (result.isFinal) {
      if (VoiceMemo.finalText.length > 0 && text.indexOf(VoiceMemo.finalText) === 0) {
        VoiceMemo.finalText = text;            // 引擎给的是全文，替换
      } else {
        VoiceMemo.finalText = VoiceMemo.finalText + text;  // 引擎给的只是这一句，追加
      }
      VoiceMemo.partialText = '';
      if (cb !== undefined) {
        cb.onText(VoiceMemo.finalText, true);
      }
    } else {
      VoiceMemo.partialText = text;
      if (cb !== undefined) {
        cb.onText(VoiceMemo.finalText + text, false);
      }
    }
  }

  /**
   * 采集回调：统计音量 + 把新数据并进待喂缓冲。
   *
   * 真正下发给引擎的是 drain()。拆开是因为**引擎就绪前采到的音频不能丢**：
   * onStart 之前来的数据只累积，等 onStart 到了由它补一次 drain。
   */
  private static feed(buf: ArrayBuffer): void {
    if (VoiceMemo.engine === undefined || VoiceMemo.finishing) {
      return;
    }
    const i16: Int16Array = new Int16Array(buf);
    for (let i: number = 0; i < i16.length; i++) {
      const v: number = i16[i];
      const a: number = v < 0 ? -v : v;
      if (a > VoiceMemo.peak) {
        VoiceMemo.peak = a;
      }
    }
    VoiceMemo.frames++;

    const fresh: Uint8Array = new Uint8Array(buf);
    const merged: Uint8Array = new Uint8Array(VoiceMemo.pending.length + fresh.length);
    merged.set(VoiceMemo.pending, 0);
    merged.set(fresh, VoiceMemo.pending.length);
    VoiceMemo.pending = merged;

    VoiceMemo.drain();
  }

  /**
   * 把缓冲里够整块的部分喂给引擎。
   *
   * ⚠ 三个必须做的事：
   *   ① **攒块**：readData 给的长度是任意的（实测 3200 字节），
   *      而 writeAudio 只收 640/1280。不攒就整批报 401。
   *   ② **等就绪**：引擎 ready（onStart）之前不下发，见 ready 的注释。
   *   ③ **限长**：超过 60 秒引擎会报 1002200003，得自己主动收尾。
   */
  private static drain(): void {
    const eng: speechRecognizer.SpeechRecognitionEngine | undefined = VoiceMemo.engine;
    if (eng === undefined || !VoiceMemo.ready) {
      return;
    }
    const buf: Uint8Array = VoiceMemo.pending;
    let off: number = 0;
    while (buf.length - off >= CHUNK_BYTES && VoiceMemo.fedBytes / BYTES_PER_MS < MAX_MS) {
      try {
        // slice 而不是 subarray：writeAudio 收的是 Uint8Array，
        // 用视图的话底层缓冲一旦被复用，喂进去的就是错的数据
        eng.writeAudio(VoiceMemo.sessionId, buf.slice(off, off + CHUNK_BYTES));
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        VoiceMemo.writeErrors++;
        // 别每帧刷日志：真出问题时一条就够，多了反而把 hilog 冲爆
        if (VoiceMemo.writeErrors <= 3) {
          Log.w(`语音：writeAudio 失败 code=${err.code} ${err.message}`);
        }
      }
      off += CHUNK_BYTES;
      VoiceMemo.fedBytes += CHUNK_BYTES;
    }
    VoiceMemo.pending = buf.slice(off);

    if (VoiceMemo.fedBytes / BYTES_PER_MS >= MAX_MS) {
      Log.i('语音：到达 60 秒上限，自动结束本次速记');
      VoiceMemo.stopDictation();
    }
  }

  private static async stopCapturer(): Promise<void> {
    const cap: audio.AudioCapturer | undefined = VoiceMemo.capturer;
    if (cap === undefined) {
      return;
    }
    VoiceMemo.capturer = undefined;
    // 先摘回调再停：stop() 期间仍可能有数据回调挤进来
    try {
      cap.off('readData');
    } catch (e) {
      Log.w('语音：摘 readData 回调失败');
    }
    try {
      await cap.stop();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.w(`语音：停录音器失败 code=${err.code}`);
    }
    try {
      cap.release();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.w(`语音：释放录音器失败 code=${err.code}`);
    }
  }

  /** 同步版的兜底释放（onError 那类已经没法 await 的路径上用） */
  private static abortCapturer(): void {
    const cap: audio.AudioCapturer | undefined = VoiceMemo.capturer;
    if (cap === undefined) {
      return;
    }
    VoiceMemo.capturer = undefined;
    try {
      cap.off('readData');
      cap.stop();
      cap.release();
    } catch (e) {
      Log.w('语音：兜底释放录音器时出错');
    }
  }

  /** 一次会话的收尾：出结果 → 释放所有资源 → 把状态归位 */
  private static finishSession(): void {
    if (VoiceMemo.finishTimer !== 0) {
      clearTimeout(VoiceMemo.finishTimer);
      VoiceMemo.finishTimer = 0;
    }
    if (!VoiceMemo.listening && !VoiceMemo.finishing) {
      return;
    }
    const text: string = VoiceMemo.finalText;
    const cb: DictationListener | undefined = VoiceMemo.cb;
    Log.i(`语音：本次速记结束 帧${VoiceMemo.frames} 峰值${VoiceMemo.peak}`
      + ` 喂入${Math.round(VoiceMemo.fedBytes / BYTES_PER_MS)}ms`
      + ` 写失败${VoiceMemo.writeErrors} 出字${text.length}字`);
    VoiceMemo.cleanup();
    if (cb === undefined) {
      return;
    }
    if (text.length > 0) {
      cb.onText(text, true);
      cb.onState(DictState.IDLE, '');
    } else {
      // 一句都没识别出来时也必须有反馈。静默收场会让用户以为按钮坏了。
      cb.onState(DictState.IDLE, '没听清，再说一次试试');
    }
    VoiceMemo.cb = undefined;
  }

  private static cleanup(): void {
    VoiceMemo.listening = false;
    VoiceMemo.finishing = false;
    VoiceMemo.ready = false;
    VoiceMemo.pending = new Uint8Array(0);
    VoiceMemo.finalText = '';
    VoiceMemo.partialText = '';
    const eng: speechRecognizer.SpeechRecognitionEngine | undefined = VoiceMemo.engine;
    VoiceMemo.engine = undefined;
    if (eng !== undefined) {
      try {
        eng.shutdown();
      } catch (e) {
        Log.w('语音：关闭引擎失败');
      }
    }
  }

  // ─────────────────────── 麦克风通路探测（自检） ───────────────────────

  /**
   * 录 5 秒，逐秒统计峰值与 RMS，写日志。
   *
   * 这是**验证手段**，不是功能的一部分。
   *
   * ⚠ 三个已经踩过的坑，改这段时别退回去：
   *   ① **录太短会把可用误判成不可用**。模拟器的麦克风要 ~1.8 秒才真正开始出数据
   *      （模拟器日志：`express_mic.c microphone start streaming` 比应用请求晚近 2 秒）。
   *      第一版只录 1.2 秒，只收到 1 帧空数据，差点把能做出来的功能判死。
   *      ⇒ 所以现在录 5 秒、逐秒统计，判定**只看第 2 秒之后**的稳定段。
   *   ② 前 100ms 会被系统主动静音（官方注释：消除麦克风上电噪声），
   *      第 0 秒峰值为 0 是正常的，不能当成"没声音"。
   *   ③ 有 MIC 设备节点 ≠ 有数据。`hidumper -s AudioPolicyService -a -d` 显示 MIC
   *      只能说明系统注册了设备，真正能出数据才算数 —— 判据必须是实际采到的振幅。
   */
  static async probe(context: common.UIAbilityContext): Promise<void> {
    const ok: boolean = await VoiceMemo.ensureMic(context);
    if (!ok) {
      Log.e('语音探测：权限未授予，无法录音');
      return;
    }

    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };

    let cap: audio.AudioCapturer | undefined = undefined;
    try {
      cap = await audio.createAudioCapturer({ streamInfo, capturerInfo });
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.e(`语音探测：创建录音器失败 code=${err.code} ${err.message}`);
      return;
    }

    const totalSec: number = 5;
    const secPeak: number[] = [0, 0, 0, 0, 0, 0];
    const secFrames: number[] = [0, 0, 0, 0, 0, 0];
    let frames: number = 0;
    let samples: number = 0;
    let peak: number = 0;
    let sumSq: number = 0;
    let firstFrameAt: number = -1;
    const startedAt: number = Date.now();

    cap.on('readData', (buf: ArrayBuffer) => {
      const t: number = Date.now() - startedAt;
      if (firstFrameAt < 0) {
        firstFrameAt = t;
      }
      const sec: number = Math.floor(t / 1000);
      const idx: number = sec < 0 ? 0 : (sec >= totalSec ? totalSec : sec);
      const view: Int16Array = new Int16Array(buf);
      for (let i: number = 0; i < view.length; i++) {
        const v: number = view[i];
        const a: number = v < 0 ? -v : v;
        if (a > peak) {
          peak = a;
        }
        if (a > secPeak[idx]) {
          secPeak[idx] = a;
        }
        sumSq += v * v;
        samples++;
      }
      secFrames[idx] = secFrames[idx] + 1;
      frames++;
    });

    try {
      await cap.start();
      await sleep(totalSec * 1000);
      await cap.stop();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.e(`语音探测：录音过程出错 code=${err.code} ${err.message}`);
    }

    const rms: number = samples > 0 ? Math.sqrt(sumSq / samples) : 0;
    Log.i(`语音探测结果：共 ${frames} 帧 / ${samples} 采样 / 峰值 ${peak} / RMS ${rms.toFixed(1)}`
      + ` / 首帧到达 ${firstFrameAt}ms`);

    let trace: string = '';
    for (let s: number = 0; s < totalSec; s++) {
      trace = trace + `[${s}s 峰值${secPeak[s]} 帧${secFrames[s]}] `;
    }
    Log.i(`语音探测逐秒：${trace}`);

    let stablePeak: number = 0;
    for (let s: number = 2; s < totalSec; s++) {
      if (secPeak[s] > stablePeak) {
        stablePeak = secPeak[s];
      }
    }

    if (frames === 0) {
      Log.e('语音探测结论：录音器没有回调任何数据 —— 通路不通');
    } else if (stablePeak === 0) {
      Log.e(`语音探测结论：稳定段（≥2s）峰值仍为 0，共 ${frames} 帧、首帧 ${firstFrameAt}ms`
        + ' —— 模拟器未接入真实音频输入');
    } else {
      Log.i(`语音探测结论：稳定段峰值 ${stablePeak}，麦克风通路可用`);
    }

    try {
      cap.release();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.w(`语音探测：释放录音器失败 ${err.message}`);
    }
  }

  // ───────────────────── 识别链路自检（喂音频文件） ─────────────────────

  /**
   * 用一段**现成的** PCM 音频跑完整识别链路，把结果写进 hilog。
   *
   * 为什么需要它：语音功能的验收有个死结 —— 要测"说话 → 出字"就得有人真的说话，
   * 而"人来说一句"既不能自动化、也谈不上可复现，回归时等于没测。
   * 但引擎的音频是**我们自己喂**的（见文件头 ①），所以把一段已知内容的 PCM
   * 当成麦克风数据灌进去，createEngine / startListening / writeAudio / onResult
   * 四步就全都能在无头环境下自动验证。音频由 make_voice_clip.py 用系统 TTS 合成，
   * 台词固定，断言就是"识别结果里有没有那几个词"。
   *
   * ⚠ 必须**按真实时间节奏**喂（每块 40ms 就 sleep 40ms）。
   *   一口气灌完的话引擎的 VAD 拿不到正常时间轴，会判成"没有有效语音"，
   *   表现是"接口全成功但结果为空" —— 看起来像识别不行，其实是喂法不对。
   */
  static async selfTestClip(context: common.UIAbilityContext,
                            rawName: string,
                            expectWords: string[]): Promise<void> {
    let data: Uint8Array = new Uint8Array(0);
    try {
      data = context.resourceManager.getRawFileContentSync(rawName);
    } catch (e) {
      const err: Error = e as Error;
      Log.e(`语音自检：读不到测试音频 ${rawName} —— ${err.message}`);
      Log.e('语音自检结论：FAIL（测试音频缺失，链路未验证）');
      return;
    }
    const clipMs: number = Math.round(data.length / BYTES_PER_MS);
    Log.i(`语音自检：测试音频 ${rawName}，${data.length} 字节 ≈ ${clipMs}ms`);

    const built: EngineBuild = await VoiceMemo.buildEngine(VoiceMemo.buildHotwords([]));
    const eng: speechRecognizer.SpeechRecognitionEngine | undefined = built.engine;
    if (eng === undefined) {
      Log.e(`语音自检：引擎创建失败 ${VoiceMemo.errText(built.err)}`);
      Log.e('语音自检结论：FAIL（这台设备起不了离线识别引擎，端侧语音不可用）');
      return;
    }

    const sid: string = `selftest${Date.now()}`;
    // 正向证据：验收脚本靠这一条判"引擎真的起来了"。
    // ⚠ 别用"没看到失败日志"来判成功 —— 前面任何一步提前 return（比如音频没读到），
    //   都会让"引擎创建失败"这条日志压根不出现，于是断言假阳性通过。
    Log.i(`语音自检：引擎创建成功（zh-CN 离线），session=${sid}`);
    let got: string = '';
    let partials: number = 0;
    let finals: number = 0;
    let errCode: number = 0;
    let completed: boolean = false;
    /** 同 startDictation：onStart 之前喂音频会被拒，得等这道门开 */
    let ready: boolean = false;

    eng.setListener({
      onStart: (s: string, msg: string) => {
        Log.i(`语音自检：onStart ${msg}`);
        ready = true;
      },
      onEvent: (s: string, code: number, msg: string) => {
        Log.i(`语音自检：onEvent code=${code} ${msg}`);
      },
      onResult: (s: string, result: speechRecognizer.SpeechRecognitionResult) => {
        if (result.isFinal) {
          finals++;
        } else {
          partials++;
        }
        got = result.result;
        Log.i(`语音自检：onResult isFinal=${result.isFinal} isLast=${result.isLast} "${result.result}"`);
      },
      onComplete: (s: string, msg: string) => {
        completed = true;
        Log.i(`语音自检：onComplete ${msg}`);
      },
      onError: (s: string, code: number, msg: string) => {
        // 引擎还没就绪就写音频（1002200010）在自检里也会发生 —— 那是时序，不是故障
        if (code === 1002200010 && !ready) {
          Log.w(`语音自检：引擎尚未就绪，暂缓喂音频（${msg}）`);
          return;
        }
        errCode = code;
        Log.e(`语音自检：onError code=${code} ${msg}`);
      }
    });

    try {
      eng.startListening({
        sessionId: sid,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: SAMPLE_RATE,
          soundChannel: 1,
          sampleBit: 16
        }
      });
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.e(`语音自检：startListening 失败 code=${err.code} ${err.message}`);
      Log.e('语音自检结论：FAIL（引擎在，但起不了识别会话）');
      VoiceMemo.shutdownEngine(eng);
      return;
    }

    // ⚠ 必须等 onStart。startListening 只是"请求受理"，抢跑喂音频必然报 1002200010。
    for (let i: number = 0; i < 50 && !ready; i++) {
      await sleep(20);
    }
    if (!ready) {
      Log.w('语音自检：onStart 一秒钟都没来，照样试着喂（结果可能为空）');
    }

    let writeFail: number = 0;
    let wrote: number = 0;
    let off: number = 0;
    while (off < data.length) {
      let piece: Uint8Array = data.slice(off, off + CHUNK_BYTES);
      if (piece.length < CHUNK_BYTES) {
        // 尾块补齐：writeAudio 只收 640/1280，不足的用静音填满
        const pad: Uint8Array = new Uint8Array(CHUNK_BYTES);
        pad.set(piece, 0);
        piece = pad;
      }
      try {
        eng.writeAudio(sid, piece);
        wrote++;
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        writeFail++;
        if (writeFail <= 3) {
          Log.e(`语音自检：writeAudio 失败 code=${err.code} ${err.message}`);
        }
      }
      off += CHUNK_BYTES;
      await sleep(CHUNK_MS);
    }
    Log.i(`语音自检：音频喂完，共 ${wrote} 块（失败 ${writeFail}）`);

    await sleep(300);
    try {
      eng.finish(sid);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Log.w(`语音自检：finish 失败 code=${err.code}`);
    }

    // ⚠ 收尾要等**最终结果**，不能只等固定时长就汇总。
    //   引擎是流式的：finish 之后它还在把积压的音频算完，模拟器上这一步可能好几秒。
    //   第一版只等 4 秒就汇总，明明后面出了完整句子，却记成了半句"明天下"。
    //   ⚠⚠ 2026-09-22 再修：**15 秒也不够**。13 套验收连着跑时模拟器负载高，
    //      最终结果在汇总**之后**才到 —— 日志现场是「自检结论：FAIL（全不沾边）」
    //      紧跟着才是 `isFinal=true isLast=true "明天下午2点面试…"`，"字其实识对了"。
    //      这种假红的代价很大：会让人去查音频格式、查麦克风，而真因只是等得不够。
    //      ⇒ 预算提到 45 秒，且把**实际等了多久**打出来，下次不用再靠猜。
    const waitT0: number = Date.now();
    for (let i: number = 0; i < 450 && !completed && finals === 0; i++) {
      await sleep(100);
    }
    const waited: number = Date.now() - waitT0;
    Log.i(`语音自检：等最终结果 ${waited}ms（final=${finals} completed=${completed}）`);
    // 拿到 final 后再多给 1 秒，让 onComplete 之类的收尾回调走完
    await sleep(1000);

    VoiceMemo.shutdownEngine(eng);

    Log.i(`语音自检汇总：中间结果 ${partials} 次 / 最终结果 ${finals} 次 / 错误码 ${errCode}`);
    Log.i(`语音自检识别文本："${got}"`);

    const hit: string[] = [];
    const miss: string[] = [];
    for (let i: number = 0; i < expectWords.length; i++) {
      if (got.indexOf(expectWords[i]) >= 0) {
        hit.push(expectWords[i]);
      } else {
        miss.push(expectWords[i]);
      }
    }
    Log.i(`语音自检关键词：命中 ${hit.length}/${expectWords.length} [${hit.join(' ')}]`
      + ` 未命中 [${miss.join(' ')}]`);

    if (errCode !== 0) {
      Log.e(`语音自检结论：FAIL（识别过程报错 code=${errCode}）`);
    } else if (got.length === 0) {
      Log.e('语音自检结论：FAIL（引擎全程无错，但一个字都没识别出来）');
    } else if (finals === 0) {
      // ⚠ 超时≠识别错。以前这条落到下面的「全不沾边」，诊断方向直接跑偏。
      Log.e(`语音自检结论：TIMEOUT（等了 ${waited}ms 没等到最终结果，`
        + `只有中间结果「${got}」—— 引擎太慢，不是识别失败，重跑一次）`);
    } else if (hit.length === 0) {
      Log.e(`语音自检结论：FAIL（出字了但全不沾边，可能是音频格式或节奏不对）`);
    } else {
      Log.i(`语音自检结论：PASS（端侧离线识别链路可用，命中 ${hit.length}/${expectWords.length}）`);
    }
  }

  private static shutdownEngine(eng: speechRecognizer.SpeechRecognitionEngine): void {
    try {
      eng.shutdown();
    } catch (e) {
      Log.w('语音自检：关闭引擎失败');
    }
  }
}
