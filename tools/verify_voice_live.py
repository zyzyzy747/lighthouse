# -*- coding: utf-8 -*-
"""灯塔 · 语音速记「真麦克风」实测（辅助验证，不是回归用例）

它验的和另外两个脚本都不一样
----------------------------
  verify_voice.py     喂文件 → 证明**识别引擎**能用（可复现，但绕过麦克风）
  verify_voice_ui.py  点按钮 → 证明**界面接线**对（可复现，但没法自动说话）
  本脚本              播声音 → 证明**真麦克风 + 识别 + 写进备注框**整条路走得通

为什么它不能当回归用例
----------------------
它依赖物理环境：声音从宿主机扬声器出来、经空气被模拟器桥接的麦克风采到。
音量太小、戴了耳机、房间太吵，都会失败 —— 而**失败不代表功能坏了**。
所以它的结论要人工看，别写进 CI。

⚠ 跑之前：把系统音量开到 60% 以上，**别戴耳机**（耳机的话声音进不了麦克风）。
"""
import os
import re
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_widget as vw  # noqa: E402
import verify_filter as vf  # noqa: E402

BUNDLE = "com.wuit.lighthouse"
HERE = os.path.dirname(os.path.abspath(__file__))
WAV = os.path.join(HERE, "_shots", "voice_clip.wav")

# 与 make_voice_clip.py 的 PHRASE 一致
PHRASE = "明天下午两点面试，记得带上简历和成绩单"
EXPECT = ["面试", "简历", "成绩单"]


def play_async(path):
    """边播边继续跑脚本，别阻塞 —— 应用那边还在录。

    winsound 是 Python 标准库，不需要 COM 也不需要装包
    （这台机器上 PowerShell 的 COM 和 Add-Type 都被安全策略拦了）。
    """
    import winsound
    winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC)


def note_text(lay):
    """只取「备注」框里的文字。

    ⚠ 千万别拿全屏文字做判断：表单里的状态 chip 就写着「面试」「笔试」，
      全屏匹配会把它们当成识别结果 —— 第一版就是这么"通过"的，
      显示"命中 1/3"，其实备注框里一个字都没有。
    """
    nb = vf.rect(lay, "备注")
    if nb is None:
        return ""
    out = []
    for n in vf.walk(lay):
        a = n.get("attributes", {})
        t = (a.get("text") or "").strip()
        b = vf.bounds(a)
        # 备注框就在「备注」标签正下方那块（72px 高，留点余量）
        if t and b and nb[3] <= b[1] <= nb[3] + 90:
            out.append(t)
    return " ".join(out)


def main():
    if not os.path.isfile(WAV):
        print(f"✗ 没有测试音频 {WAV}，先跑 make_voice_clip.py")
        return 2

    print("=" * 62)
    print("语音速记 · 真麦克风实测")
    print("=" * 62)
    print("⚠ 确认系统音量 ≥60% 且没戴耳机，3 秒后开始…")
    time.sleep(3)

    # ① 回到快记页最上面
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE}")
    time.sleep(6)
    vf.scroll_to_top()
    if not vf.tap(vw.dump_layout("vl0"), "快记"):
        vf.tap(vw.dump_layout("vl0b"), "快记")
        time.sleep(3)
    time.sleep(2)

    # ② 点语音开录
    print("\n-- 开始录音 --")
    vw.shell("hilog -r")
    lay = vw.dump_layout("vl1")
    if not vf.tap(lay, "语音"):
        print("✗ 点不到「语音」按钮")
        return 2

    # ⚠ 模拟器的麦克风要 ~1.8 秒才真正出数据（express_mic 起流比应用请求晚），
    #   这段时间说话是录不进去的，必须先等再播
    print("  等 3 秒让模拟器麦克风起流…")
    time.sleep(3)

    # ③ 播声音
    print(f"  播放：{PHRASE}")
    play_async(WAV)

    # ④ 录完再停（音频 6 秒，多等一点免得尾巴被切）
    time.sleep(9)
    lay = vw.dump_layout("vl2")
    if vf.rect(lay, "停止") is not None:
        vf.tap(lay, "停止")
    elif vf.rect(lay, "在录") is not None:
        vf.tap(lay, "在录")
    else:
        print("  ！找不到停止按钮，可能已经自己结束了")

    print("  等引擎出最终结果…")
    time.sleep(10)

    # ⑤ 看结果：先看 hilog（那里有原始文本），再看备注框有没有写进去
    raw = vw.shell("hilog -x 2>/dev/null | grep -E '语音：' | tail -30")
    lines = [l for l in raw.splitlines() if l.strip()]
    print("\n-- hilog --")
    for l in lines[-8:]:
        print("   ", l.split("Lighthouse: ", 1)[-1])

    end_log = ""
    for l in lines:
        if "本次速记结束" in l:
            end_log = l.split("Lighthouse: ", 1)[-1]
    print(f"\n  收尾日志：{end_log if end_log else '(没有)'}")

    lay = vw.dump_layout("vl3")
    vw.shot("vl_1_live.jpeg")
    note = note_text(lay)
    print(f"  备注框里现在的内容：「{note}」")

    # 麦克风电平是**最有用的一条诊断**：它能区分
    #   "根本没采到声音"（环境问题，不是功能问题）和 "采到了却识别不出"（才是真问题）。
    peak = 0
    m = re.search(r"峰值\s*(\d+)", end_log)
    if m:
        peak = int(m.group(1))
    print(f"  麦克风峰值：{peak}（安静房间底噪约 300，正常说话 > 2000）")

    hit = [w for w in EXPECT if w in note]
    print("\n-- 结论 --")
    print(f"  备注框里出现的台词关键词：{hit} / {EXPECT}")
    if len(hit) >= 2:
        print("  ✓ 真麦克风 → 识别 → 写进备注框，整条路通了")
        print("    （截图 vl_1_live.jpeg 里备注框应该就是刚才那句话的转写）")
        return 0
    if peak < 500:
        print("  ⚠ 这次**基本没采到声音**（峰值接近底噪）⇒ 是环境问题，不是功能问题：")
        print("     · 系统音量太小 / 静音")
        print("     · 戴着耳机 —— 声音根本到不了麦克风")
        print("     · 模拟器的音频可能被系统回声消除（AEC）当成回声抹掉了")
        print("    调高音量、拔掉耳机再来一次。")
        return 1
    if len(hit) == 1:
        print("  ~ 采到声音了但只命中一个词，识别质量一般（音量偏低或环境噪声）。")
        print("    功能本身是通的 —— verify_voice.py 已证明引擎与喂音频管线没问题。")
        return 0
    print("  ✗ 采到声音了（峰值足够）却没出字 —— 这个值得查，把日志留下来。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
