#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
灯塔 · 模拟器端到端验证：数据写入 + 界面刷新。

为什么需要它：
  本机 Agent 读不了模拟器截图，也点不了 IDE 里的界面。这个脚本用
  「截图 → 按颜色定位控件 → uinput 点击 → 再截图比对」的方式，
  在命令行里完成一次真实的手点验证。

它验证的是最容易翻车的一环：
  **数据写进库了，但当前页面没有立刻刷新**（切走再切回才对）。
  ArkUI V1 的 @Builder 按值传参就会造成这个现象。

用法:
  python verify_write.py                # 全流程
  python verify_write.py --skip-build   # 跳过编译（复用已有 hap）

退出码: 0 全部通过；1 有断言失败；2 环境问题
"""
import argparse
import hashlib
import os
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
DEVECO = r"D:\DevEco Studio"
HDC = os.path.join(DEVECO, "sdk", "default", "openharmony", "toolchains", "hdc.exe")
NODE = os.path.join(DEVECO, "tools", "node", "node.exe")
HVIGOR = os.path.join(DEVECO, "tools", "hvigor", "bin", "hvigorw.js")
PROJ = r"D:\work\DevEcoStudioProject\Lighthouse"
HAP_DIR = os.path.join(PROJ, "entry", "build", "default", "outputs", "default")
HAP = "entry-default-signed.hap"

BUNDLE = "com.wuit.lighthouse"
ABILITY = "EntryAbility"
DB_DIR = f"/data/app/el2/100/database/{BUNDLE}/entry/rdb"
SHOTS = os.path.join(HERE, "_shots")

# 屏幕 1256x2760，密度约 3.44
# ⛔ 坐标已作废（加了第五个 Tab，每格变窄中心平移），一律用 tap_tab(name)
TAB_Y = 2620

# 应用调色板（与 resources/{base,dark}/element/color.json 一致）
# ⚠ 深浅两套都要有：应用跟随系统深浅色，只认深色那套的话，
#   模拟器一切浅色就"找不到蓝色按钮"，报错跟颜色毫无关系。详见 verify_ai.py 顶部说明。
PRIMARY = (0x4A, 0x9E, 0xFF)            # 深色「载入演示数据」按钮
PRIMARY_LIGHT = (0x1F, 0x6F, 0xEB)      # 浅色
ACCENT = (0xFF, 0xB0, 0x20)             # 「记一笔」按钮
ACCENT_LIGHT = (0xB2, 0x6A, 0x00)

ok_count = 0
fail_count = 0


def log(msg):
    print(msg, flush=True)


def ok(msg):
    global ok_count
    ok_count += 1
    log(f"  [PASS] {msg}")


def fail(msg):
    global fail_count
    fail_count += 1
    log(f"  [FAIL] {msg}")


def hdc(*args, timeout=90):
    r = subprocess.run([HDC, *args], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return r.stdout or ""


def shot(name):
    """截图并拉回本地，返回本地路径"""
    os.makedirs(SHOTS, exist_ok=True)
    hdc("shell", "snapshot_display", "-f", "/data/local/tmp/_v.jpeg")
    local = os.path.join(SHOTS, name)
    # ⚠ hdc file recv 会把绝对路径拼到 cwd 之后，必须 cd 过去用相对名
    subprocess.run([HDC, "file", "recv", "/data/local/tmp/_v.jpeg", name],
                   cwd=SHOTS, capture_output=True, timeout=60)
    return local


def md5(path):
    if not os.path.exists(path):
        return ""
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def db_size():
    """WAL 文件字节数。
    ⚠ 不要解析 `ls -la` 的第 N 个字段 —— 第一列是硬链接数（恒为 1），
      容易误取。直接用 stat -c %s 拿纯数字。文件不存在返回 -1。"""
    out = hdc("shell", f"stat -c %s {DB_DIR}/lighthouse.db-wal").strip()
    if out.isdigit():
        return int(out)
    return -1


def find_color_band(image, rgb, tol=20, min_area=5000):
    """返回最大同色色带的 (cx, cy, area, w, h)"""
    try:
        import numpy as np
        from PIL import Image
    except ImportError:
        return None
    arr = np.asarray(Image.open(image).convert("RGB")).astype(np.int16)
    diff = np.abs(arr - np.array(rgb, dtype=np.int16))
    mask = (diff <= tol).all(axis=2)
    if mask.sum() == 0:
        return None
    h, w = mask.shape
    rowsum = mask.sum(axis=1)
    best = None
    start = None
    for y in range(h + 1):
        on = y < h and rowsum[y] > 0
        if on and start is None:
            start = y
        elif not on and start is not None:
            y0, y1 = start, y - 1
            start = None
            if y1 - y0 < 8:
                continue
            sub = mask[y0:y1 + 1]
            xs = np.where(sub.sum(axis=0) > 0)[0]
            if len(xs) == 0:
                continue
            area = int(sub.sum())
            x0, x1 = int(xs.min()), int(xs.max())
            if area < min_area:
                continue
            if best is None or area > best[2]:
                best = ((x0 + x1) // 2, (y0 + y1) // 2, area, x1 - x0 + 1, y1 - y0 + 1)
    return best


def build():
    log("== 1/6 编译")
    env = dict(os.environ, DEVECO_SDK_HOME=os.path.join(DEVECO, "sdk"))
    r = subprocess.run([NODE, HVIGOR, "--mode", "module", "-p", "product=default",
                        "assembleHap", "--no-daemon"],
                       cwd=PROJ, env=env, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=600)
    tail = (r.stdout or "")[-400:]
    if "BUILD SUCCESSFUL" in (r.stdout or ""):
        ok("编译通过")
    else:
        fail(f"编译失败:\n{tail}")
        return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-build", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(HDC):
        log(f"找不到 hdc: {HDC}")
        return 2

    if not args.skip_build:
        if not build():
            return 1

    log("== 2/6 安装")
    r = subprocess.run([HDC, "install", "-r", HAP], cwd=HAP_DIR,
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace", timeout=180)
    if "successfully" in (r.stdout or ""):
        ok("hap 安装成功")
    else:
        fail(f"安装失败: {(r.stdout or '')[-200:]}")
        return 1

    log("== 3/6 清库并重启（拿到干净基线）")
    hdc("shell", "aa", "force-stop", BUNDLE)
    hdc("shell", f"rm -f {DB_DIR}/lighthouse.db*")
    time.sleep(1)
    hdc("shell", "aa", "start", "-a", ABILITY, "-b", BUNDLE)
    time.sleep(5)

    base = shot("verify_tab0.jpeg")
    if os.path.getsize(base) < 20000:
        fail("冷启动截图异常，应用可能没起来")
        return 1
    ok(f"冷启动正常（截图 {os.path.getsize(base)} 字节）")

    log("== 4/6 切到「我的」页，记录写入前基线")
    # ⛔ 不能再用 TAB_X[3] 的硬编码坐标：加第五个 Tab（助手）后每格变窄、中心平移
    if not tap_tab_by_text("我的"):
        fail("找不到底部 Tab「我的」")
        return 1
    time.sleep(2)
    before = shot("verify_before.jpeg")
    wal_before = db_size()
    ok(f"写入前 WAL = {wal_before} 字节")

    log("== 5/6 点「载入演示数据」")
    band = None
    for rgb in (PRIMARY, PRIMARY_LIGHT):     # 深浅两套都试
        band = find_color_band(before, rgb)
        if band is not None:
            break
    if band is None:
        fail("没定位到蓝色按钮（深浅两套调色板都试过了），页面结构可能变了")
        return 1
    cx, cy, area, bw, bh = band
    ok(f"按钮定位 ({cx}, {cy})，尺寸 {bw}x{bh}")
    hdc("shell", "uinput", "-T", "-c", str(cx), str(cy))
    time.sleep(3)

    wal_after = db_size()
    wal_ok = wal_after > wal_before
    if wal_ok:
        ok(f"数据已落库：WAL {wal_before} -> {wal_after} 字节")
    else:
        fail(f"WAL 没有增长（{wal_before} -> {wal_after}），写入没发生")

    log("== 6/6 关键断言：不切页面，界面是否立刻刷新")
    after = shot("verify_after.jpeg")
    changed = md5(after) != md5(before)
    if changed and wal_ok:
        ok("当前页面已自动刷新（响应式正常）")
    elif changed and not wal_ok:
        fail("界面变了但库没变 —— 写入其实失败了，画面变化只是 Toast/busy 态的假象")
    else:
        fail("当前页面没刷新 —— 就是 @Builder 按值传参断响应式那个坑，"
             "检查有没有把动态数据塞进带值类型参数的 @Builder")

    log("")
    log(f"结果：{ok_count} 通过 / {fail_count} 失败")
    log(f"截图目录：{SHOTS}")
    return 0 if fail_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

def tap_tab_by_text(label, tries=3):
    """按文字点底部 Tab（为什么不用坐标：见同目录 verify_widget.tap_tab 的说明）。"""
    import json as _json, subprocess as _sp, os as _os
    for i in range(tries):
        remote = "/data/local/tmp/wr_layout.json"
        hdc("shell", "uitest", "dumpLayout", "-p", remote)
        _sp.run([HDC, "file", "recv", remote, f"wr_tab{i}.json"],
                cwd=SHOTS, capture_output=True, timeout=60)
        path = _os.path.join(SHOTS, f"wr_tab{i}.json")
        if not _os.path.isfile(path):
            time.sleep(1.2); continue
        try:
            lay = _json.load(open(path, encoding="utf-8"))
        except Exception:
            time.sleep(1.2); continue
        hit = _deep_find(lay, label)
        if hit is not None:
            hdc("shell", "uinput", "-T", "-c", str(hit[0]), str(hit[1]))
            return True
        time.sleep(1.2)
    return False


def _deep_find(node, text):
    b = _bounds(node)
    t = (node.get("attributes", {}).get("text") or "").strip()
    if t == text and b:
        return ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)
    for c in node.get("children") or []:
        r = _deep_find(c, text)
        if r is not None:
            return r
    return None


def _bounds(node):
    import re as _re
    m = _re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]",
                  node.get("attributes", {}).get("bounds", ""))
    return tuple(int(v) for v in m.groups()) if m else None

