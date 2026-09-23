# -*- coding: utf-8 -*-
"""灯塔 · 语音速记「接线」验收（界面层）

和 verify_voice.py 的分工
------------------------
  verify_voice.py     识别本身能不能用 —— 把一段已知内容的音频喂给引擎，看能不能出正确的字。
                      这条路可复现、可自动化，是"引擎可用"的证据。
  verify_voice_ui.py  界面接线对不对 —— 按钮状态机、权限申请、麦克风是否真的在采、
                      识别结果能不能存进备注再读回来。

为什么必须分成两个脚本
----------------------
界面这条路径没法自动"说话"：模拟器麦克风采的是宿主机环境音，脚本控制不了它出什么内容。
所以这里**只断言链路接上了、且状态如实反馈**，不断言"识别出了哪几个字"（那是上一条脚本的事）。
硬要在这一层断言识别内容，只会写出一个时灵时不灵的用例。

⚠ 一个已经踩过的坑：切 Tab 会把 @State 重建，筛选条件之类的会丢。
  本脚本全程不切 Tab（载入演示数据那一步除外，那是必须切的）。
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
HAP = r"D:\work\DevEcoStudioProject\Lighthouse\entry\build\default\outputs\default\entry-default-signed.hap"

# 演示数据里带备注的那条（见 DemoData.DEMO_APPS）
DEMO_NOTE_OWNER = "精测电子"
DEMO_NOTE_PART = "HR 说一面过了"

# 用来验"备注能存回来"的一条**本来没有备注**的记录，避开"怎么清空已有备注"这个麻烦。
# ⚠ 挑演示数据里靠前的记录：这个模拟器上长距离滚动不可靠（连续 7 次 dump 内容一样），
#   "滚到第 7 条"这种指望不住，断言尽量只用**当前屏第一张卡**能覆盖到的。
BLANK_OWNER = "光庭信息"
NEW_NOTE = "测试备注ABC"

# 权限弹窗的正向文案各版本会变，按候选词找
PERM_WORDS = ("允许", "使用应用时允许", "仅使用时允许", "始终允许")


def hdc(*args):
    return subprocess.run([vw.HDC, *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace")


def grant_permission(timeout=15):
    """等权限弹窗并点「允许」。返回点中的文案，没弹返回 None。

    ⚠ 必须**精确匹配**「允许」。弹窗标题是「允许"灯塔"访问你的麦克风？」，
      用包含匹配会先命中标题文字（按 y 排序它在最上面），
      点下去什么也不会发生，弹窗照旧挂着 —— 第一版就这么卡住的，
      报出来的现象还是"没进入录制态"，看着像功能坏了。
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        lay = vw.dump_layout("vu_perm")
        for w in PERM_WORDS:
            h = vf.hit(lay, w, True)
            if h:
                vf.tap_rect(h[0])
                return w
        time.sleep(1.5)
    return None


def screen_texts(tag):
    return " ".join(vw.texts_of(vw.dump_layout(tag)))


def find_card(company, tries=6):
    last = None
    for i in range(tries):
        lay = vw.dump_layout(f"vu_card{i}")
        last = lay
        if vf.rect(lay, company) is not None:
            return lay
        vf.swipe_up()
    if last is not None:
        print(f"    （滚了 {tries} 屏没看到「{company}」，最后一屏："
              f"{' '.join(vw.texts_of(last))[:150]}）")
    return None


def tap_scrolling(text, tries=6):
    """「载入演示数据」在「我的」页要靠下，得滚一滚才露出来"""
    for i in range(tries):
        lay = vw.dump_layout(f"vu_sc{i}")
        if vf.tap(lay, text, exact=False):
            return True
        vf.swipe_up()
    return False


def long_press(lay, text, ms=1200):
    b = vf.rect(lay, text)
    if b is None:
        return False
    cx, cy = (b[0] + b[2]) // 2, (b[1] + b[3]) // 2
    vw.shell(f"uinput -T -m {cx} {cy} {cx} {cy} {ms}")
    return True


def main():
    print("=" * 62)
    print("语音速记接线验收")
    print("=" * 62)

    if not os.path.isfile(HAP):
        print(f"✗ 找不到产物 {HAP}，先跑 build.sh")
        return 2

    # ── ① 重装 + 载入演示数据（demo 的 note 是这次新加的，旧库没有）
    # 「载入演示数据」已搬进设置页 —— 走 lh_load_demo 开关，别去界面上找按钮。
    print("\n-- ① 重装并载入演示数据 --")
    vw.shell(f"aa force-stop {BUNDLE}")
    time.sleep(1)
    hdc("uninstall", BUNDLE)
    time.sleep(2)
    hdc("install", HAP)
    time.sleep(2)
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1 --pi lh_load_demo 1")
    time.sleep(10)
    print("  已载入演示数据（lh_load_demo 开关）")

    vf.tap(vw.dump_layout("vu1"), "快记")
    time.sleep(3)

    # ── ② 备注在卡片上是可见的（语音写进来的东西得能被人看到，否则录了等于没录）
    print("\n-- ② 卡片渲染备注 --")
    lay = find_card(DEMO_NOTE_OWNER)
    vw.shot("vu_1_note_card.jpeg")
    # ⚠ collect_texts 返回的是**一个拼接好的字符串**（不是列表），
    #   而且它会自己滚列表 —— 用完必须 scroll_to_top 复位
    all_txt = vf.collect_texts(rounds=3) if lay is not None else ""
    vw.check(DEMO_NOTE_PART in all_txt,
             f"「{DEMO_NOTE_OWNER}」卡片上渲染出了备注（「{DEMO_NOTE_PART}…」）",
             "卡片上没看到备注 —— 备注渲染没接上")

    # ── ③ 表单里的备注框 + 语音入口
    print("\n-- ③ 表单里的备注与语音入口 --")
    vf.scroll_to_top()
    t = screen_texts("vu_form")
    vw.shot("vu_2_form.jpeg")
    vw.check("备注" in t, "表单里有「备注」区", "表单里找不到「备注」")
    vw.check("语音" in t, "备注旁有「语音」按钮", "找不到语音按钮")

    # ── ④ 点语音 → 权限 → 状态机
    print("\n-- ④ 点语音：权限 + 进入录制态 --")
    vw.shell("hilog -r")   # 只留这一次的日志，避免上一次的"开始速记"混进来
    lay = vw.dump_layout("vu_pre_dict")
    if not vf.tap(lay, "语音"):
        vw.check(False, "", "点不到「语音」按钮")
        return 2
    time.sleep(2)

    perm = grant_permission()
    if perm:
        print(f"  权限弹窗已点「{perm}」")
        time.sleep(2)
    else:
        print("  没等到权限弹窗（可能之前已授权）")

    # 弹窗没关掉的话，后面每条断言都在对着弹窗说事 —— 先确认它真的消失了
    gone = False
    for i in range(8):
        if "访问你的麦克风" not in screen_texts(f"vu_pg{i}"):
            gone = True
            break
        time.sleep(1)
    vw.check(gone, "麦克风权限弹窗已关闭（授权生效）",
             "权限弹窗还挂着 —— 后面的用例都不作数")

    lay = vw.dump_layout("vu_listening")
    vw.shot("vu_3_listening.jpeg")
    t = screen_texts("vu_listening")
    vw.check("停止" in t or "在录" in t,
             "进入录制态：按钮变成「停止 / 在录」",
             f"点语音后没进入录制态，当前屏：{t[:160]}")

    # ── ⑤ 麦克风真的在采（拿 hilog 当证据，不看界面）
    print("\n-- ⑤ 麦克风与引擎确实起来了 --")
    logs = vw.shell("hilog -x 2>/dev/null | grep -E '语音：' | tail -12")
    print("   " + "\n   ".join([l for l in logs.splitlines() if l.strip()][-6:]))
    vw.check("开始速记" in logs,
             "hilog 有「开始速记」—— 引擎与采集都真的起来了",
             "hilog 没有「开始速记」—— 只改了界面状态，底层没动")

    # ── ⑥ 停下来：状态要回到未录，且不能卡在「出字中」
    print("\n-- ⑥ 停止：状态收得回来 --")
    time.sleep(3)
    lay = vw.dump_layout("vu_stop")
    if vf.rect(lay, "停止") is not None:
        vf.tap(lay, "停止")
    else:
        vf.tap(lay, "在录")
    # 轮询等它回到"语音"（模拟器上引擎收尾慢，给足 12 秒）
    back = False
    for i in range(12):
        time.sleep(1)
        t = screen_texts(f"vu_back{i}")
        if "语音" in t and "在录" not in t and "出字中" not in t:
            back = True
            break
    vw.shot("vu_4_after_stop.jpeg")
    vw.check(back,
             "点停止后状态收回「语音」（没有卡在「出字中」）",
             "停止后状态没回来 —— 按钮卡住了，用户会以为应用死了")

    end = vw.shell("hilog -x 2>/dev/null | grep -E '本次速记结束' | tail -3")
    vw.check("本次速记结束" in end,
             "hilog 有「本次速记结束」—— 会话正常收尾（出了字或如实反馈没听清）",
             "hilog 没有「本次速记结束」—— 会话没收尾，资源可能没释放")

    # ── ⑦ 备注能存进去、再读回来（走一遍完整的写读链）
    print("\n-- ⑦ 备注写入 → 保存 → 卡片显示 → 编辑带回 --")
    vf.scroll_to_top()
    lay = find_card(BLANK_OWNER)
    if lay is None:
        vw.check(False, "", f"列表里找不到「{BLANK_OWNER}」")
        return 1
    long_press(lay, BLANK_OWNER)
    time.sleep(2.5)
    lay = vw.dump_layout("vu_menu")
    if not vf.tap(lay, "编辑这条"):
        vw.check(False, "", "菜单里没有「编辑这条」")
        return 1
    time.sleep(3)

    # 点备注框（「备注」标签下面那个输入区），再打字
    vf.scroll_to_top()
    lay = vw.dump_layout("vu_edit")
    nb = vf.rect(lay, "备注")
    if nb is None:
        vw.check(False, "", "编辑态里找不到「备注」标签")
        return 1
    # 输入框在标签正下方：往下偏 40px 点进去
    vw.shell(f"uinput -T -c {(nb[0] + nb[2]) // 2} {nb[3] + 40}")
    time.sleep(1.5)
    vw.shell(f"uitest uiInput inputText 628 {nb[3] + 40} {NEW_NOTE}")
    time.sleep(2)
    vf.hide_keyboard()
    vw.shot("vu_5_typed.jpeg")

    lay = vw.dump_layout("vu_save")
    if not vf.tap(lay, "保存修改"):
        vw.check(False, "", "找不到「保存修改」按钮")
        return 1
    time.sleep(3)

    found = False
    if find_card(BLANK_OWNER) is not None:
        all_txt = vf.collect_texts(rounds=3)
        found = NEW_NOTE in all_txt
    vw.shot("vu_6_saved.jpeg")
    vw.check(found,
             f"备注保存成功，「{BLANK_OWNER}」卡片上显示「{NEW_NOTE}」",
             "保存后备注没出现在卡片上 —— 备注没写进库或没渲染")

    # 再打开编辑，看备注有没有带回来
    vf.scroll_to_top()
    lay = find_card(BLANK_OWNER)
    if lay is not None:
        long_press(lay, BLANK_OWNER)
    time.sleep(2.5)
    lay = vw.dump_layout("vu_menu2")
    if vf.tap(lay, "编辑这条"):
        time.sleep(3)
        t = screen_texts("vu_reopen")
        vw.shot("vu_7_reopen.jpeg")
        vw.check(NEW_NOTE in t,
                 "再次编辑时备注被带回来了（库里的值读得出来）",
                 "编辑态里看不到刚才存的备注 —— 读回链路断了")
    else:
        vw.check(False, "", "第二次打开菜单失败")

    ok = sum(1 for r in vw.RESULTS if r)
    bad = len(vw.RESULTS) - ok
    print(f"\n{'=' * 46}\n结果：通过 {ok} / {len(vw.RESULTS)}，失败 {bad}\n{'=' * 46}")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
