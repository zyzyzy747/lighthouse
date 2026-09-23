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
TAB_PROFILE = (1099, 2560)     # ⛔ 已作废：曾经是第 4 个 Tab「我的」的坐标。
                               #    加第五个 Tab（助手）之后每格变窄、中心平移，
                               #    这个坐标现在正好落在「助手」上 —— 一律改用 tap_tab("我的")。

# 「2×4 主卡」按钮底色 = Palette.ACCENT（橙），「载入演示数据」= Palette.PRIMARY（蓝）
# 应用调色板（与 resources/{base,dark}/element/color.json 一致）
#
# ⚠⚠ **两套都要留着**：应用跟随系统深浅色，颜色走 base/（浅）与 dark/（深）两套资源。
#   只认深色那一套，模拟器一旦是浅色模式，"按颜色找按钮"就集体失灵 ——
#   而且报出来是「找不到那个按钮」，跟颜色一点关系都看不出来。
#   实测 accent 深 #FFB020 / 浅 #B26A00，红通道差 77；primary 深 #4A9EFF / 浅 #1F6FEB，差 43。
#   ★ 但颜色永远只是**兜底**：主路径一律先用控件树按文字找（Button 节点自带 text）。
#     verify_ai 的「生成能力雷达」就是栽在这儿，见那里的 find_radar_entry()。
BTN_ACCENT = (255, 176, 32)          # 深色 accent
BTN_ACCENT_LIGHT = (178, 106, 0)     # 浅色 accent
BTN_PRIMARY = (74, 158, 255)         # 深色 primary（保留给后续用）
BTN_PRIMARY_LIGHT = (31, 111, 235)   # 浅色 primary
BTN_ACCENTS = (BTN_ACCENT, BTN_ACCENT_LIGHT)

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
    """截当前屏幕到 `_shots/<name>`。⚠ 与 `dump_layout` 同一类坑，见那里的说明。

    截图失败时必须**抛错**，不能返回一张旧图 —— 旧图和"当前界面没问题"
    在像素层面 indistinguishable，会让整条判据失去意义。
    """
    local = os.path.join(SHOTS, name)
    os.makedirs(SHOTS, exist_ok=True)
    shell("rm -f /data/local/tmp/_v.jpeg")
    shell("snapshot_display -f /data/local/tmp/_v.jpeg")
    p = subprocess.run([HDC, "file", "recv", "/data/local/tmp/_v.jpeg", name],
                       cwd=SHOTS, capture_output=True, timeout=90)
    out = (p.stdout or b"").decode("utf-8", "ignore")
    if "Fail" in out or "Fail" in (p.stderr or b"").decode("utf-8", "ignore"):
        raise RuntimeError(f"截图失败（设备端没生成）: {name}")
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


def _card_has_content(lay, form):
    """卡片矩形**内部真的画出了文字**吗（而不是一个还没渲染的空壳）。

    ⚠ 只判"有没有 FormComponent"是不够的：刚回到桌面时卡片进程可能还没画完，
      控件树里**已经有一个空的 FormComponent**。于是函数高高兴兴返回，
      调用方读到的却是一页桌面图标（实测原样是
      `设置 | 图库 | 文件管理 | 日历 | 灯塔 | 18:44 …`），
      报出来是「卡片没显示节点概览」「卡片上没有倒计时」——
      两句都在说"卡片内容不对"，而真因是**那一刻卡片还没画出来**。
      （2026-09-22 实测：verify_widget 从 24/24 掉到 21/23 就是这么来的。）
    判据用"卡片矩形内部至少有一条文字"：空壳必然一条都没有。
    """
    if not form:
        return False
    for n in walk_nodes(lay):
        a = n.get("attributes", {})
        if not (a.get("text") or "").strip():
            continue
        b = _bounds_of(n)
        if b and b[0] >= form[0] and b[1] >= form[1] and b[2] <= form[2] and b[3] <= form[3]:
            return True
    return False


def goto_card_page(tries=4, settle=6):
    """回到桌面上**已经画出内容**的卡片那一页，返回 (控件树, 卡片 bounds or None)。

    五个坑都在这里踩过，别再凭直觉改：

    ⓪ **先看一眼再按键**（2026-09-22 修，这次踩的就是它）。
      原实现**无条件**按两下 HOME，那是照"应用在前台"这个前提写的。
      但如果**已经在桌面主屏、卡片就在眼前**，再按 HOME 不是"回主屏"而是**翻页** ——
      实测从主屏按两下，落到了只有『设置 / 图库 / 文件管理 / 日历』的那一页，
      于是卡片明明好端端摆在屏幕上，函数却报「桌面上找不到卡片了」。
      ⇒ 先 dump 一次，卡片在就直接返回，**一个键都不按**。

    ① **HOME 键要按两下**（应用在前台时）。实测这台模拟器（HarmonyOS 6.1.1 模拟器）：
        应用前台按 HOME → 落到一个**没有卡片的空页**（不是主屏）；
        已经在桌面时再按 HOME → 才回到主屏第一页，卡片在这儿。
       最早那次跑脚本就是栽在这 —— 按一次 HOME，于是「桌面上找不到卡片」、
       点「＋」也点空，4 个 ✗ 里 3 个都是这一个原因。

    ② **卡片管理页里也有 FormComponent**（卡片预览），
       不排除就会把预览当成桌面卡片，靠 "添加至" 字样区分。

    ③ **卡片坐标不能写死**：位置由用户在桌面上决定，必须从控件树现取。

    ④ **"有 FormComponent" ≠ "卡片画出来了"**，见 `_card_has_content`。
      最后那一下 HOME 之后要**轮询到卡片真的带内容**为止，别抓到空壳就走。
    """
    def probe(tag):
        lay = dump_layout(tag)
        if not lay:
            return None, None
        form = find_form_node(lay)
        if form and "添加至" not in " ".join(texts_of(lay)) and _card_has_content(lay, form):
            return lay, form
        return lay, None

    def wait_card(prefix):                     # 见 ④
        lay = None
        for k in range(settle):
            lay, form = probe(f"{prefix}_{k}")
            if form:
                return lay, form
            time.sleep(1.5)
        return lay, None

    lay, form = probe("card_page0")            # 见 ⓪
    if form:
        return lay, form
    key(1, wait=3)                             # 见 ①
    lay, form = probe("card_page_home1")
    if form:
        return lay, form
    key(1, wait=3)
    lay, form = wait_card("card_page_home2")
    if form:
        return lay, form
    for attempt in range(tries):               # 卡片在别的页 ⇒ 翻页找
        if attempt % 2 == 0:
            shell("uinput -T -m 1080 1500 180 1500 400")    # 左滑 = 去下一页
        else:
            shell("uinput -T -m 180 1500 1080 1500 400")    # 右滑 = 回上一页
        time.sleep(2)
        lay, form = wait_card(f"card_page{attempt + 1}")
        if form:
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

    ⚠ **必须能分辨"没拉到"和"拉到的是旧数据"**（2026-09-22 加）。
      `hdc file recv` 失败时**不会**删掉本地目标文件，于是 `os.path.isfile` 照样为真，
      函数会静默返回**上一屏**的控件树 —— 调用方完全看不出来。
      （实测后果：`tap_tab` 连续 3 次读到同一份旧树，报「找不到底部 Tab「我的」」，
        而同一次运行里那个 Tab 明明是好的。找控件的逻辑没错，错的是它看的那份数据。）
      两条一起用才够：
        ① **先删设备端** `rm -f $remote` —— 否则 dump 失败时设备上还留着上一次的，
           recv 会"成功"并把旧内容拉回来；删的是模拟器里的临时文件，不碰本机。
        ② **认 hdc 自己的失败输出** —— 它拉不到时**退出码仍是 0**（实测），
           只在输出里打 `[Fail]Error opening file: no such file or directory`。
      ⛔ 别改成"先删本地文件"：本机有按【回合】计数的删除守卫（50 个），
         验收脚本一轮要 dump 几十次，跑到一半会被拦下来，报的还是一行 json，极难看懂。
    """
    import json as _json
    remote = "/data/local/tmp/lh_layout.json"
    name = f"{tag}.json"
    path = os.path.join(SHOTS, name)
    shell(f"rm -f {remote}")
    shell(f"uitest dumpLayout -p {remote}")
    p = subprocess.run([HDC, "file", "recv", remote, name], cwd=SHOTS,
                       capture_output=True, timeout=60)
    pulled = (p.stdout or b"").decode("utf-8", "ignore")
    if "Fail" in pulled or not os.path.isfile(path):
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
    """按文字找控件，返回 (cx, cy, bounds) 或 None。

    ⚠ **同一个文字在本机上经常对应两个节点**，这里的三条规则都是为它写的：
      实测底部 Tab「我的」= 外层 `Column`（clickable=true，[1004,2459][1256,2662]）
      + 内层 `Text`（clickable=false，[1077,2531][1183,2593]）。
      ArkUI 的容器节点会把子节点文字**聚合到自己的 text 属性上**，所以两边都能命中。

    ① **丢掉退化节点**（宽或高 < 4px）。安全键盘把被遮住的控件压成 2px 高是实测过的
       （见 SKILL 12.16），这种节点点不到任何东西；不排除的话，
       "取最小面积"会稳定地选中它，坐标还正好是屏幕边缘。
    ② **取面积最小的命中**，而不是 DFS 里第一个 —— 最小 = 最贴近那段文字本身的控件，
       不会一蹦跳到某个横跨全屏的聚合容器上（那种容器的中心可能在屏幕正中）。
    ③ **如果某个可点击命中罩住了②的中心，改用它** —— 点容器比点它内部那一小块文字
       更不容易擦边（Tab 的 Column 比里面的 Text 宽 2 倍多）。
       只在"中心确实落在最小命中范围内"时才替换，所以永远是在同一处文字上做选择，
       不会把点击挪到别的控件去。
    """
    if not layout:
        return None
    hits = []
    for n in walk_nodes(layout):
        a = n.get("attributes", {})
        t = (a.get("text") or "").strip()
        if not ((t == text) if exact else (text and text in t)):
            continue
        b = _bounds_of(n)
        if not b:
            continue
        if (b[2] - b[0]) < 4 or (b[3] - b[1]) < 4:      # 见 ①
            continue
        hits.append((b, str(a.get("clickable", "")).lower() == "true"))
    if not hits:
        return None

    tight = min(hits, key=lambda h: (h[0][2] - h[0][0]) * (h[0][3] - h[0][1]))
    cx, cy = (tight[0][0] + tight[0][2]) // 2, (tight[0][1] + tight[0][3]) // 2
    for b, clickable in hits:                            # 见 ③
        if clickable and b[0] <= cx <= b[2] and b[1] <= cy <= b[3]:
            return ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2, b)
    return (cx, cy, tight[0])


def tap_text_anywhere(text, exact=True, tries=6, wait=1.6):
    """在当前界面上点某段文字（自带重试）。找不到返回 False。"""
    for _ in range(tries):
        lay = dump_layout("ta")
        hit = find_text_node(lay, text, exact=exact)
        if hit is not None:
            tap(hit[0], hit[1], wait=wait)
            return True
        time.sleep(1.2)
    return False


def tap_text_with_scroll(text, exact=True, rounds=3, tries=4):
    """在当前页面上点某段文字；找不到就**往下滚一屏再找**（最多 rounds 轮）。

    ⚠ 宽屏/横屏下入口经常被顶到折线以下 —— 而 `dumpLayout` **只返回可见节点** ⇒
      直接找必然为空，报出来却是"这个控件不存在"，把排错方向指向控件匹配。
      （2026-09-22 实测：横屏 1256px 高，「我的」页的「设置」入口正好落在屏幕外。）
    ⚠ 每轮先**直接找**再滚：滚动是有副作用的手势，能不滚就不滚。
      （滚动本身踩过的坑见 `scroll_content` —— 坐标写死会把应用拖到后台，
        然后在**下一步**报成"找不到 Tab"，真因藏得很深。）
    """
    for _ in range(rounds):
        if tap_text_anywhere(text, exact=exact, tries=tries):
            return True
        scroll_content(times=1)
    return False


def tap_settings_entry():
    """点「我的」页里的「设置」入口（横屏下它在折线以下，要滚一屏）"""
    return tap_text_with_scroll("设置", exact=True, rounds=3, tries=4)


def card_present(bundle=None):
    """系统里有没有本应用的卡片（查 FormMgr）。"""
    return "FormRecord" in shell(f"hidumper -s FormMgr -a '-n {bundle or BUNDLE}'")


def ensure_card(bundle=None):
    """确保桌面上存在本应用的卡片；成功返回 True。

    ⚠ 卡片的生命周期和**应用安装**绑在一起 —— `bm uninstall` 时系统会把卡片
      从桌面一起删掉。所以**任何重装过应用的脚本，之后都不能假设桌面上还有卡片**。
      症状是 `find_form_node` 返回 None、报成「桌面上找不到卡片了」，
      而真因是"卡片在重装时被系统删了"，跟卡片功能一点关系都没有。
      （2026-09-22 实测：verify_ai 跑完接着跑 verify_multidevice，
        第 6 步就栽在这 —— 顺序一变就红。）

    走的是用户自己的那条路：我的 → 设置 → 「2×4 主卡」→「添加至桌面」。
    """
    bundle = bundle or BUNDLE
    if card_present(bundle):
        return True
    print("    桌面上没有卡片 → 切「我的」→「设置」→ 加 2×4 主卡")
    if not tap_tab("我的", wait=2):
        return False
    if not tap_settings_entry():
        print("    ⚠ 「我的」页里找不到「设置」入口")
        return False
    time.sleep(2.5)
    if not tap_text_with_scroll("2×4 主卡", exact=True, rounds=3, tries=4):
        print("    ⚠ 设置页里找不到「2×4 主卡」")
        return False
    time.sleep(5)
    add = find_text_node(dump_layout("cm"), "添加至桌面", exact=True)
    if add is None:
        print("    ⚠ 卡片管理页里找不到「添加至桌面」")
        return False
    tap(add[0], add[1], wait=7)
    return card_present(bundle)


def window_size():
    """当前窗口的 (宽, 高)，单位 px。取根节点 bounds —— 不写死分辨率，也不假设朝向。"""
    b = _bounds_of(dump_layout("win"))
    return ((b[2] - b[0], b[3] - b[1]) if b else None)


def scroll_content(px=None, times=1, x=None, frac=0.35):
    """把页面内容往上拖（= 露出下方内容）。坐标**按当前窗口算**。

    ⚠ 它的用途是解决"字在屏幕外"：`dumpLayout` **只返回可见节点**（见 2.1），
      竖屏能一屏放下的「我的」页，横屏放不下，设置入口就被顶到折线以下了。

    ⚠⚠ 但坐标**绝不能写死**（2026-09-22 修，代价是一整轮验收）：
      原实现是 `-m {x} 1200 {x} {1200-px}`，那个 1200 是照**竖屏 2760px 高**量的。
      横屏只有 1256px 高 ⇒ y=1200 落在**屏幕最底下 56px**，也就是**手势导航区**——
      这一拖实际触发的是"上滑回桌面"，应用被扔到后台，而脚本毫无察觉。
      后果全部报在**别的步骤**上：「我的」→「设置」找不到（滚动后也没有）、
      紧接着「点不到「复盘」Tab」、第 6 步「主界面一直没画出来」。
      每一条都把排错方向指向"控件匹配/文字匹配"，真因却是这一行把应用弄到后台去了。
      ⇒ **凡是跨步骤复用的手势，坐标必须从窗口尺寸派生。**

    新算法：
      · 起点 y = 85% 高（在竖屏的底部 Tab 栏之上、横屏的手势区之外）
      · 终点 y = 起点 − 35% 高
      · x 默认 55% 宽 —— 宽屏是「左导航 + 右内容」，取中间偏右能保证落点在内容区，
        不会拖到左侧 Tab 栏上（拖上去会被当成导航滑动）。
    """
    sz = window_size()
    if sz is None:
        return False
    w, h = sz
    x = int(w * 0.55) if x is None else x
    y0 = int(h * 0.85)
    y1 = y0 - (px if px is not None else int(h * frac))
    y1 = max(int(h * 0.10), y1)          # 别拖出屏幕顶端
    for _ in range(times):
        shell(f"uinput -T -m {x} {y0} {x} {y1} 700")
        time.sleep(1.2)
    return True


TAB_LABELS = ("快记", "地图", "复盘", "助手", "我的")


def ensure_main_ui(timeout=90, keep=None, autologin=True):
    """确保**应用在前台、且主界面已经画出来**（底部 Tab 栏在）。成功返回 True。

    为什么需要它：`uitest dumpLayout` 给的是**当前前台窗口**的树。
    应用还没画完（刚装完冷启动）、或者被 HOME 挤到后台时，dump 出来的是别的东西，
    于是"按文字找 Tab"必然落空 —— 报出来的却是「找不到底部 Tab」，指向完全错误的方向。

    ⚠ 默认会**把应用拉回前台**（`aa start`）。这一点对所有调用方都成立：
      只有想点应用内控件时才会来调用它，此时应用本来就该在前台。
      `aa start` 对已运行的进程走 `onNewWant`，**不会**重置登录态（见 EntryAbility）。

    `keep`：调用方自己判断"已经准备好了"的谓词，比如已经在设置页里就不该被拽回 Tab 首页。

    ⚠ 拉回前台时**必须带 `--pi lh_autologin 1`**（2026-09-22 修）。
      不带的话，只要这台机器上已经建过本地档案，`aa start` 冷启动会停在**解锁页**——
      那当然没有 Tab 栏，本函数就一路等到超时，报「主界面一直没画出来」。
      典型现场：第 6 步先 `aa force-stop` 再补卡片，于是报「找不到底部 Tab「我的」」，
      而"档案锁着"这件事从头到尾没在任何一句提示里出现过。
      `lh_autologin` 走的是**真实登录链**（见 Auth.selfTestLogin），不是绕过门；
      对已运行的进程也只走 `onNewWant`、不会踢掉现有会话。

      ★ 软拉回失效时会再升级成**冷启动硬恢复**一次（仅 `autologin=True` 时）：
        实测 `aa start`（→ onNewWant）在连跑负载下会**整段失效**，应用一直停在解锁页；
        冷启动（→ onCreate）是另一条路径。见函数体注释与 2026-09-23 现场。

      `autologin=False` 留给极少数真的要停在锁上的调用方。
    """
    t0 = time.time()
    resumed = False
    hardened = False
    last_ts = None
    while time.time() - t0 < timeout:
        lay = dump_layout("ui_ready")
        if keep is not None:
            if keep(lay):
                return True
        else:
            ts = texts_of(lay)
            last_ts = ts or last_ts
            if sum(1 for t in ts if t in TAB_LABELS) >= 3:
                return True
        # 给启动留一段观察时间再动手拉，避免把"正在启动"误判成"在后台"
        if not resumed and time.time() - t0 > 8:
            flag = " --pi lh_autologin 1" if autologin else ""
            shell(f"aa start -a EntryAbility -b {BUNDLE}{flag}")
            resumed = True
        # ★ 软拉回没生效 ⇒ 升级成**硬恢复**（冷启动）。
        #   `aa start` 对已在跑的进程只走 `onNewWant`，实测在连跑负载下会**整段失效**：
        #   应用一直停在解锁页，90s 过去了主界面还没画出来
        #   （2026-09-23 连跑现场：dump 到的一直是「欢迎回来 / selftest / 解锁 / 忘记密码？」）。
        #   冷启动走 `onCreate`，是完全不同的一条路径 —— 这条才真能救回来。
        #   ⚠ 只在 `autologin=True` 时做：`autologin=False` 的调用方**故意**要停在锁上，
        #     冷启动会把它们要的页面冲掉。
        elif autologin and not hardened and time.time() - t0 > timeout // 2:
            print(f"  ⚠ `aa start` 软拉回失效（已等 {time.time() - t0:.0f}s）"
                  f"→ 冷启动硬恢复一次")
            shell(f"aa force-stop {BUNDLE}")
            time.sleep(1.5)
            shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1")
            hardened = True
        time.sleep(1.5)
    # ⚠ 超时了要把「当时屏幕上到底是什么」打出来。
    #   只报一句「主界面没画出来」，等于把"停在解锁页 / 停在启动页 / 应用在后台"
    #   三种完全不同的原因糊成一条，排查只能靠猜（2026-09-22 连跑时踩到）。
    shown = [t for t in (last_ts or []) if t.strip()][:12]
    print(f"  ⚠ {timeout}s 内主界面一直没画出来。最后一次 dump 看到的文字：{shown or '（什么都没读到）'}")
    print(f"     对照：解锁页应有「欢迎回来」/「创建本地档案」；"
          f"主界面应有 Tab {list(TAB_LABELS)}")
    print(f"     软拉回已试：{'是' if resumed else '否'}；"
          f"冷启动硬恢复已试：{'是' if hardened else '否（autologin=False 不做）'}")
    return False


def pid_of(bundle=BUNDLE):
    """应用进程的 PID；不在跑返回空串。

    ⚠ 鸿蒙 `ps -ef` 的列是 `UID PID PPID C STIME TTY TIME CMD`，PID 在第 2 列。
    """
    out = shell(f"ps -ef | grep {bundle} | grep -v grep")
    for ln in out.splitlines():
        parts = ln.split()
        if len(parts) >= 2 and bundle in ln:
            return parts[1]
    return ''


def force_stop(bundle=BUNDLE, timeout=20):
    """强制停掉应用，并**等到进程表里确实没有它**。返回是否停干净。

    为什么不能只发一条 `aa force-stop` 就往下走（2026-09-22 实踩）：
    这台模拟器上报过 `force stop process successfully`，**3 秒后进程还在、PID 还变了**
    —— 被系统或桌面卡片又拉起来了。此时直接 `aa start`，
    所谓的"冷启动验证"验的其实还是同一个进程里残留的界面状态：
    「重启之后 XX 还在吗」这类断言全部失去意义，而且**它会绿得毫无破绽**。
    被自动拉起就再停一次，直到确认进程表里没有它。
    """
    shell(f"aa force-stop {bundle}")
    t0 = time.time()
    while time.time() - t0 < timeout:
        if pid_of(bundle) == '':
            return True
        time.sleep(1.5)
        shell(f"aa force-stop {bundle}")
    return pid_of(bundle) == ''


def enter_tab_shell(tries=4):
    """回到**拥有底部 Tab 的主界面**。二级页（设置）不占 Tab，必须先退出来。

    ⚠ 不做这一步的后果：脚本以为自己站在主界面上，于是按文字找「我的」Tab ——
      二级页当然没有 Tab，报出来的却是「找不到底部 Tab」，
      指向完全错误的方向（真因是"上一步留在二级页里没出来"）。
      2026-09-22 写头像验收时又栽了一次：截图截到的是设置页，
      于是"头像变了没有"变成了拿两个不同页面做差分，全盘歪掉。

    ⚠⚠ 按 BACK 之前必须**确认自己真的站在二级页上**（屏幕上有「‹」返回箭头）。
      第一版只要"没读到 Tab 栏"就按 BACK，于是 `dump_layout` 偶尔失败时
      （窗口正在切换 / 应用刚被拉到前台）会被误判成"在二级页"，
      在**快记页**这种根页面上连按 BACK 会把应用**直接退到桌面**。
      之后一路的报错都成了「找不到 XX」，而真因是"应用已经不在前台了"。
      —— dump 失败 ≠ 没有 Tab 栏；这两种情况必须分开处理。
    """
    for i in range(tries):
        lay = dump_layout(f"shell_{i}")
        if lay is None:
            time.sleep(2)
            continue
        ts = texts_of(lay)
        if sum(1 for t in ts if t in TAB_LABELS) >= 3:
            return True
        if "‹" not in ts:
            time.sleep(2)
            continue
        key("2")
        time.sleep(2)
    return False


def tap_tab(label, wait=2.0, tries=3):
    """点底部 Tab —— **按文字找，不用硬编码坐标**。

    ⚠ 这条是被 2026-09-22 加第五个 Tab（助手）逼出来的：
      之前每个脚本都记着一组 @觀察 `TAB_X = {"快记":157, "地图":471, ...}`，
      那是对**四等分**的宽度量出来的。一旦多插一个 Tab，每个格子变窄、中心全部平移，
      于是「我的」坐标正好落在新的「助手」上 —— 脚本点了不报错，只是下一步什么都找不到。
      这种失败最难查：安装、编译、日志全是对的。

    ✅ 所以改成对着 tabor 上的文字定位：**加多少个 Tab 都不用再动脚本**。

    ⚠ 两个前提：
      ① 必须先确认界面真的画出来了（Tab 栏在），否则这里的 dump 是上一屏的东西；
      ② Tab 文字要用 exact=True —— 「我的数据」「我的 stage」这类卡片也会被子串命中。
      ①现在由 `ensure_main_ui` 兜住了：刚装完冷启动 / 应用在后台都能自愈，
      不再依赖调用方"恰好"先等够了时间。
    """
    if not ensure_main_ui():
        print(f"  ⚠ 主界面一直没画出来，找不到底部 Tab「{label}」")
        return False
    for i in range(tries):
        lay = dump_layout(f"tab_{i}")
        hit = find_text_node(lay, label, exact=True)
        if hit is not None:
            tap(hit[0], hit[1], wait=wait)
            return True
        time.sleep(1.2)
    print(f"  ⚠ 找不到底部 Tab「{label}」")
    return False


def wait_ui_ready(timeout=45):
    """等主界面真的画出来（底部 Tab 栏至少出现 3 个标签）。"""
    t0 = time.time()
    while time.time() - t0 < timeout:
        ts = texts_of(dump_layout("boot"))
        if sum(1 for t in ts if t in TAB_LABELS) >= 3:
            return True
        time.sleep(1.5)
    return False


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
    shell(f"aa start -a {ABILITY} -b {BUNDLE} --pi lh_autologin 1")
    time.sleep(5)
    return True


def step3_create_form():
    print("\n== 3/7 卡片能否被系统创建（onAddForm） ==")
    # 「2×4 主卡」按钮在④之后挪进了设置页，所以路线是：我的 → 设置 → 往下翻。
    # ⛔ Tab 一律用 tap_tab（按文字定位）：加第五个 Tab 之后硬编码坐标已经平移了。
    tap_tab("我的")
    time.sleep(1.5)
    entry = find_text_node(dump_layout("w_profile"), "设置", exact=True)
    if entry is not None:
        tap(entry[0], entry[1], wait=2.5)
        time.sleep(1.5)
    lay = dump_layout("layout_profile")
    btn = find_text_node(lay, "主卡")
    if btn is None:
        # 设置页首屏不一定放得下桌面卡片那一块，往下翻一屏再试
        shell("uinput -T -m 628 1700 628 1200 800")
        time.sleep(1.2)
        lay = dump_layout("layout_profile2")
        btn = find_text_node(lay, "主卡")
    if btn is not None:
        cx, cy, src = btn[0], btn[1], "控件树"
    else:
        # 兜底再翻两屏：设置页比原来长，扫不到就多扫一会儿
        cx, cy, src = None, None, "像素"
        for _ in range(2):
            shell("uinput -T -m 628 1700 628 1200 800")
            time.sleep(1.2)
            lay = dump_layout("layout_profile3")
            btn = find_text_node(lay, "主卡")
            if btn is not None:
                cx, cy = btn[0], btn[1]
                break
        if btn is None:
            img = shot("widget_profile.jpeg")
            band = None
            for rgb in BTN_ACCENTS:          # 深浅两套都试，见 BTN_ACCENT 上面的说明
                band = find_band(img, rgb, tol=16, min_area=2000)
                if band is not None:
                    break
            if band is None:
                return check(False, "", "在设置页找不到『2×4 主卡』按钮")
            cx, cy = band[0], band[1]
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
    # 本步的输入改写库。两条可选路径，这里走**自检开关**（force-stop + 带参冷启动）：
    #   · 界面点「载入演示数据」：④ 之后它搬进了设置页，要点进去得
    #     「我的 → 设置 → 往下翻找按钮」，而这个模拟器上的长距离滚动本来就不可靠；
    #     失败时报错是"找不到按钮"，看着像功能坏了，其实是导航问题。
    #   · `aa start --pi lh_load_demo 1`：一次到位，且与 lh_mic_probe / lh_voice_dict 同一套惯例。
    # ⚠ 前提是开关路径要和界面路径做同样的事 —— EntryAbility.loadDemoAndSync 里
    #   必须也调用 WidgetRefresher.refreshAll()，否则"卡片没刷新"的锅会算在本步头上。
    shell(f"aa force-stop {BUNDLE}")
    time.sleep(1)
    clear_logs()
    shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1 --pi lh_load_demo 1")
    time.sleep(10)

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
