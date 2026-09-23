"""录演示视频的原始素材：ffmpeg 抓模拟器窗口 + hdc 驱动应用。

为什么这么绕：
  · 模拟器**没有 screenrecord**（实测 `/bin/sh: screenrecord: inaccessible or not found`）；
  · `gdigrab -i title=Emulator` 抓到的是**空帧**（DWM 合成的窗口抓不到），
    但 `-i desktop` 正常 ⇒ 只能整屏抓、再用 offset/video_size 裁到设备屏。
  · 设备屏在桌面上的矩形由 `--detect` 用亮度分析定出来（桌面壁纸是亮的，
    黑边框是暗的），定好之后写进 REGIONS 直接用。

用法：
  python demo_record.py --detect            # 打印当前朝向的设备屏矩形
  python demo_record.py --clip portrait     # 录一段（带 hdc 驱动）
  python demo_record.py --clip portrait --dry   # 只跑流程不录，先验动作对不对
"""
import argparse
import os
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import verify_widget as vw          # noqa: E402
import verify_multidevice as vm     # noqa: E402

FF = (r"C:\Users\Administrator\.workbuddy\binaries\python\envs\default"
      r"\Lib\site-packages\imageio_ffmpeg\binaries\ffmpeg-win-x86_64-v7.1.exe")
OUT = os.path.join(os.path.dirname(HERE), "submit", "演示视频", "_raw")
B = vw.BUNDLE

# 设备屏在桌面上的矩形 (x, y, w, h) —— 由 --detect 定出来，含一圈机身边框
REGIONS = {
    "portrait": (1286, 74, 414, 856),
}


def log(msg):
    print(msg, flush=True)


# ───────────────────────── 区域侦测 ─────────────────────────

def grab_desktop(path):
    subprocess.run([FF, "-hide_banner", "-loglevel", "error", "-f", "gdigrab",
                    "-framerate", "1", "-i", "desktop", "-frames:v", "1",
                    "-y", path], check=True, timeout=60)
    return path


def detect_region(pad=14):
    """靠亮度找设备屏：亮屏 vs 黑边框。桌面/亮色界面下有效。"""
    import numpy as np
    from PIL import Image

    tmp = os.path.join(OUT, "_detect.png")
    grab_desktop(tmp)
    g = np.asarray(Image.open(tmp).convert("L")).astype(np.int32)
    h, w = g.shape

    # 模拟器窗口大致在右半边；直接全图找最大亮块，避免依赖窗口位置
    bright = g > 55
    colsum, rowsum = bright.sum(axis=0), bright.sum(axis=1)

    def longest_run(arr, thr, min_len):
        best, s = None, None
        for i, v in enumerate(arr):
            if v >= thr and s is None:
                s = i
            elif v < thr and s is not None:
                if best is None or (i - s) > (best[1] - best[0]):
                    best = (s, i - 1)
                s = None
        if s is not None and (best is None or (len(arr) - s) > (best[1] - best[0])):
            best = (s, len(arr) - 1)
        if best and best[1] - best[0] >= min_len:
            return best
        return None

    cx = longest_run(colsum, int(h * 0.45), 200)
    cy = longest_run(rowsum, int(w * 0.30), 300)
    if not cx or not cy:
        return None
    x0, x1 = cx
    y0, y1 = cy
    x0 = max(0, x0 - pad); y0 = max(0, y0 - pad)
    x1 = min(w - 1, x1 + pad); y1 = min(h - 1, y1 + pad)
    rw, rh = (x1 - x0 + 1), (y1 - y0 + 1)
    rw -= rw % 2; rh -= rh % 2          # libx264 要偶数
    return (x0, y0, rw, rh)


# ───────────────────────── 录制 ─────────────────────────

class Rec:
    """起一个固定时长的 gdigrab，之后无论流程怎么走都会自己停。"""

    def __init__(self, region, seconds, out, fps=30):
        x, y, w, h = region
        self.p = subprocess.Popen([
            FF, "-hide_banner", "-loglevel", "error",
            "-f", "gdigrab", "-framerate", str(fps),
            "-offset_x", str(x), "-offset_y", str(y),
            "-video_size", f"{w}x{h}", "-i", "desktop",
            "-t", str(seconds),
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart",
            "-y", out,
        ])
        self.out = out
        time.sleep(1.2)                 # 让 ffmpeg 真正开始抓
        log(f"  ● 开录 {seconds}s → {os.path.basename(out)}")

    def wait(self):
        self.p.wait(timeout=300)
        sz = os.path.getsize(self.out) if os.path.isfile(self.out) else 0
        log(f"  ■ 录制结束（{sz/1024:.0f} KB）")
        return sz


def foreground():
    """把模拟器窗口提到最前，保证它不被别的窗口挡住。"""
    import ctypes
    import ctypes.wintypes as wt
    u = ctypes.windll.user32
    found = []

    @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    def cb(h, _):
        if u.IsWindowVisible(h):
            n = u.GetWindowTextLengthW(h)
            if n:
                b = ctypes.create_unicode_buffer(n + 1)
                u.GetWindowTextW(h, b, n + 1)
                if b.value == "Emulator":
                    found.append(h)
        return True

    u.EnumWindows(cb, 0)
    if not found:
        log("  ⚠ 没找到 Emulator 窗口")
        return False
    h = found[0]
    u.ShowWindow(h, 9)          # SW_RESTORE
    u.SetForegroundWindow(h)
    r = wt.RECT()
    u.GetWindowRect(h, ctypes.byref(r))
    log(f"  ● 模拟器窗口提到最前 {r.left},{r.top},{r.right},{r.bottom}")
    time.sleep(0.8)
    return True


# ───────────────────────── 流程 ─────────────────────────

def tap_xy(x, y, label=""):
    vw.shell(f"uitest uiInput click {x} {y}")
    if label:
        log(f"    · 点击 {label} ({x},{y})")


def flow_portrait(dry=False):
    """竖屏主流程：桌面卡片 → 卡内「＋」直达快记 → 地图 → 复盘雷达 → 我的。"""
    secs = 42
    rec = None if dry else Rec(REGIONS["portrait"], secs,
                               os.path.join(OUT, "clip_portrait.mp4"))

    # ① 停在桌面，先亮出卡片（焦点：第一个界面不是 App 首页）
    vw.shell(f"aa force-stop {B}")
    time.sleep(2)
    log("    · [0s] 桌面 · 卡片展示")
    time.sleep(4.5)

    # ② 点卡片上的「＋」—— 冷启动直达投递快记，这是「3 秒记一条」的证据
    tap_xy(1088, 673, "卡片「＋」")
    log("    · [5s] 等待冷启动进入快记")
    time.sleep(11)

    # ③ 快记：切页 + 轻微滚动，让界面有「活着」的动感
    vw.tap_tab("快记", wait=2.5)
    time.sleep(2.5)
    vw.scroll_content(times=1, frac=0.16)
    time.sleep(2.5)

    # ④ 作战地图
    vw.tap_tab("地图", wait=3)
    time.sleep(5)
    vw.scroll_content(times=1, frac=0.14)
    time.sleep(3)

    # ⑤ 复盘 → 展开看雷达
    vw.tap_tab("复盘", wait=3)
    time.sleep(3)
    lay = vw.dump_layout("demo_review")
    hit = None
    for label in ("查看能力雷达", "生成能力雷达"):
        hit = vw.find_text_node(lay, label, exact=True)
        if hit:
            log(f"    · 雷达入口「{label}」@ {hit[:2]}")
            break
    if hit:
        vw.tap(hit[0], hit[1], wait=2)
        time.sleep(6)
        vw.scroll_content(times=1, frac=0.22)
        time.sleep(3.5)

    # ⑥ 助手
    vw.tap_tab("助手", wait=3)
    time.sleep(4.5)

    # ⑦ 我的
    vw.tap_tab("我的", wait=3)
    time.sleep(4)

    if rec:
        return rec.wait()
    log("  ✓ 流程走完（dry run）")
    return 0


def flow_landscape(dry=False):
    """横屏：一多部署的价值——平板双栏看全局。"""
    secs = 34
    region = REGIONS.get("landscape")
    if not region:
        log("  ⚠ REGIONS 里还没有 landscape，先跑 --detect 再填进来")
        return 0
    rec = None if dry else Rec(region, secs, os.path.join(OUT, "clip_landscape.mp4"))

    vw.shell(f"aa force-stop {B}")
    time.sleep(2)
    vm.rotate_until(lambda: vm.is_landscape() and vm.tabs_on_left(), "横屏侧栏")
    time.sleep(1.5)
    vw.shell(f"aa start -a EntryAbility -b {B} --pi lh_autologin 1 --pi lh_load_demo 1")
    time.sleep(11)

    vw.tap_tab("地图", wait=3)
    time.sleep(6)
    vw.tap_tab("复盘", wait=3)
    time.sleep(7)
    vw.tap_tab("快记", wait=3)
    time.sleep(6)

    if rec:
        return rec.wait()
    log("  ✓ 流程走完（dry run）")
    return 0


FLOWS = {"portrait": flow_portrait, "landscape": flow_landscape}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--clip", choices=sorted(FLOWS))
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--detect", action="store_true")
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)

    if args.detect:
        foreground()
        r = detect_region()
        log(f"检测到设备屏矩形: {r}")
        if r:
            x, y, w, h = r
            log(f"  宽高比 {w/h:.3f}（竖屏应≈0.455 / 横屏应≈2.197）")
        return 0

    if not args.clip:
        ap.print_help()
        return 1

    foreground()
    if not args.dry and args.clip not in REGIONS:
        log(f"⚠ REGIONS 缺 {args.clip} 的矩形")
        return 1
    return 0 if FLOWS[args.clip](dry=args.dry) is not None else 1


if __name__ == "__main__":
    sys.exit(main())
