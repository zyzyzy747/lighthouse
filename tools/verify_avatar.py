# -*- coding: utf-8 -*-
"""灯塔 · 头像（更换 / 恢复默认）验收

要证明什么
----------
1. 个人页真的有头像，而且**换一张之后头像区域的像素真的变了**。
2. 换过的头像**能活过冷启动** —— 不是只存在内存里。
3. 恢复默认后**真的回到默认头像**。
4. 设置页那个「更换」按钮**真的能拉起系统相册**。

为什么这么验
------------
模拟器是 uid=2000 非 root，**没法程序化往系统相册塞图**
（`mediatool` 只有 recv/delete/query 没有 insert；媒体库目录 Permission denied）。
所以"从相册选一张"这条路径在无人值守时走不到底。

于是验收绕开相册，用 `--ps lh_avatar demo` 把 rawfile 里那张
**橙黑斜条纹测试图**（`avatar_selftest.png`）装成头像 ——
它和默认头像（一张黑白漫画）视觉差异极大，像素比对能给出硬判据。
这条链路覆盖的正是相册路径后半程最容易出错的一段：
「读图 → 写沙箱 → 记 KV → 界面读取」。

三个必须守住的坑（都实踩过）
----------------------------
① **每步都要确认自己站在个人页上**。第一版没有这一步，
   结果两张截图都截在设置页（应用上一个状态残留），
   拿两个不同页面做差分，"头像变了没有"直接变成整页差异，全盘歪掉。
② **冷启动必须等进程真的消失**（`vw.force_stop`）。`aa force-stop` 报成功
   不代表进程没了 —— 实测过 3 秒后进程还在且 PID 变了。不等，
   "重启后头像还在吗"验的就是同一个进程。
③ **picker 是系统半模态窗口，`dumpLayout` 看不见它**。
   `uitest dumpLayout` 只 dump 应用自己的窗口树。第一版据此判"相册没拉起"，
   而日志里明明白白写着 `pickerType:PHOTO_PICKER` —— 是判据错了，不是功能坏了。
   所以这里改成**看日志**。

⚠ 头像框位置不写死：先截「默认」与「已换」两张做差分，
   差异像素的包围盒就是头像所在区域。布局改了脚本也不会失效。
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

LOG_CHANGED = "头像已更新（来源 rawfile"
LOG_RESET = "头像已恢复默认"
LOG_PICKER = "pickerType:PHOTO_PICKER"

# 头像 52vp @3.5 密度 ≈ 182px 见方 ⇒ 约 2.6 万像素。
# 换一张完全不同的图，绝大多数像素都会变；阈值 5000（约 19%）留足余量，
# 同时高到"只是倒计时数字动了"这种噪声不可能触发。
DIFF_CHANGED = 5000
# 「已恢复默认 / 换的头像被记住」只看头像框内，JPEG 压缩噪声是几百像素量级
DIFF_SAME = 2500
PIXEL_TOL = 26
# 状态栏的时间会随截图时刻变，比对前先裁掉顶部，免得分差被它带偏
TOP_CROP = 150


def hdc(*args, timeout=90):
    return subprocess.run([vw.HDC, *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=timeout)


def logs_of(pattern, tail=80):
    """读 hilog（含系统 tag）。picker 的日志来自系统组件，不能用应用 tag 过滤。"""
    r = hdc("shell", f"hilog -x 2>/dev/null | grep -E '{pattern}' | tail -{tail}")
    return [l for l in (r.stdout or '').splitlines() if l.strip()]


def mask_of(a_path, b_path):
    """裁掉状态栏后的逐像素差异掩码。尺寸不一致返回 None。"""
    a = np.asarray(Image.open(a_path).convert("RGB")).astype(np.int16)[TOP_CROP:, :, :]
    b = np.asarray(Image.open(b_path).convert("RGB")).astype(np.int16)[TOP_CROP:, :, :]
    if a.shape != b.shape:
        return None
    return np.abs(a - b).max(axis=2) > PIXEL_TOL


def box_of(mask, pad=12):
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return None
    h, w = mask.shape
    return (max(0, int(xs.min()) - pad), max(0, int(ys.min()) - pad),
            min(w, int(xs.max()) + pad), min(h, int(ys.max()) + pad))


def count_in(mask, box):
    x0, y0, x1, y1 = box
    return int(mask[y0:y1, x0:x1].sum())


def go_profile(tries=4):
    """回到主界面并切到「我的」，**并确认真的到了**。

    ⚠ 必须带重试：`aa start` 把应用拉到前台的瞬间窗口正在重建，
      `dump_layout` 会偶发失败（返回 None）。只试一次的话，
      这次失败会被记成"进不到个人页"，
      而紧接着的断言就变成拿两个不同页面做像素差分 —— 全盘歪掉。
    """
    for i in range(tries):
        vw.enter_tab_shell()
        if vw.tap_tab("我的"):
            time.sleep(1.5)
            ts = vw.texts_of(vw.dump_layout(f"gp_{i}"))
            if "我的数据" in ts:
                return True
        print(f"     （第 {i + 1} 次没进到个人页，重试）")
        time.sleep(2)
    return False


def cold_start(param=None, settle=12):
    """冷启动：先确认进程真的没了，再拉起。"""
    if not vw.force_stop(BUNDLE):
        print("     ⚠ 进程没停干净，冷启动结果可能不可信")
    vw.clear_logs()
    extra = f" --ps {param}" if param else ""
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1{extra}")
    time.sleep(settle)


def hot_param(param, settle=6):
    """热启动带参（走 onNewWant）—— 应用活着时不会重建 UI，页面保持不变。"""
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1 --ps {param}")
    time.sleep(settle)


def main():
    print("=" * 62)
    print("灯塔 · 头像 验收")
    print("=" * 62)

    # ── ① 重装 + 冷启动 + 进个人页
    print("\n-- ① 重装并进「我的」 --")
    vw.force_stop(BUNDLE)
    hdc("uninstall", BUNDLE)
    time.sleep(2)
    r = hdc("install", HAP)
    print(f"     {(r.stdout or r.stderr or '').strip()[:70]}")
    time.sleep(2)
    cold_start(settle=13)

    if not go_profile():
        vw.check(False, "", "进不到个人页（拿不到像素基准）")
        return
    vw.check(True, "已进入个人页", "")

    # ── ② 先把头像重置成默认，拿到干净基准
    #    ⚠ 覆盖安装**不清应用数据**，上一次跑测可能已经设过自定义头像。
    #      不先重置，"默认头像基准"就是错的（第一版就栽在这：基准其实是上次的测试图）。
    print("\n-- ② 基准：重置为默认头像 --")
    hot_param("lh_avatar reset")
    if not go_profile():
        vw.check(False, "", "重置后回不到个人页")
        return
    p_default = vw.shot("av_0_default.jpeg")

    # ── ③ 换一张测试头像
    print("\n-- ③ 换上测试头像 --")
    vw.clear_logs()
    hot_param("lh_avatar demo")
    if not go_profile():
        vw.check(False, "", "换头像后回不到个人页")
        return
    p_test = vw.shot("av_1_test.jpeg")

    lg = logs_of(LOG_CHANGED)
    vw.check(len(lg) > 0,
             "日志确认头像已写盘",
             f"没看到「{LOG_CHANGED}」—— 自检开关没生效或写盘失败")

    m = mask_of(p_default, p_test)
    if m is None:
        vw.check(False, "", "两张截图尺寸不一致，无法比对")
        return
    n_changed = int(m.sum())
    box = box_of(m)
    print(f"     差异像素 {n_changed}，包围盒 {box}（已裁掉顶部 {TOP_CROP}px 状态栏）")

    vw.check(n_changed > DIFF_CHANGED,
             f"头像区域像素真的变了（{n_changed} 个差异像素）",
             f"换完头像画面几乎没变（只有 {n_changed} 个差异像素）"
             f" —— 落盘成功但界面没刷新，或 Image 还在吃缓存")

    if box is not None:
        w, h = m.shape[1], m.shape[0]
        cx = (box[0] + box[2]) / 2
        cy = (box[1] + box[3]) / 2
        vw.check(cx < w * 0.45 and cy < h * 0.6,
                 f"变化集中在左上（重心 {int(cx)},{int(cy + TOP_CROP)}）—— 确实是头像",
                 f"变化区域在 ({int(cx)},{int(cy + TOP_CROP)})，不像个人页左上角的头像")

    # ── ④ 换的头像要活过冷启动
    print("\n-- ④ 冷启动后头像仍在 --")
    cold_start(settle=13)
    if not go_profile():
        vw.check(False, "", "冷启动后进不到个人页")
        return
    p_reboot = vw.shot("av_2_reboot.jpeg")

    m2 = mask_of(p_test, p_reboot)
    if m2 is None:
        vw.check(False, "", "重启前后截图尺寸不一致")
    elif box is not None:
        inside = count_in(m2, box)
        vw.check(inside < DIFF_SAME,
                 f"冷启动后头像框内几乎无变化（{inside} 像素）—— 自定义头像被记住了",
                 f"冷启动后头像框内变了 {inside} 像素 —— 头像没落盘，或启动时没读回来")
    else:
        vw.check(False, "", "拿不到头像包围盒，跳过重启一致性")

    # ── ⑤ 恢复默认
    print("\n-- ⑤ 恢复默认头像 --")
    vw.clear_logs()
    hot_param("lh_avatar reset")
    if not go_profile():
        vw.check(False, "", "恢复默认后回不到个人页")
        return
    p_reset = vw.shot("av_3_reset.jpeg")

    lg2 = logs_of(LOG_RESET)
    vw.check(len(lg2) > 0, "日志确认已恢复默认", f"没看到「{LOG_RESET}」")

    m3 = mask_of(p_default, p_reset)
    if m3 is None:
        vw.check(False, "", "恢复默认前后截图尺寸不一致")
    elif box is not None:
        inside = count_in(m3, box)
        vw.check(inside < DIFF_SAME,
                 f"头像框内已回到默认（与初始只差 {inside} 像素）",
                 f"头像框内与初始差 {inside} 像素 —— 恢复默认没真的还原")
    else:
        vw.check(False, "", "拿不到头像包围盒，跳过恢复一致性")

    # ── ⑥ 界面入口能拉起系统相册
    #    ⚠ 判据是**日志**不是控件树：picker 是系统半模态窗口，
    #      `uitest dumpLayout` 只 dump 应用自己的窗口树，看不到它。
    print("\n-- ⑥ 设置页「更换」能拉起系统相册 --")
    vw.enter_tab_shell()
    vw.tap_tab("我的")
    time.sleep(1.5)
    if not vf.tap(vw.dump_layout("av_p1"), "设置", True):
        vw.check(False, "", "点不到「设置」入口")
    else:
        time.sleep(3)
        stxt = " ".join(vw.texts_of(vw.dump_layout("av_settings")))
        vw.check("本地档案" in stxt and "头像" in stxt and "更换" in stxt,
                 "设置页有「本地档案 · 头像 · 更换」",
                 f"设置页看不到头像设置（屏幕文字：{stxt[:80]}）")

        vw.clear_logs()
        if not vf.tap(vw.dump_layout("av_p2"), "更换", True):
            vw.check(False, "", "点不到「更换」按钮")
        else:
            time.sleep(7)
            plog = logs_of("PHOTO_PICKER|PickerSheetContent")
            hit = plog[-1].strip()[:78] if plog else ""
            vw.check(len(plog) > 0,
                     f"系统相册面板被拉起（{hit}）—— 真机上就能选图了",
                     "日志里没有 PHOTO_PICKER —— 相册没被拉起")
            vw.key("2")
            time.sleep(2)
            vw.key("2")
            time.sleep(2)

    total = len(vw.RESULTS)
    ok = sum(1 for r in vw.RESULTS if r)
    print(f"\n{'=' * 62}")
    print(f"结果：{ok} 通过 / {total - ok} 失败")
    print("截图：tools/_shots/av_*.jpeg")
    print(f"{'=' * 62}")


if __name__ == "__main__":
    main()
