# -*- coding: utf-8 -*-
"""JD 岗位匹配验收：菜单入口 → 面板 → 分析结果

为什么先重装：演示数据里内置的 JD 是这次新加的字段，
旧库里的记录没有它 —— 不重装的话面板打开是空的，会误判成"功能没做出来"。
   ① 菜单里出现「JD 匹配分析」并能打开面板
   ② 面板带出这条记录已存的 JD（不用手输中文，也顺便验证了 JD 落库）
   ③ 点分析后真的出结果：匹配度 / 技能差距 / 来源标注
"""
import sys
import os
import re
import time
import subprocess

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_widget as vw  # noqa: E402

BUNDLE = "com.wuit.lighthouse"
HAP = r"D:\work\DevEcoStudioProject\Lighthouse\entry\build\default\outputs\default\entry-default-signed.hap"
HDC = getattr(vw, "HDC", r"D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe")

OK = 0
FAIL = 0


def check(cond, good, bad):
    global OK, FAIL
    if cond:
        OK += 1
        print(f"  ✓ {good}")
    else:
        FAIL += 1
        print(f"  ✗ {bad}")
    return bool(cond)


def hdc(*args):
    return subprocess.run([HDC, *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace")


def rect(lay, text, exact=True):
    hits = []
    stack = [lay]
    while stack:
        n = stack.pop()
        a = n.get("attributes", {})
        t = (a.get("text") or "").strip()
        hit = (t == text) if exact else (text in t)
        if hit and a.get("bounds"):
            nums = [int(v) for v in re.findall(r"-?\d+", a["bounds"])]
            if len(nums) == 4:
                hits.append(nums)
        for c in (n.get("children") or []):
            stack.append(c)
    if not hits:
        return None
    hits.sort(key=lambda b: (b[1], b[0]))
    return hits[0]


def tap(lay, text, exact=True):
    b = rect(lay, text, exact)
    if b is None:
        return False
    vw.shell(f"uinput -T -c {(b[0] + b[2]) // 2} {(b[1] + b[3]) // 2}")
    return True


def long_press(lay, text, ms=900):
    b = rect(lay, text, False)
    if b is None:
        return False
    x = (b[0] + b[2]) // 2
    y = (b[1] + b[3]) // 2
    vw.shell(f"uinput -T -m {x} {y} {x} {y} {ms}")
    return True


def swipe_up():
    vw.shell("uinput -T -m 628 2000 628 1100 400")
    time.sleep(1.2)


def tap_scrolling(text, tries=6, exact=True):
    """页面可能要滚动才露出来 —— 每滚一屏找一次"""
    for i in range(tries):
        lay = vw.dump_layout(f"jd_sc{i}")
        if tap(lay, text, exact):
            return True
        swipe_up()
    return False


def main():
    print("=" * 62)
    print("JD 岗位匹配验收")
    print("=" * 62)

    # ── ① 重装（旧库里没有内置 JD，必须清一次）
    print("\n-- ① 重装应用（让演示数据带上内置 JD） --")
    vw.shell(f"aa force-stop {BUNDLE}")
    time.sleep(1)
    u = hdc("uninstall", BUNDLE)
    print(f"  uninstall: {(u.stdout or '').strip()[:60]}")
    time.sleep(2)
    i = hdc("install", HAP)
    print(f"  install: {(i.stdout or '').strip()[:80]}")
    time.sleep(2)

    vw.shell(f"aa start -a EntryAbility -b {BUNDLE}")
    time.sleep(8)

    # ── ② 载入演示数据
    print("\n-- ② 载入演示数据 --")
    lay = vw.dump_layout("jd0")
    if not tap(lay, "我的"):
        check(False, "", "点不到「我的」Tab")
        return
    time.sleep(3)
    if not tap_scrolling("载入演示数据"):
        check(False, "", "找不到「载入演示数据」按钮")
        return
    time.sleep(4)
    print("  已点「载入演示数据」")

    # ── ③ 回快记页，长按「鼎捷软件」（演示数据里唯一带 JD 的那条）
    print("\n-- ③ 长按记录卡片，打开菜单 --")
    lay = vw.dump_layout("jd1")
    tap(lay, "快记")
    time.sleep(3)

    found = False
    for i in range(5):
        lay = vw.dump_layout(f"jd_card{i}")
        if rect(lay, "鼎捷软件") is not None:
            found = True
            break
        swipe_up()
    if not found:
        check(False, "", "列表里找不到「鼎捷软件」")
        return

    long_press(lay, "鼎捷软件")
    time.sleep(2.5)
    lay = vw.dump_layout("jd_menu")
    vw.shot("jd_1_menu.jpeg")
    ok = check(rect(lay, "JD 匹配分析") is not None,
               "卡片菜单里出现「JD 匹配分析」",
               "菜单里没有「JD 匹配分析」")
    if not ok:
        return

    # ── ④ 打开面板
    print("\n-- ④ 打开岗位匹配面板 --")
    tap(lay, "JD 匹配分析")
    time.sleep(3)
    lay = vw.dump_layout("jd_panel")
    vw.shot("jd_2_panel.jpeg")
    txt = " ".join(vw.texts_of(lay))
    check("岗位匹配" in txt, "面板打开（出现「岗位匹配」标题）", "面板没打开")
    # JD 应该已经带出来了：正文里的句子能在控件树里读到
    check("岗位职责" in txt or "任职要求" in txt,
          "演示数据的 JD 已带出到输入框（JD 落库链路通了）",
          "输入框是空的 —— JD 没带出来")
    check("技能底牌" in txt, "面板里有「我的技能底牌」区", "找不到技能底牌区")

    # ── ⑤ 开始分析
    print("\n-- ⑤ 点「开始分析」 --")
    if not tap(lay, "开始分析"):
        check(False, "", "找不到「开始分析」按钮")
        return
    print("  已点击，等服务端返回（最多等 25 秒）…")

    has = False
    for i in range(10):
        time.sleep(2.5)
        lay = vw.dump_layout(f"jd_res{i}")
        t = " ".join(vw.texts_of(lay))
        if "岗位匹配度" in t:
            has = True
            break
    vw.shot("jd_3_result.jpeg")
    if not check(has, "分析出结果（出现「岗位匹配度」）", "等不到分析结果"):
        return

    txt = " ".join(vw.texts_of(lay))
    # 匹配度分数：单独一个纯数字文本节点
    score = None
    for t in vw.texts_of(lay):
        s = t.strip()
        if s.isdigit() and 0 <= int(s) <= 100:
            score = int(s)
            break
    check(score is not None, f"读得到匹配度分数（{score}）", "读不到匹配度分数")

    check("技能差距" in txt, "出现「技能差距」清单", "没有技能差距清单")

    # ⚠ 断言必须把「部分」也算上。
    #   第一版只数「具备 / 缺失」，结果这份真实 JD 的结论以「部分」为主
    #   （底牌说"用过 Redis"但没说懂原理 → 模型判"部分"），只数到 1 个，
    #   差点把渲染正常的清单判成没渲染。三类状态之和才是"清单渲染了几条"。
    def state_count(t):
        return t.count("具备") + t.count("缺失") + t.count("部分")

    n0 = state_count(txt)
    # 清单有 12 项，一屏放不下 —— 滚到底再数一次，否则统计的是"屏幕上的条数"
    for _ in range(3):
        swipe_up()
    lay = vw.dump_layout("jd_res_full")
    vw.shot("jd_4_result_scrolled.jpeg")
    txt2 = " ".join(vw.texts_of(lay))
    n = max(n0, state_count(txt2))
    check(n >= 3,
          f"技能项渲染出来了（三类状态共 {n} 处）",
          f"技能项太少（共 {n} 处）—— 清单可能没渲染")

    # 备考动作也该有（本地引擎与云端都会给）
    check("先补这几块" in txt2 or "先补这几块" in txt,
          "出现「先补这几块」备考清单",
          "没有备考清单")

    full = txt + " " + txt2
    cloud = "云端" in full
    local = "本地" in full
    check(cloud or local, f"标注了结论来源（{'云端模型' if cloud else '本地引擎'}）",
          "没有标注来源 —— 这是本产品的一条原则，不能漏")

    # ── ⑥ 关掉再打开，结论应该还在
    print("\n-- ⑥ 关掉再打开：结论应自动恢复（验证落库） --")
    lay = vw.dump_layout("jd_bk")
    # ⚠ 按钮文案是「‹ 返回」（带一个左尖括号），精确匹配 "返回" 永远找不到。
    #   第一版就栽在这：⑥ 直接因为"找不到返回按钮"退出，前面全绿也被打断。
    if not tap(lay, "返回", exact=False):
        check(False, "", "找不到「返回」按钮")
        return
    time.sleep(2.5)

    # 先滚回列表顶部，再找那条记录（返回后停留的滚动位置不确定）
    for _ in range(4):
        vw.shell("uinput -T -m 628 1100 628 2000 400")
        time.sleep(0.8)

    found = False
    for i in range(6):
        lay = vw.dump_layout(f"jd_bk{i}")
        if rect(lay, "鼎捷软件") is not None:
            found = True
            break
        swipe_up()
    if not found:
        check(False, "", "返回后列表里找不到「鼎捷软件」")
        return

    long_press(lay, "鼎捷软件")
    time.sleep(2.5)
    lay = vw.dump_layout("jd_menu2")
    tap(lay, "JD 匹配分析")
    time.sleep(4.5)  # 读缓存是异步的，给足时间
    lay = vw.dump_layout("jd_reopen")
    vw.shot("jd_5_reopened.jpeg")
    t = " ".join(vw.texts_of(lay))
    check("岗位匹配度" in t,
          "重开面板时上一次的结论自动恢复了（不用重新烧一次 token）",
          "重开后面板是空的 —— 结果没有落库")

    print(f"\n{'=' * 62}")
    print(f"结果：{OK} 通过 / {FAIL} 失败")
    print(f"截图：tools/_shots/jd_*.jpeg")
    print(f"{'=' * 62}")


if __name__ == "__main__":
    main()
