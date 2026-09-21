#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
「灯塔」桌面服务卡片的端到端验证。

回答的问题是：卡片到底能不能用，而不是"编译过了所以应该能用"。

七个断点，每个都有硬判据（日志 / 系统 dump / 像素），不靠"看起来正常"：

  1  卡片配置真的进了包           hap 内含 form_config.json + widgets.abc
  2  卡片能被系统创建             hilog: onAddForm
  3  卡片进程能读数据库           hilog: form: db ready + 读到节点
  4  卡片真的加到了桌面           FormMgr dump: FormRecord + RENDERED
  5  定时刷新配置生效             FormMgr dump: updateDuration=1800000（30 分钟）
  6  App 写库后卡片自动刷新       hilog: reloadForms 命中数 + 卡片进程 onUpdateForm
  7  卡内 ＋ 能拉起应用到指定页   hilog: 导航意图已入队 + 卡片意图已执行

用法：
    python verify_widget.py                # 全流程（会卸载重装，清空数据库）
    python verify_widget.py --skip-build   # 跳过编译
    python verify_widget.py --keep         # 不重装，在现有数据上验证
"""
import argparse
import os
import re
import subprocess
import sys
import time

import numpy as np
from PIL import Image

sys.stdout.reconfigure(encoding="utf-8")

HDC = r"D:/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"
PROJECT = os.environ.get("LIGHTHOUSE_PROJECT", r"D:/work/DevEcoStudioProject/Lighthouse")
TOOLS = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(TOOLS, "_shots")

BUNDLE = "com.wuit.lighthouse"
ABILITY = "EntryAbility"
HAP_DIR = os.path.join(PROJECT, "entry/build/default/outputs/default")
HAP = "entry-default-signed.hap"

FORM_MAIN = "rhythm_card"

# 屏幕坐标（1256x2760，密度 3.5）。定位不到时用这些兜底。
TAB_PROFILE = (1099, 2560)     # 底部第 4 个 Tab「我的」

# 「2×4 主卡」按钮底色 = Palette.ACCENT（橙），「载入演示数据」= Palette.PRIMARY（蓝）
BTN_ACCENT = (255, 176, 32)
BTN_PRIMARY = (74, 158, 255)

# 系统强调蓝：卡片管理页的「添加至桌面」和底部「完成」同色，
# 只能靠宽度区分 —— 前者是一行字，后者是全宽实心按钮。
SYS_BLUE = (10, 88, 246)

# 卡片上的「＋」= 淡蓝底 #EAF1FD + 蓝字 #2E7FE8，28×24vp ≈ 98×84px。
PLUS_BG = (234, 241, 253)

AC = "\u2713"   # ✓
NG = "\u2717"   # ✗

RESULTS = []


# ---------------------------------------------------------------- 基础工具

def hdc(*args, timeout=60):
    p = subprocess.run([HDC] + list(args), capture_output=True, timeout=timeout)
    return p.stdout.decode("utf-8", "ignore").strip()


def shell(cmd, timeout=60):
    return hdc("shell", cmd, timeout=timeout)


def tap(x, y, wait=2.0):
    shell(f"uinput -T -c {x} {y}")
    time.sleep(wait)


def key(code, wait=2.0):
    """code: 1=HOME 2=BACK"""
    shell(f"uinput -K -d {code} -u {code}")
    time.sleep(wait)


def shot(name):
    local = os.path.join(SHOTS, name)
    os.makedirs(SHOTS, exist_ok=True)
    shell("snapshot_display -f /data/local/tmp/_v.jpeg")
    p = subprocess.run([HDC, "file", "recv", "/data/local/tmp/_v.jpeg", name],
                       cwd=SHOTS, capture_output=True, timeout=90)
    if not os.path.isfile(local):
        raise RuntimeError(f"截图拉取失败: {local}")
    return local


def logs(pattern, tail=40):
    out = shell(f"hilog -x 2>/dev/null | grep -E '{pattern}' | tail -{tail}")
    return [l for l in out.splitlines() if l.strip()]


def clear_logs():
    shell("hilog -r")


def check(cond, ok_msg, bad_msg):
    if cond:
        print(f"  {AC} {ok_msg}")
        RESULTS.append(True)
    else:
        print(f"  {NG} {bad_msg}")
        RESULTS.append(False)
    return bool(cond)


def find_band(image, rgb, tol=20, min_area=3000, pick="largest"):
    """在截图里找符合颜色的色带，返回 (cx, cy, x0, y0, x1, y1) 或 None"""
    arr = np.asarray(Image.open(image).convert("RGB")).astype(np.int16)
    diff = np.abs(arr - np.array(rgb, dtype=np.int16))
    mask = (diff <= tol).all(axis=2)
    if mask.sum() == 0:
        return None
    h = mask.shape[0]
    rowsum = mask.sum(axis=1)
    bands, in_band, start = [], False, 0
    for y in range(h):
        if rowsum[y] > 0 and not in_band:
            in_band, start = True, y
        elif rowsum[y] == 0 and in_band:
            in_band = False
            if y - start >= 8:
                bands.append((start, y - 1))
    if in_band and h - start >= 8:
        bands.append((start, h - 1))

    found = []
    for (y0, y1) in bands:
        sub = mask[y0:y1 + 1]
        xs = np.where(sub.sum(axis=0) > 0)[0]
        if len(xs) == 0:
            continue
        area = int(sub.sum())
        if area < min_area:
            continue
        x0, x1 = int(xs.min()), int(xs.max())
        found.append(((x0 + x1) // 2, (y0 + y1) // 2, x0, y0, x1, y1, area))
    if not found:
        return None
    if pick == "bottom":
        found.sort(key=lambda b: b[1])
    else:
        found.sort(key=lambda b: b[6], reverse=True)
    return found[-1] if pick == "bottom" else found[0]


def _bands(mask, min_h=10):
    """把布尔掩码按行切成连续段，返回 [(y0, y1), ...]"""
    rows = mask.sum(axis=1)
    out, inb, st = [], False, 0
    for y in range(mask.shape[0]):
        if rows[y] > 0 and not inb:
            inb, st = True, y
        elif rows[y] == 0 and inb:
            inb = False
            if y - st >= min_h:
                out.append((st, y - 1))
    if inb and mask.shape[0] - st >= min_h:
        out.append((st, mask.shape[0] - 1))
    return out


def find_card_band(image, min_rows=800):
    """在桌面截图里找卡片背板，返回 (y0, y1) 或 None。

    判据是「低饱和度 + 横向铺满」，而不是「近白」：
    浅色模式下卡片底是纯白 (255,255,255)，深色模式下是深蓝灰，
    共同点是饱和度极低，而模拟器壁纸是高饱和蓝 —— 两者能干净分开。
    """
    arr = np.asarray(Image.open(image).convert("RGB")).astype(np.int16)
    mx, mn = arr.max(axis=2), arr.min(axis=2)
    flat = ((mx - mn) < 24) & ((mx > 225) | (mx < 95))
    for (y0, y1) in _bands(flat, min_h=200):
        sub = flat[y0:y1 + 1]
        xs = np.where(sub.sum(axis=0) > 5)[0]
        if len(xs) and (xs.max() - xs.min()) > 700:
            return (y0, y1)
    return None


def goto_card_page(tries=4):
    """回到桌面上有卡片的那一页，返回 (控件树, 卡片 bounds or None)。

    三个坑都在这里踩过，别再凭直觉改：

    ① **HOME 键要按两下**。实测这台模拟器（HarmonyOS 6.1.1 模拟器）：
        应用前台按 HOME → 落到一个**没有卡片的空页**（不是主屏）；
        已经在桌面时再按 HOME → 才回到主屏第一页，卡片在这儿。
       最早那次跑脚本就是栽在这 —— 按一次 HOME，于是「桌面上找不到卡片」、
       点「＋」也点空，4 个 ✗ 里 3 个都是这一个原因。

    ② **卡片管理页里也有 FormComponent**（卡片预览），
       不排除就会把预览当成桌面卡片，靠 "添加至" 字样区分。

    ③ **卡片坐标不能写死**：位置由用户在桌面上决定，必须从控件树现取。
    """
    lay = None
    key(1, wait=3)
    key(1, wait=3)      # 连按两下才回主屏，见 ①
    for attempt in range(tries + 1):
        if attempt > 0:
            if attempt % 2 == 1:
                shell("uinput -T -m 180 1500 1080 1500 400")    # 右滑 = 回上一页
            else:
                shell("uinput -T -m 1080 1500 180 1500 400")    # 左滑 = 去下一页
            time.sleep(2)
        lay = dump_layout(f"layout_home{attempt}")
        if not lay:
            continue
        form = find_form_node(lay)
        if form and "添加至" not in " ".join(texts_of(lay)):
            return lay, form
    return lay, None


def find_add_button(image):
    """【已废弃】靠像素找「添加至桌面」。留作参照，不再是主路径。

    实测这个页面底部有两个同色按钮：「添加至负一屏」（细长蓝字）和
    「添加至桌面」（全宽蓝底白字），靠宽度/居中筛选很容易选错，
    而 uitest dumpLayout 能直接给出文字和 bounds —— 用 find_text_node。
    """
    arr = np.asarray(Image.open(image).convert("RGB")).astype(np.int16)
    mid = arr.shape[1] // 2
    d = np.abs(arr - np.array(SYS_BLUE, dtype=np.int16))
    mask = (d <= 26).all(axis=2)
    if mask.sum() < 300:
        return None
    for (y0, y1) in _bands(mask, min_h=8):
        if y0 < 300:
            continue
        xs = np.where(mask[y0:y1 + 1].sum(axis=0) > 0)[0]
        if len(xs) == 0:
            continue
        cx = (int(xs.min()) + int(xs.max())) // 2
        if int(xs.max() - xs.min()) > 600:
            continue
        if abs(cx - mid) > 220:
            continue
        return (cx, (y0 + y1) // 2)
    return None


# ---------------------------------------------------------------- 控件树

def dump_layout(tag="layout"):
    """导出当前界面的控件树，返回解析后的 dict（失败返回 None）。

    比截图找色可靠得多：卡片的每个 Text 连同 bounds 都在里面，
    于是可以对着**文字**断言（"3 个节点在等"、"精测电子 一面"），
    而不是对着像素猜。桌面上卡片会以 FormComponent 节点出现。
    """
    import json as _json
    remote = "/data/local/tmp/lh_layout.json"
    shell(f"uitest dumpLayout -p {remote}")
    name = f"{tag}.json"
    subprocess.run([HDC, "file", "recv", remote, name], cwd=SHOTS,
                   capture_output=True, timeout=60)
    path = os.path.join(SHOTS, name)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return _json.load(f)
    except Exception:
        return None


def walk_nodes(node):
    yield node
    for c in node.get("children") or []:
        yield from walk_nodes(c)


def _bounds_of(node):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]",
                 node.get("attributes", {}).get("bounds", ""))
    return tuple(int(v) for v in m.groups()) if m else None


def find_text_node(layout, text, exact=False):
    """按文字找控件，返回 (cx, cy, bounds) 或 None"""
    if not layout:
        return None
    for n in walk_nodes(layout):
        t = (n.get("attributes", {}).get("text") or "").strip()
        if (t == text) if exact else (text and text in t):
            b = _bounds_of(n)
            if b:
                return ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2, b)
    return None


def find_form_node(layout):
    """找桌面上的卡片本体（FormComponent），返回 bounds 或 None"""
    if not layout:
        return None
    for n in walk_nodes(layout):
        if n.get("attributes", {}).get("type") == "FormComponent":
            b = _bounds_of(n)
            if b:
                return b
    return None


def texts_of(layout):
    """控件树里所有非空文字（用于断言卡片内容）"""
    if not layout:
        return []
    return [t for t in ((n.get("attributes", {}).get("text") or "").strip()
                        for n in walk_nodes(layout)) if t]


def find_plus_in_card(layout, card):
    """在卡片范围内找「＋」（全角 U+FF0B），返回 (cx, cy, bounds) 或 None。

    写死坐标是行不通的：卡片位置由用户在桌面上决定，
    所以从控件树里拿它自己报出来的 bounds。
    """
    if not layout or not card:
        return None
    for n in walk_nodes(layout):
        if (n.get("attributes", {}).get("text") or "").strip() != "\uff0b":
            continue
        b = _bounds_of(n)
        if b and card[0] <= b[0] and b[2] <= card[2] and card[1] <= b[1] and b[3] <= card[3]:
            return ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2, b)
    return None


# ---------------------------------------------------------------- 各断点

def step1_packaged():
    print("\n== 1/7 卡片配置是否真的进了 hap ==")
    import json
    import zipfile
    hap = os.path.join(HAP_DIR, HAP)
    if not os.path.isfile(hap):
        return check(False, "", f"找不到 hap：{hap}")
    z = zipfile.ZipFile(hap)
    names = z.namelist()
    ok = True
    for need in ["ets/widgets.abc", "resources/base/profile/form_config.json"]:
        ok = check(any(n.endswith(need) for n in names), f"包内含 {need}", f"包内缺 {need}") and ok
    mj = json.loads(z.read("module.json").decode("utf-8"))
    ext = [e for e in mj["module"].get("extensionAbilities", []) if e.get("type") == "form"]
    ok = check(len(ext) == 1 and ext[0]["name"] == "EntryFormAbility",
               f"FormExtensionAbility 已注册（{ext[0]['name'] if ext else '无'}）",
               "module.json5 里没有 type=form 的 extensionAbility") and ok
    forms = []
    for n in names:
        if n.endswith("form_config.json"):
            forms = json.loads(z.read(n).decode("utf-8"))["forms"]
    ok = check(len(forms) == 2, f"form_config 有 {len(forms)} 张卡片", "form_config 卡片数不为 2") and ok
    return ok


def step2_install(args):
    print("\n== 2/7 安装并冷启动（清库） ==")
    if args.skip_build:
        print("  跳过编译")
    else:
        log = os.path.join(TOOLS, "_build.log")
        with open(log, "w", encoding="utf-8") as f:
            p = subprocess.run(
                [r"D:/DevEco Studio/tools/node/node.exe",
                 r"D:/DevEco Studio/tools/hvigor/bin/hvigorw.js",
                 "--mode", "module", "-p", "product=default", "assembleHap", "--no-daemon"],
                cwd=PROJECT, stdout=f, stderr=subprocess.STDOUT,
                env={**os.environ, "DEVECO_SDK_HOME": r"D:\DevEco Studio\sdk"})
        ok = open(log, encoding="utf-8", errors="ignore").read()
        if not check("BUILD SUCCESSFUL" in ok, "编译通过", "编译失败，见 tools/_build.log"):
            return False

    hap = os.path.join(HAP_DIR, HAP)
    subprocess.run([HDC, "install", "-r", HAP], cwd=HAP_DIR, capture_output=True, timeout=240)
    if not args.keep:
        shell(f"bm uninstall -n {BUNDLE}")
        time.sleep(2)
        out = subprocess.run([HDC, "install", HAP], cwd=HAP_DIR, capture_output=True, timeout=240)
        txt = out.stdout.decode("utf-8", "ignore")
        if not check("successfully" in txt.lower(), "卸载重装成功（数据库已清空）", f"安装失败：{txt[-200:]}"):
            return False
    else:
        print("  --keep：保留现有数据")
    shell(f"aa force-stop {BUNDLE}")
    time.sleep(1)
    shell(f"aa start -a {ABILITY} -b {BUNDLE}")
    time.sleep(5)
    return True


def step3_create_form():
    print("\n== 3/7 卡片能否被系统创建（onAddForm） ==")
    tap(*TAB_PROFILE, wait=2)
    lay = dump_layout("layout_profile")
    btn = find_text_node(lay, "主卡")
    if btn is not None:
        cx, cy, src = btn[0], btn[1], "控件树"
    else:
        img = shot("widget_profile.jpeg")
        band = find_band(img, BTN_ACCENT, tol=16, min_area=2000)
        if band is None:
            return check(False, "", "在「我的」页找不到『2×4 主卡』按钮")
        cx, cy, src = band[0], band[1], "像素"
    print(f"  『2×4 主卡』按钮位于 ({cx}, {cy})（{src}定位）")

    clear_logs()
    tap(cx, cy, wait=6)
    lines = logs("Lighthouse")
    text = "\n".join(lines)
    ok = check(f"onAddForm" in text and FORM_MAIN in text,
               "onAddForm 被调用（卡片已被创建）", "没有 onAddForm 日志 —— 卡片没被创建")
    ok = check("form: db ready" in text,
               "卡片进程独立初始化了数据库", "卡片进程没读数据库（跨进程读库失败？）") and ok
    m = re.search(r"卡片已刷新.*?共(\d+)个节点", text)
    ok = check(m is not None and int(m.group(1)) >= 0,
               f"卡片拿到真实数据（{m.group(0) if m else '无'}）",
               "卡片没读到节点数据") and ok
    return ok


def step4_added_to_desktop():
    print("\n== 4/7 卡片真的加到桌面了吗（查系统 FormMgr） ==")
    lay = dump_layout("layout_mgr")
    btn = find_text_node(lay, "添加至桌面", exact=True)
    if btn is None:
        img = shot("widget_manager.jpeg")
        band = find_add_button(img)
        if band is None:
            return check(False, "", "卡片管理页没找到「添加至桌面」（页面没打开？）")
        btn = (band[0], band[1], None)
        print("  控件树没读到，回退像素定位")
    print(f"  「添加至桌面」位于 ({btn[0]}, {btn[1]})")
    tap(btn[0], btn[1], wait=6)

    dump = shell(f"hidumper -s FormMgr -a '-n {BUNDLE}'")
    has = "FormRecord" in dump and FORM_MAIN in dump
    ok = check(has, "系统 FormMgr 里存在灯塔的卡片记录", "FormMgr 里查不到灯塔卡片 —— 没加桌成功")
    if not has:
        return False
    ok = check("RENDERED" in dump, "卡片状态为 RENDERED（已渲染）", "卡片未渲染完成") and ok
    m = re.search(r"specification \[(\d+)\]", dump)
    ok = check(m is not None and m.group(1) == "3",
               f"规格为 {m.group(1) if m else '?'}（3 = 2×4）", "卡片规格不是 2×4") and ok

    # 回到桌面，确认卡片真的以组件形式画出来了（不只是系统里有一条记录）
    _lay, form = goto_card_page()
    if form:
        w, h = form[2] - form[0], form[3] - form[1]
        ratio = w / h if h else 0
        ok = check(1.9 < ratio < 2.6,
                   f"桌面上的卡片是 {w}×{h} px（{ratio:.2f}:1，约 2×4）",
                   f"桌面卡片比例 {ratio:.2f}:1 不像 2×4") and ok
    else:
        ok = check(False, "", "桌面上找不到卡片组件（FormComponent）") and ok
    return ok


def step5_update_duration():
    print("\n== 5/7 定时刷新配置是否被系统接受 ==")
    dump = shell(f"hidumper -s FormMgr -a '-n {BUNDLE}'")
    m = re.search(r"updateDuration \[(\d+)\]", dump)
    ms = int(m.group(1)) if m else -1
    ok = check(ms == 1800000,
               f"updateDuration = {ms} ms（{ms // 60000} 分钟）",
               f"updateDuration = {ms}，期望 1800000（30 分钟）")
    # ⚠ 别写成 "isEnableUpdate \[1\]" in dump —— Python 里 \[ 是无效转义，
    #   会字面去找带反斜杠的串，永远匹配不上。要么用 r"" 要么用正则。
    m2 = re.search(r"isEnableUpdate \[(\d+)\]", dump)
    ok = check(m2 is not None and m2.group(1) == "1",
               "周期性刷新已启用（isEnableUpdate=1）",
               f"周期性刷新未启用（isEnableUpdate={m2.group(1) if m2 else '缺失'}）") and ok
    ok = check("rhythm_card" in dump, "主卡已注册到系统", "系统里没有主卡记录") and ok
    return ok


def step6_consistency():
    print("\n== 6/7 数据一致性：App 写库 → 卡片自动刷新 ==")
    # 上一断点结束时停在桌面，这里必须先把应用拉起来，否则点底部 Tab 是点在壁纸上
    shell(f"aa start -a {ABILITY} -b {BUNDLE}")
    time.sleep(5)
    tap(*TAB_PROFILE, wait=3)
    lay = dump_layout("layout_profile2")
    btn = find_text_node(lay, "载入演示数据")
    if btn is not None:
        pos, src = (btn[0], btn[1]), "控件树"
    else:
        img = shot("widget_profile2.jpeg")
        band = find_band(img, BTN_PRIMARY, tol=18, min_area=5000)
        if band is None:
            return check(False, "", "在「我的」页找不到『载入演示数据』按钮"), None, None
        pos, src = (band[0], band[1]), "像素"
    print(f"  『载入演示数据』位于 {pos}（{src}定位）")
    clear_logs()
    tap(pos[0], pos[1], wait=8)
    text = "\n".join(logs("Lighthouse"))

    m = re.search(r"rhythm_card 命中 (\d+) 张", text)
    hit = int(m.group(1)) if m else -1
    ok = check(hit >= 1,
               f"reloadForms 命中 {hit} 张卡片（主动推送生效）",
               f"reloadForms 命中 {hit} 张 —— 应用没有把变更推给卡片")
    ok = check("onUpdateForm" in text,
               "卡片进程收到刷新通知（onUpdateForm）", "卡片进程没收到刷新通知") and ok
    ok = check("卡片已刷新" in text, "卡片完成重绘", "卡片没有完成重绘") and ok
    n = re.search(r"共(\d+)个节点", text)
    ok = check(n is not None and int(n.group(1)) > 0,
               f"卡片读到 {n.group(1) if n else '?'} 个节点（不是空态）",
               "卡片读到 0 个节点 —— 跨进程读库没拿到写进去的数据") and ok

    # 回到桌面，直接从控件树读卡片上真正画出来的文字
    lay, card = goto_card_page()
    if card is None:
        return check(False, "", "桌面上找不到卡片组件") and ok, None, None
    joined = " | ".join(texts_of(lay))
    m2 = re.search(r"(\d+) 个节点在等", joined)
    ok = check(m2 is not None,
               f"卡片上写着「{m2.group(0)}」（和日志口径一致）" if m2 else "",
               f"卡片没显示节点概览（实际读到：{joined[:120]}）") and ok
    m3 = re.search(r"(小时后|天后)", joined)
    ok = check(m3 is not None,
               "卡片大字倒计时带单位（小时后/天后）", "卡片上没有倒计时") and ok
    return ok, lay, card


def step7_card_action(layout, card):
    print("\n== 7/7 卡内交互：点卡片「＋」直达投递快记 ==")
    if card is None:
        return check(False, "", "上一断点没找到卡片，无法定位「＋」按钮")
    # 此刻桌面已停在有卡片的那页（step6 的 goto_card_page 保证），别再按 HOME
    shell(f"aa force-stop {BUNDLE}")
    time.sleep(2)
    lay = dump_layout("layout_before_plus") or layout
    plus = find_plus_in_card(lay, card)
    if plus is None:
        return check(False, "", "卡片上找不到「＋」按钮")
    print(f"  卡片「＋」位于 ({plus[0]}, {plus[1]})，按钮区 {plus[2]}")

    clear_logs()
    tap(plus[0], plus[1], wait=7)
    text = "\n".join(logs("Lighthouse"))
    ok = check("导航意图已入队：quick" in text,
               "postCardAction 生效，参数 lh_target=quick 传到了应用",
               "点击卡片没有产生导航意图 —— postCardAction 没生效或坐标不对")
    ok = check("卡片意图已执行 target=quick tab=0" in text,
               "应用冷启动后直接落在「投递快记」页",
               "意图没被执行（@Watch 接不住冷启动的初值？）") and ok
    shot("widget_after_plus.jpeg")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-build", action="store_true")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    if hdc("list", "targets").count("127.0.0.1") == 0 and "emulator" not in hdc("list", "targets").lower():
        t = hdc("list", "targets")
        if not t.strip() or "Empty" in t:
            print("没有连接设备/模拟器，先启动模拟器")
            sys.exit(2)
        print(f"设备: {t.splitlines()[0]}")

    step1_packaged()
    if step2_install(args):
        if step3_create_form():
            step4_added_to_desktop()
            step5_update_duration()
            _ok6, lay6, card = step6_consistency()
            step7_card_action(lay6, card)

    total = len(RESULTS)
    passed = sum(1 for r in RESULTS if r)
    print(f"\n{'=' * 56}")
    print(f"结果：{passed}/{total} 通过")
    if passed < total:
        print("未通过项见上方 ✗ 行")
        sys.exit(1)
    print("桌面卡片全链路可用")


if __name__ == "__main__":
    main()
