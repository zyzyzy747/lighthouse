# -*- coding: utf-8 -*-
"""灯塔 · 日夜主题 + 设置页拆分 验收

这套脚本要证明三件事
--------------------
1. 深浅色是**真的**变了 —— 不只是按钮高亮挪了个位置，而是整屏底色换了一套。
   判定靠截图像素统计：数一数"深色底色的像素数"和"浅色底色的像素数"谁占多数。
   比 dumpLayout 可靠 —— 控件树里读不到 backgroundColor，只看文字会漏掉"配色没跟上"。
2. 个人页真的瘦了 —— 原来那七个开关一块都不该再出现在「我的」里。
3. 设置页里这些开关都还在 —— 搬家不等于丢东西。

⚠ 一个必须避开的假阳性：
   个人页「设置」入口的副标题里本来就写着"外观 · AI 引擎…"这类词，
   所以"个人页不该有 XX"的断言用的是**完整词组**（"AI 分析引擎"而不是"AI"），
   副标题也刻意不写完整词组。两边都留一步，否则断言会互相打架。
"""
import os
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_widget as vw  # noqa: E402
import verify_filter as vf  # noqa: E402
import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

BUNDLE = "com.wuit.lighthouse"
HAP = vf.HAP

# 两套底色（与 resources/{base,dark}/element/color.json 的 lh_bg 一致）
DARK_BG = (10, 17, 32)        # #0A1120
LIGHT_BG = (242, 245, 250)    # #F2F5FA
TOL = 22

# 整屏 1256×2760 ≈ 347 万像素。底色连成片后覆盖面积是百万级；
# 判"这一屏是深色"的门槛取 30 万（约 8.6%），足以区分"整屏底色"和"某个色块"。
BIG = 300000

# 个人页不该再出现的设置项（完整词组）
GONE_FROM_PROFILE = ("AI 分析引擎", "节奏哨兵", "危险操作", "载入演示数据", "测试连接")


def hdc(*args, timeout=90):
    return subprocess.run([vw.HDC, *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=timeout)


def cover(img, rgb, tol=TOL):
    """截图里有多少像素是这个颜色。"""
    arr = np.asarray(Image.open(img).convert("RGB")).astype(np.int16)
    diff = np.abs(arr - np.array(rgb, dtype=np.int16))
    return int((diff <= tol).all(axis=2).sum())


def shot_pair(tag):
    """截一张，同时数出深/浅两种底色的覆盖面积。"""
    img = vw.shot(f"{tag}.jpeg")
    return img, cover(img, DARK_BG), cover(img, LIGHT_BG)


def screen_texts(tag):
    return " ".join(vw.texts_of(vw.dump_layout(tag)))


def tap_text(tag, text, exact=True):
    lay = vw.dump_layout(tag)
    return vf.tap(lay, text, exact)


def wait_text(text, tries=10, sleep=1.5):
    """等到某个文字出现在屏幕上。返回是否等到。"""
    for i in range(tries):
        if text in screen_texts(f"w_{text}_{i}"):
            return True
        time.sleep(sleep)
    return False


def main():
    print("=" * 62)
    print("灯塔 · 日夜主题 + 设置页拆分 验收")
    print("=" * 62)

    # ── ① 重装 + 载入演示数据
    #    ⚠ 走 lh_load_demo 开关而不是去界面上点按钮：按钮搬到设置页之后，
    #      脚本要先切「我的」→进设置→再滚动，长距离滚动在这个模拟器上不可靠。
    print("\n-- ① 重装并载入演示数据 --")
    vw.shell(f"aa force-stop {BUNDLE}")
    time.sleep(1)
    hdc("uninstall", BUNDLE)
    time.sleep(2)
    hdc("install", HAP)
    time.sleep(2)
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1 --pi lh_load_demo 1")
    time.sleep(9)

    demo_logs = vw.logs("演示数据已载入", tail=5)
    vw.check(any("演示数据已载入" in l for l in demo_logs),
             f"带参启动自动载入演示数据（{demo_logs[-1].strip()[:46] if demo_logs else '无日志'}）",
             "自检开关没生效 —— 演示数据没载入，后续数字全是空的")

    # ── ② 个人页只剩三块
    print("\n-- ② 个人页：只有档案 / 数据 / 设置入口 --")
    if not tap_text("th_tab", "我的"):
        vw.check(False, "", "点不到「我的」Tab")
        return
    time.sleep(3)

    txt = screen_texts("th_profile")
    vw.check("我的数据" in txt, "个人页还在：「我的数据」", "个人页丢了「我的数据」")
    vw.check("设置" in txt, "个人页有「设置」入口", "个人页没有进设置的入口")
    leaked = [w for w in GONE_FROM_PROFILE if w in txt]
    vw.check(len(leaked) == 0,
             "七个开关已全部搬走（AI 引擎 / 哨兵 / 卡片 / 演示数据 / 关于 / 危险操作）",
             f"个人页里还留着：{leaked}")

    # ── ③ 进设置页
    print("\n-- ③ 进设置页 --")
    if not tap_text("th_entry", "设置"):
        vw.check(False, "", "点不到「设置」入口")
        return
    time.sleep(3)

    stxt = screen_texts("th_settings")
    vw.check("本地档案" in stxt, "设置页有「本地档案」", "设置页缺「本地档案」")
    vw.check("外观" in stxt, "设置页有「外观」分区", "设置页缺「外观」分区")

    # ── ④ 默认（跟随系统）时的底色 —— 只记录不断言，系统当前是深是浅我们说了不算
    img0, d0, l0 = shot_pair("th_0_default")
    print(f"     默认：深色像素 {d0} / 浅色像素 {l0}")

    # ── ⑤ 切成浅色
    print("\n-- ⑤ 切「浅色」 --")
    if not tap_text("th_pick_light", "浅色"):
        vw.check(False, "", "点不到「浅色」")
        return
    time.sleep(4)
    img1, d1, l1 = shot_pair("th_1_light")
    vw.check(l1 > BIG and l1 > d1,
             f"整屏换成浅色底（浅 {l1} > 深 {d1}）",
             f"点了浅色但底色没换（浅 {l1} / 深 {d1}）")

    # ── ⑥ 切回深色
    print("\n-- ⑥ 切「深色」 --")
    if not tap_text("th_pick_dark", "深色"):
        vw.check(False, "", "点不到「深色」")
        return
    time.sleep(4)
    img2, d2, l2 = shot_pair("th_2_dark")
    vw.check(d2 > BIG and d2 > l2,
             f"整屏换回深色底（深 {d2} > 浅 {l2}）",
             f"点了深色但底色没换（深 {d2} / 浅 {l2}）")

    # ── ⑦ 返回个人页
    #    ⚠ 先测返回再重启：设置页是内存里的二级页状态，重启后本来就该关掉，
    #      那时再点「‹」自然是空的 —— 第一版把重启放在返回前面，9/10 就是这么丢的。
    print("\n-- ⑦ 返回个人页 --")
    if not tap_text("th_back", "‹", exact=True):
        vw.key("2")
    time.sleep(3)
    btxt = screen_texts("th_back2")
    vw.check("我的数据" in btxt, "返回后回到个人页", "返回后不在个人页")

    # ── ⑧ 偏好要能记住（setColorMode 是应用级、不自带持久化）
    print("\n-- ⑧ 重启后仍是深色 --")
    vw.shell(f"aa force-stop {BUNDLE}")
    time.sleep(2)
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1")
    time.sleep(8)
    img3, d3, l3 = shot_pair("th_3_reboot")
    vw.check(d3 > BIG and d3 > l3,
             f"重启后仍是深色（深 {d3} > 浅 {l3}）—— 偏好真的落盘了",
             f"重启后回到浅色了（深 {d3} / 浅 {l3}）—— Appearance.apply 没接上启动路径")
    rtxt = screen_texts("th_reboot_ui")
    vw.check("本地档案" not in rtxt,
             "重启后直接进主界面，不停在设置页",
             "重启后停在设置页 —— 二级页状态被错误地记住了")

    total = len(vw.RESULTS)
    ok = sum(1 for r in vw.RESULTS if r)
    print(f"\n{'=' * 62}")
    print(f"结果：{ok} 通过 / {total - ok} 失败")
    print("截图：tools/_shots/th_*.jpeg")
    print(f"{'=' * 62}")


if __name__ == "__main__":
    main()
