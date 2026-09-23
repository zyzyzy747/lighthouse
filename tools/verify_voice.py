# -*- coding: utf-8 -*-
"""灯塔 · 语音速记验收（端侧离线识别链路）

验的是什么
----------
「端侧离线语音速记」这句话要成立，得证明三件事，而且**都不依赖人工说话**：

  ① 设备能起离线识别引擎
     这是最大的不确定项，先验它。
     ⚠ 别把 1002200001 直接当成"这台机器没装离线语音模型" —— 那是错的诊断。
       该码的官方描述只有一句 "Create engine failed"，真正的原因在 message 里；
       实测 2026-09-21 那条是 `asr engine init failed with other process has initialized`，
       即**引擎被别的进程占着**（系统输入法），70ms 后就释放了。见 ⑦。

  ② 音频喂进引擎的管线是通的
     writeAudio 只收 640/1280 字节的整块，采集回调给的长度是任意的，
     中间必须自己攒块；喂快了 VAD 又拿不到正常时间轴。这两处都容易"不报错但不工作"。

  ③ 出的字**确实来自音频内容**
     只断言"有输出"是不够的 —— 随机噪声也可能出一个字。
     所以用固定台词的测试音频，断言识别结果里命中特定词。

⚠ 本脚本**验不到**的一件事：引擎被别的进程占着时的"重试自愈"。
  单例冲突是真故障（用户 2026-09-21 截图报过，实机日志里是
  `other process has initialized`，占用方 `com.huawei.hmos.inputmethod`，
  且引擎在我们失败后约 70ms 就释放了），`VoiceMemo` 里也加了重试；
  但**在这个环境里造不出这个冲突**：
    · 同进程重复 createEngine 会直接命中缓存（`Using cached ASR engine`），
      所以"自己占自己"的写法从构造上就验不到跨进程冲突；
    · 触发方（系统输入法的语音输入）要**长按**键盘麦克风键，
      而 IME 窗口不向 `dumpLayout` 暴露键位，点不准也控不住时长。
  已知的手工验证法：点输入框弹键盘 → 长按键盘上的麦克风键 → 立刻点应用里的「语音」。
  期望：最多看到一句「引擎被占用，正在重试…」，然后正常进入录制态。

怎么做到无人值守
----------------
引擎的音频是应用自己喂的（`writeAudio`），所以把 rawfile 里一段已知内容的
16k/单声道/16bit 裸 PCM 当成麦克风数据灌进去，整条链路就能自动化验证。
音频由 `make_voice_clip.py` 用系统 TTS 合成，台词固定（见 PHRASE）。

⚠ 这条路径**不经过麦克风**。所以它 PASS 只说明"识别能用"，
   "麦克风采集能用"是另一回事，由 VoiceMemo.probe 单独验（见 verify 日志里的「语音探测」）。
   两件事都过，语音速记才算真的可用。

跑法：python verify_voice.py
"""
import os
import re
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_widget as vw  # noqa: E402

BUNDLE = "com.wuit.lighthouse"
ABILITY = "EntryAbility"
HAP_DIR = r"D:\work\DevEcoStudioProject\Lighthouse\entry\build\default\outputs\default"
HAP = os.path.join(HAP_DIR, "entry-default-signed.hap")

# 与 make_voice_clip.py 的 PHRASE 一致；改台词必须同时改这里
PHRASE = "明天下午两点面试，记得带上简历和成绩单"
EXPECT_WORDS = ["面试", "简历", "成绩单"]

# 音频长度由脚本实测填（verify_voice 跑起来会自己核对，对不上直接报出来）
CLIP_BYTES = 192162


def install():
    print("-- 安装（rawfile 里带了测试音频，必须重装）--")
    subprocess.run([vw.HDC, "install", "-r", HAP], cwd=HAP_DIR,
                   capture_output=True, timeout=240)
    if not os.path.isfile(HAP):
        print(f"  ✗ 产物不存在：{HAP}")
        return False
    print(f"  ✓ 已安装 {os.path.basename(HAP)}")
    return True


def main():
    if not os.path.isfile(HAP):
        print(f"✗ 找不到产物 {HAP}，先跑 build.sh")
        return 2
    if not install():
        return 2

    print("\n-- 清日志 → 带自检开关冷启动 --")
    vw.shell("hilog -r")
    vw.shell(f"aa force-stop {BUNDLE}")
    time.sleep(2)
    vw.shell(f"aa start -a {ABILITY} -b {BUNDLE} --pi lh_autologin 1 --ps lh_voice_dict 1")
    # ⚠ 原来写死 `sleep(34)`。13 套验收连着跑时模拟器负载高、ASR 收尾明显变慢，
    #   34 秒会在**最终结果到达之前**就收网 ⇒ 假红（实测 2026-09-22：汇总之后
    #   才打出 `isFinal=true "明天下午2点面试…"`，字其实识对了）。
    #   改成**轮询**「自检汇总」那行日志：出现即收网，正常情况比写死更快；
    #   等满 120 秒还没有才认超时。应用侧同时把预算提到 45 秒，两边一起放宽。
    print("  等「语音自检汇总」那行日志（最多 120 秒，出现即继续）…")
    deadline = time.time() + 120
    got_summary = False
    while time.time() < deadline:
        probe = vw.shell("hilog -x 2>/dev/null | grep '语音自检汇总' | tail -3")
        if "语音自检汇总" in probe:
            got_summary = True
            print("    ✓ 自检汇总已出现，收网")
            break
        time.sleep(3)
    if not got_summary:
        print("    ⚠ 120 秒内没等到自检汇总 —— 按实际拿到的日志判定（下面会看到差在哪一步）")

    raw = vw.shell("hilog -x 2>/dev/null | grep -E '语音自检' | tail -80")
    lines = [l.split("Lighthouse", 1)[-1].lstrip(": ") if "Lighthouse" in l else l
             for l in raw.splitlines() if l.strip()]
    print("\n-- hilog 里的自检日志 --")
    for l in lines:
        print("   ", l)

    if not lines:
        print("\n✗ 一条自检日志都没有 —— 开关没生效或应用没起来")
        return 2

    joined = "\n".join(lines)

    def has(s):
        return s in joined

    def check(cond, ok_msg, bad_msg):
        vw.check(cond, ok_msg, bad_msg)

    print("\n-- 断言 --")
    # ① 音频资产
    got_bytes = None
    m = None
    for l in lines:
        if "测试音频" in l:
            m = l
    if m:
        nums = [int(x) for x in re.findall(r"\d+", m)]
        # 形如「voice_clip.pcm，192162 字节 ≈ 6005ms」
        got_bytes = nums[-2] if len(nums) >= 2 else None
    check(got_bytes == CLIP_BYTES,
          f"测试音频读到了：{CLIP_BYTES} 字节",
          f"测试音频字节数不对（读到 {got_bytes}，期望 {CLIP_BYTES}）")

    # ② 引擎
    # ⚠ 要**正向证据**，不能写 `not has("引擎创建失败")`：
    #   前面任何一步提前 return（比如音频没读到），"创建失败"这条日志压根不会出现，
    #   断言就会假阳性通过 —— 第一版正是这么骗过自己的。
    check(has("引擎创建成功"),
          "离线识别引擎创建成功（这台设备装了语音模型）",
          "引擎创建失败 —— 端侧离线语音在这台设备上用不了，文案得改")

    # ③ 会话
    check(has("onStart"),
          "识别会话起来了（onStart 回调到了）",
          "没有 onStart —— startListening 没生效")

    # ④ 音频真的喂进去了、且没报错
    wrote, failed = None, None
    for l in lines:
        if "音频喂完" in l:
            g = re.findall(r"\d+", l)
            if len(g) >= 2:
                wrote, failed = int(g[0]), int(g[1])
    exp = -(-CLIP_BYTES // 1280)   # 向上取整的块数
    check(wrote == exp and failed == 0,
          f"音频全部喂入：{wrote} 块 / 0 失败（期望 {exp} 块）",
          f"喂音频有问题：喂了 {wrote} 块、失败 {failed} 次（期望 {exp} 块 / 0 失败）")

    # ⑤ 出字且沾边
    text = ""
    for l in lines:
        if "识别文本" in l:
            # 形如「语音自检识别文本："明天下午2点面试…。"」
            # ⚠ 冒号在中文全角下会粘在文本前面（"："明天下），必须连冒号带引号一起剥，
            #   否则断言拿到的字符串永远比不上（第一版就吃了这个亏）。
            text = l.split("识别文本", 1)[1].strip().lstrip("：:").strip().strip('"').strip()
    check(len(text) > 0, f"识别出文字：「{text}」", "一个字都没识别出来")

    finals = 0
    for l in lines:
        if "最终结果" in l:
            m2 = re.search(r"最终结果 (\d+) 次", l)
            if m2:
                finals = int(m2.group(1))
    check(finals > 0,
          f"拿到了最终结果（isFinal=true {finals} 次）—— 流式识别正常收尾",
          "没拿到最终结果，只有中间结果 —— 收尾阶段被打断了")

    hit = [w for w in EXPECT_WORDS if w in text]
    check(len(hit) > 0,
          f"识别结果命中测试台词的关键词：{hit}（台词「{PHRASE}」）",
          f"识别结果和台词对不上（期望含 {EXPECT_WORDS}，实际「{text}」）")

    # ⑥ 结论行
    # ⚠ 超时和"识别错"要分开报：TIMEOUT 只说明这台模拟器当时太慢，
    #   跑出来的字往往是对的，让人去查音频/麦克风是南辕北辙。
    if has("语音自检结论：TIMEOUT"):
        check(False,
              "自检结论 PASS",
              "自检结论 TIMEOUT —— 只是没等到最终结果，**不是识别失败**，重跑一次再看")
    else:
        check(has("语音自检结论：PASS"),
              "自检结论 PASS",
              "自检结论不是 PASS（详见上面的日志）")

    ok = sum(1 for r in vw.RESULTS if r)
    bad = len(vw.RESULTS) - ok
    print(f"\n{'=' * 46}\n结果：通过 {ok} / {len(vw.RESULTS)}，失败 {bad}\n{'=' * 46}")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
