import { AbilityConstant, ConfigurationConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { DbHelper } from '../model/DbHelper';
import { DeepSeekClient } from '../service/DeepSeekClient';
import { Sentinel, SentinelReport } from '../service/Sentinel';
import { VoiceMemo } from '../service/VoiceMemo';
import { pushNavTarget, navTargetOf } from '../common/Nav';
import { applyLayoutPreview } from '../common/Layout';
import { Log } from '../common/Logger';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 数据库在这里拉起一次，之后全应用共用同一个 store。
    // 不 await：建库是毫秒级，页面 aboutToAppear 里会通过 DbHelper.get() 自然排队等待。
    DbHelper.init(this.context)
      .then(() => {
        Log.i('DbHelper ready in Ability.onCreate');
      })
      .catch((err: Error) => {
        Log.e(`DbHelper init failed: ${err.message}`);
      });

    // AI 客户端同理，必须在这里加载一次。
    // ⚠ 漏了这一步会静默降级：apiKey 初值是空串，isCloudEnabled() 会一直为 false，
    //   于是「配了 key 也用不上云端」，日志只留一句『云端不可用：未配置 API Key』，
    //   从表面看像是没配 key，实际是压根没读进来。
    DeepSeekClient.get().load(this.context)
      .then(() => {
        Log.i(`AI client ready, cloudEnabled=${DeepSeekClient.get().isCloudEnabled()}`);
      })
      .catch((err: Error) => {
        Log.e(`AI client load failed: ${err.message}`);
      });

    // 首次启动可能是从桌面卡片点进来的，意图要先接住再交给 UI
    this.acceptIntent(want);

    // 多端：悬停预览开关（只用于没有折叠屏设备时把悬停布局渲染出来自检，正常启动不命中）
    applyLayoutPreview(want.parameters);

    // 语音探测开关（同样只在自检时命中，正常启动不会跑）。
    // 为什么延后 4 秒：权限弹窗要挂在已经建好的窗口上，onCreate 阶段窗口还没出来。
    const probe: Object | undefined = want.parameters === undefined ? undefined : want.parameters['lh_mic_probe'];
    if (probe !== undefined && probe !== null) {
      Log.i('语音探测：收到自检开关，4 秒后开始录音');
      const ctx: common.UIAbilityContext = this.context;
      setTimeout(() => {
        VoiceMemo.probe(ctx);
      }, 4000);
    }

    // 语音识别链路自检：把 rawfile 里的测试音频当麦克风数据喂给引擎，看能不能出字。
    // 这条路径不用麦克风、不弹权限，所以是**无人值守**可跑的最强证据 ——
    // 能过就说明 createEngine/startListening/writeAudio/onResult 四步都通。
    const voice: Object | undefined =
      want.parameters === undefined ? undefined : want.parameters['lh_voice_dict'];
    if (voice !== undefined && voice !== null) {
      Log.i('语音自检：收到开关，4 秒后跑识别链路');
      const ctx: common.UIAbilityContext = this.context;
      setTimeout(() => {
        VoiceMemo.selfTestClip(ctx, 'voice_clip.pcm', ['面试', '简历', '成绩单'])
          .catch((err: Error) => {
            Log.e(`语音自检异常：${err.message}`);
          });
      }, 4000);
    }
  }

  /**
   * 应用已在运行时被卡片再次拉起（用户没杀掉后台，直接点桌面卡片）。
   * ⚠ 这条回调不写，卡片就只能在"冷启动"时跳对页面 ——
   *   而真实使用场景里绝大多数点击都是热启动，等于功能只在演示时成立。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.acceptIntent(want);
    // 自检开关同样要在热启动路径上生效：`aa start --ps ...` 打在活着的进程上是走
    // onNewWant 而不是 onCreate，这里不接一次，"先起应用再带参拉起"就完全无效。
    applyLayoutPreview(want.parameters);
  }

  /** 把卡片带过来的 lh_target 转成导航意图交给 UI（UI 还没起来也不会丢） */
  private acceptIntent(want: Want): void {
    const target: string = navTargetOf(want.parameters);
    if (target.length === 0) {
      return;
    }
    pushNavTarget(target);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    this.syncSentinel();
  }

  /**
   * 节奏哨兵：每次回到前台评估一次提醒、并对齐系统排程。
   *
   * 为什么放在 onForeground 而不是 onCreate：
   *   onCreate 只在冷启动跑一次，而"跨天""用户改了系统时间""上次没授权这次授权了"
   *   这些情况都发生在应用一直活着的时候。onForeground 每次回前台都会触发，覆盖面刚好。
   *
   * 不 await：都是跨进程调用，不该让用户等 —— 两个函数内部各自有互斥/去重，
   * 连点几次也不会重复发或重复排。
   */
  private syncSentinel(): void {
    // ① 本地通知：真正可用的主通道。用户回到应用就当场把该发的发掉，
    //    不必等卡片那条 30 分钟的心跳。
    Sentinel.evaluate(this.context, '前台')
      .then((n: number) => {
        Log.i(`哨兵(前台) 本地提醒 ${n} 条`);
      })
      .catch((err: Error) => {
        Log.e(`哨兵(前台) 评估异常：${err.message}`);
      });

    // ② 系统代理提醒：精度最高，但有管控配额（普通应用默认 0 条）。
    //    排不进去会如实降级并在 UI 上说明，不影响 ①。
    Sentinel.sync(this.context)
      .then((rep: SentinelReport) => {
        Log.i(`哨兵(前台) ${rep.message}`);
      })
      .catch((err: Error) => {
        Log.e(`哨兵(前台) 排程异常：${err.message}`);
      });
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}