#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
灯塔 Lighthouse · AI 链路端到端验证

验证什么（这是「AI 功能到底通没通」的唯一硬证据）：
  1. 应用能装上、能冷启动、RDB 建库成功
  2. 「载入演示数据」写出 8 条投递 + 3 条复盘样本
  3. 在复盘页点「生成能力雷达」→ 云端或本地引擎产出六维结果
  4. 结果真的落库（review.radar_json 非空、score_avg 合理）
  5. 界面不切页就自动刷新（截图 MD5 变化）

判据分离原则（踩坑换来的）：
  - WAL 字节数证明「写进去了」
  - 截图 MD5 证明「刷新了」
  两者必须分开看，因为"写了但没刷新"和"压根没写"指向完全不同的故障。

用法:
  python verify_ai.py              # 完整跑一遍（重装 + 灌数据 + 生成雷达）
  python verify_ai.py --keep       # 不重装，直接在现有数据上验证
  python verify_ai.py --no-radar   # 只到"灌完演示数据"为止
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

HDC = r"D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
BUNDLE = "com.wuit.lighthouse"
ABILITY = "EntryAbility"
DB_DIR = "/data/app/el2/100/database/com.wuit.lighthouse/entry/rdb"
HAP_DIR = r"D:\work\DevEcoStudioProject\Lighthouse\entry\build\default\outputs\default"
HAP = "entry-default-signed.hap"

HERE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(HERE, "_shots")
DBDUMP = os.path.join(HERE, "_dbdump")

# 应用调色板（与 resources/{base,dark}/element/color.json 保持一致）
#
# ⚠⚠ **两套都必须留**：应用是**跟随系统深浅色**的（颜色走 base/ 与 dark/ 两套资源），
#   只写深色那一套，模拟器一旦处在浅色模式，"按颜色找蓝底按钮"就全部落空，
#   报出来的是「复盘页找不到「生成能力雷达」入口」—— 而截图里三个蓝按钮排得整整齐齐。
#   实测浅色 lh_primary=#1F6FEB、深色 lh_primary=#4A9EFF，红通道差 43，远超 tol=20。
#   （2026-09-22 实测踩到：全量回归里 ai 这一套挂在这，单看截图完全看不出问题。）
#
# ★ 根治办法不是"把两套色都列上"，而是**首选控件树按文字找** ——
#   见 find_radar_entry()：Button 节点自带 text='生成能力雷达' 且 clickable=true，
#   这条路与主题无关。颜色只留作兜底。
C_PRIMARY_DARK = (0x4A, 0x9E, 0xFF)
C_PRIMARY_LIGHT = (0x1F, 0x6F, 0xEB)
C_PRIMARY = C_PRIMARY_DARK          # 旧引用保持可用
C_ACCENT_DARK = (0xFF, 0xB0, 0x20)
C_ACCENT_LIGHT = (0xB2, 0x6A, 0x00)
C_ACCENT = C_ACCENT_DARK
C_OK = (0x3D, 0xD6, 0x8C)
C_DANGER = (0xFF, 0x5C, 0x5C)

# 底部 Tab：⛔ 硬编码坐标已作废（原先对着四等分屏宽量出来，加第五个 Tab 后每格变窄、中心平移）。
#    现在一律按文字定位，实现统一在 verify_widget.tap_tab —— 以后再加 Tab 也不用改脚本。

_fails: list = []
_oks: list = []


# ───────────────────────── 基础工具 ─────────────────────────

def hdc(*args, timeout=90):
    p = subprocess.run([HDC] + list(args), capture_output=True, timeout=timeout)
    return p.stdout.decode("utf-8", "ignore").strip()


def shell(cmd, timeout=90):
    return hdc("shell", cmd, timeout=timeout)


def ok(msg):
    _oks.append(msg)
    print(f"  \u2713 {msg}")


def bad(msg):
    _fails.append(msg)
    print(f"  \u2717 {msg}")


def info(msg):
    print(f"    {msg}")


def step(n, total, title):
    print(f"\n== {n}/{total} {title}")


def tap(x, y, wait=1.6):
    shell(f"uinput -T -c {x} {y}")
    time.sleep(wait)


def tap_tab(name, wait=2.0):
    """点底部 Tab。

    实现统一放进 verify_widget.tap_tab（按文字定位），这里只是转发 ——
    ⛔ 以前是 `tap(TAB_X[name], TAB_Y)`，坐标对着**四个等分 Tab**量的：
      加第五个 Tab（助手）之后每格变窄、中心平移，那组坐标全部指错，
      而且点下去一声不响，要等后面每一步都找不到控件才暴露出来（2026-09-22）。
    """
    import verify_widget as vw
    return vw.tap_tab(name, wait=wait)


def shot(name):
    os.makedirs(SHOTS, exist_ok=True)
    shell("snapshot_display -f /data/local/tmp/_v.jpeg")
    subprocess.run([HDC, "file", "recv", "/data/local/tmp/_v.jpeg", name],
                   cwd=SHOTS, capture_output=True)
    path = os.path.join(SHOTS, name)
    if not os.path.isfile(path):
        bad(f"截图失败 {name}")
        return ""
    return path


def md5(path):
    if not path or not os.path.isfile(path):
        return ""
    import hashlib
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def wal_size():
    out = shell(f"stat -c %s {DB_DIR}/lighthouse.db-wal")
    m = re.search(r"(\d+)", out)
    return int(m.group(1)) if m else -1


def find_blocks(img_path, rgb, tol=24, min_area=2000):
    """按颜色找矩形色块，返回按 y 从上到下排序的块列表"""
    if not img_path or not os.path.isfile(img_path):
        return []
    arr = np.asarray(Image.open(img_path).convert("RGB"))
    diff = np.abs(arr.astype(np.int16) - np.array(rgb, dtype=np.int16))
    mask = (diff <= tol).all(axis=2)
    if mask.sum() == 0:
        return []

    rowsum = mask.sum(axis=1)
    bands = []
    in_b, start = False, 0
    for y in range(mask.shape[0]):
        if rowsum[y] > 0 and not in_b:
            in_b, start = True, y
        elif rowsum[y] == 0 and in_b:
            in_b = False
            if y - start >= 8:
                bands.append((start, y - 1))
    if in_b:
        bands.append((start, mask.shape[0] - 1))

    out = []
    for (y0, y1) in bands:
        sub = mask[y0:y1 + 1]
        colsum = sub.sum(axis=0)
        xs = np.where(colsum > 0)[0]
        if len(xs) == 0:
            continue
        x0, x1 = int(xs.min()), int(xs.max())
        area = int(sub.sum())
        if area < min_area:
            continue
        out.append({
            "cx": (x0 + x1) // 2, "cy": (y0 + y1) // 2, "area": area,
            "x0": x0, "y0": y0, "x1": x1, "y1": y1,
            "w": x1 - x0 + 1, "h": y1 - y0 + 1,
        })
    out.sort(key=lambda b: b["y0"])
    return out


def pull_db():
    os.makedirs(DBDUMP, exist_ok=True)
    for f in ["lighthouse.db", "lighthouse.db-wal", "lighthouse.db-shm"]:
        subprocess.run([HDC, "file", "recv", f"{DB_DIR}/{f}", f],
                       cwd=DBDUMP, capture_output=True)
    return os.path.join(DBDUMP, "lighthouse.db")


def query(sql):
    import sqlite3
    con = sqlite3.connect(pull_db())
    try:
        cur = con.cursor()
        return list(cur.execute(sql))
    finally:
        con.close()


# ───────────────────────── 主流程 ─────────────────────────

def ensure_device():
    print("\n== 0/6 检查设备")
    t = hdc("list", "targets")
    if not t:
        bad("没有可用设备，先在 DevEco 里启动模拟器")
        return False
    ok(f"设备在线：{t.splitlines()[0]}")
    return True


def install(keep):
    print("\n== 1/6 安装")
    hap = os.path.join(HAP_DIR, HAP)
    if not os.path.isfile(hap):
        bad(f"找不到 hap 产物：{hap}")
        return False
    info(f"{os.path.getsize(hap)} 字节")

    if not keep:
        out = hdc("uninstall", BUNDLE)
        info(f"卸载旧版（同时清空数据库）：{out.splitlines()[-1] if out else 'ok'}")
        time.sleep(1.5)

    # ⚠ 必须 cwd 到 hap 目录再用相对文件名：
    #   hdc 会把传入的绝对路径拼在 cwd 后面（D:\...\tools\D:\...\x.hap），
    #   传相对名才是唯一可靠的方式。
    p = subprocess.run([HDC, "install", "-r", HAP],
                       cwd=HAP_DIR, capture_output=True, timeout=180)
    out = (p.stdout.decode("utf-8", "ignore") + p.stderr.decode("utf-8", "ignore")).strip()
    info(out.replace("\n", " | ")[:300])

    if "success" not in out.lower():
        bad("安装失败")
        return False
    ok("安装成功")

    shell(f"aa force-stop {BUNDLE}")
    time.sleep(1)
    out = shell(f"aa start -a {ABILITY} -b {BUNDLE} --pi lh_autologin 1")
    if "successfully" not in out.lower() and "start" not in out.lower():
        bad(f"启动失败：{out}")
        return False
    ok("已启动")
    time.sleep(4)
    return True


def load_demo():
    print("\n== 2/6 灌入演示数据")
    # 「载入演示数据」已搬进设置页 —— 原来在「我的」页按蓝底颜色试探按钮的写法随之失效。
    # 改走 lh_load_demo 开关：force-stop 后带参冷启动，一次到位；写没写成功看 hilog。
    shell(f"aa force-stop {BUNDLE}")
    time.sleep(1)
    out = shell(f"aa start -a {ABILITY} -b {BUNDLE} --pi lh_autologin 1 --pi lh_load_demo 1")
    if "successfully" not in out.lower() and "start" not in out.lower():
        bad(f"带参启动失败：{out}")
        return False
    time.sleep(10)
    text = shell("hilog -x 2>/dev/null | grep -E '演示数据已载入' | tail -3")
    if "演示数据已载入" not in text:
        bad("hilog 里没有「演示数据已载入」—— lh_load_demo 开关没生效")
        return False
    ok("数据已写入（lh_load_demo 开关）")

    apps = query("SELECT COUNT(*) FROM application")[0][0]
    reviews = query("SELECT COUNT(*) FROM review")[0][0]
    events = query("SELECT COUNT(*) FROM event_node")[0][0]
    info(f"落库结果：投递 {apps} 条 · 复盘 {reviews} 条 · 节点 {events} 个")

    if apps >= 8 and reviews >= 3:
        ok("演示数据完整（8 投递 + 3 复盘样本）")
        return True
    bad(f"数据不完整：期望 8 投递 / 3 复盘，实际 {apps} / {reviews}")
    return False


def find_radar_entry():
    """找「生成能力雷达」入口，返回 (cx, cy, 来源说明) 或 None。

    ★ **首选控件树**：Button 节点自带 `text='生成能力雷达'` 且 `clickable=true`，
      实测 `[105,790][1151,916]`，整块都能点。这条路**与深浅色主题无关**，
      也不会因为按钮从"蓝底"变成"描边"而失效。
    兜底才是截图找色：两套调色板都试，且先大后小试面积门槛
      （未分析=蓝底大块；已分析=底 + PRIMARY 字，只是小块）。
    """
    import verify_widget as vw
    lay = vw.dump_layout("ai_review")
    for label in ("生成能力雷达", "查看能力雷达", "重新生成"):
        hit = vw.find_text_node(lay, label, exact=True)
        if hit:
            return hit[0], hit[1], f"控件树·「{label}」"

    img = shot("ai_02_review_list.jpeg")
    for tint, rgb in (("深色", C_PRIMARY_DARK), ("浅色", C_PRIMARY_LIGHT)):
        for min_area in (8000, 400):
            blocks = find_blocks(img, rgb, tol=20, min_area=min_area)
            if blocks:
                info(f"控件树里没有按钮文案，退回截图找色：{tint} PRIMARY / min_area={min_area}")
                return blocks[0]["cx"], blocks[0]["cy"], f"截图找色·{tint}·{min_area}"
    return None


def gen_radar():
    print("\n== 3/6 生成能力雷达")
    tap_tab("复盘")
    time.sleep(1.5)          # 切页有 180ms 动画 + 列表异步 reload，dump 前先让它落定

    hit = find_radar_entry()
    if hit is None:
        bad("复盘页找不到「生成能力雷达」入口，截图 ai_02_review_list.jpeg 可查")
        return False
    tx, ty, how = hit
    info(f"入口定位：{how} → ({tx}, {ty})")

    img = shot("ai_02_review_list.jpeg")
    before_shot = img
    before_wal = wal_size()
    t0 = time.time()
    tap(tx, ty, wait=2)
    # 云端最多 12 秒熔断；本地引擎瞬时。等足 14 秒再判定。
    time.sleep(14)
    elapsed = time.time() - t0
    after_wal = wal_size()

    info(f"点击后 WAL = {after_wal}（{'+' if after_wal > before_wal else ''}{after_wal - before_wal}）")

    # 日志里找结果
    logs = shell("hilog -x 2>/dev/null | grep -iE 'Lighthouse' | tail -25")
    interesting = [ln for ln in logs.splitlines()
                   if any(k in ln for k in ["雷达", "分析", "AI", "radar", "降级", "engine"])]
    if interesting:
        print("    相关日志：")
        for ln in interesting[-10:]:
            info(f"    {ln.strip()[:150]}")

    after_shot = shot("ai_03_radar_result.jpeg")

    # 硬证据 1：数据库里 radar_json 非空
    rows = query("SELECT id, round, score_avg, LENGTH(radar_json) FROM review ORDER BY id")
    analyzed = [r for r in rows if r[3] > 2]
    info(f"复盘共 {len(rows)} 条，其中已分析 {len(analyzed)} 条")
    for r in rows:
        info(f"    id={r[0]} {r[1]} 均分={r[2]} radarJson={r[3]} 字节")

    if analyzed:
        ok(f"雷达已落库：review#{analyzed[0][0]} score_avg={analyzed[0][2]}")
    else:
        bad("没有任何一条复盘写出 radar_json —— 分析链路没跑通")

    # 硬证据 2：界面刷新（截图变化）
    if md5(after_shot) and md5(after_shot) != md5(before_shot):
        ok(f"界面已刷新（截图 {os.path.getsize(before_shot)} → {os.path.getsize(after_shot)} 字节，用时 {elapsed:.0f}s）")
    else:
        bad("界面没有变化 —— 分析结果没有渲染出来")

    # 硬证据 3：走的是云端还是本地引擎
    #   日志行形如：雷达已生成 id=1 cloud=true avg=41
    #   ⚠ 这一条决定"云端路径到底通没通"，是配好 key 之后最该看的判据。
    #   只看没有报错是不够的：无 key / 网络失败都会**静默降级**到本地引擎，
    #   结果是"有结果、但根本没走云端"——必须用 cloud=true 才能证明走了云端。
    m = re.search(r"雷达已生成\s+id=(\d+)\s+cloud=(true|false)\s+avg=(\d+)", logs)
    if m:
        went_cloud = m.group(2) == "true"
        info(f"分析来源：cloud={m.group(2)}  id={m.group(1)}  均分={m.group(3)}")
        if ARGS.expect == "cloud":
            if went_cloud:
                ok(f"★ 云端路径已验证通过（cloud=true，用时 {elapsed:.0f}s）")
            else:
                bad("期望云端，实际走了本地引擎 —— 看上面日志的『云端不可用/云端分析失败』原因行")
        elif ARGS.expect == "local":
            if not went_cloud:
                ok("本地引擎路径已验证通过（cloud=false，符合预期）")
            else:
                bad("期望本地，实际走了云端 —— 若在测降级，说明 key 没被抹掉或网络意外可用")
        else:
            ok(f"分析完成（来源 cloud={m.group(2)}）")
    else:
        bad("日志里没有『雷达已生成』这行 —— 无法判定走了云端还是本地引擎")

    return bool(analyzed)


def show_radar_detail():
    print("\n== 4/6 雷达内容抽查")
    rows = query("SELECT id, radar_json FROM review WHERE LENGTH(radar_json) > 2 ORDER BY id LIMIT 1")
    if not rows:
        bad("没有可解析的 radar_json")
        return False
    import json
    data = json.loads(rows[0][1])

    # 落库格式有两种：
    #   v2 信封：{v:2, analysis:{...}, fromCloud, engine, latencyMs, tokens, analyzedAt}
    #   v1 裸格式：radar_json 直接就是 ReviewAnalysis 本身
    is_env = "analysis" in data
    body = data.get("analysis", data)
    if is_env:
        ok(f"落库为 v2 信封（来源可追溯：cloud={data.get('fromCloud')} "
           f"engine={data.get('engine')} tokens={data.get('tokens')}）")
        if not data.get("engine"):
            bad("信封里 engine 为空 —— 来源信息没写进去，重进应用就看不到来源标注了")
    else:
        info("落库为 v1 裸格式（无来源元数据）")

    dims = body.get("dimensions", [])
    info(f"summary: {body.get('summary', '')[:60]}")
    info(f"topWeakness: {body.get('topWeakness', '')}")
    info(f"nextActions: {len(body.get('nextActions', []))} 条")
    print("    六维分数：")
    for d in dims:
        info(f"    {d['key']:<10} {d['label']:<16} {d['score']:>3}  证据「{d['evidence'][:26]}」")
    if len(dims) == 6:
        ok("六维结构完整")
    else:
        bad(f"维度数量不对：{len(dims)}（应为 6）")
        return False
    if any(d["score"] > 0 for d in dims):
        ok("至少一个维度有分，说明不是空转")
    else:
        bad("六个维度全是 0，分析没起作用")
        return False
    return True


def shot_after_restart():
    print("\n== 5/6 冷启动复查（来源标注是否随落库保留）")
    # 这一条专门验「信封格式」：来源信息如果只活在页面的 @State 里，
    # 冷启动一过就没了，界面会退回「已完成分析」这种无信息量的中性文案。
    shell(f"aa force-stop {BUNDLE}")
    time.sleep(1.5)
    shell(f"aa start -a {ABILITY} -b {BUNDLE} --pi lh_autologin 1")
    time.sleep(5)
    tap_tab("复盘")
    shot("ai_05_review_restarted.jpeg")

    rows = query("SELECT id, radar_json FROM review WHERE LENGTH(radar_json) > 2 ORDER BY id")
    if not rows:
        bad("冷启动后没有任何已分析记录 —— 落库没生效")
        return False
    import json
    data = json.loads(rows[0][1])
    if "analysis" in data and data.get("engine"):
        ok(f"冷启动后仍读得出来源：cloud={data.get('fromCloud')} engine={data.get('engine')}")
        ok(f"（界面截图 ai_05_review_restarted.jpeg 应能看到来源标注，不再是「未记录来源」）")
        return True
    bad("冷启动后读不出源信息 —— radar_json 还是 v1 裸格式或 engine 为空")
    return False


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true", help="不重装、不清库，在现有数据上验证")
    ap.add_argument("--no-radar", action="store_true", help="只验证到灌入演示数据")
    ap.add_argument("--expect", choices=["cloud", "local", "any"], default="any",
                    help="期望的分析来源：cloud=必须走云端 / local=必须降级本地 / any=不判")
    ARGS = ap.parse_args()

    total = 4 if ARGS.no_radar else 4
    print("=" * 68)
    print("灯塔 Lighthouse · AI 链路端到端验证")
    print("=" * 68)

    if not ensure_device():
        sys.exit(1)
    if not install(ARGS.keep):
        sys.exit(1)
    if not load_demo():
        sys.exit(1)
    if ARGS.no_radar:
        pass
    else:
        gen_radar()
        show_radar_detail()
        shot_after_restart()

    print("\n" + "=" * 68)
    # ⚠ 收尾必须是**可解析**的固定格式。原来只打「结果：全部通过 / N 项未通过」，
    #   全量回归的汇总器读不出通过数，就把它判成"没跑到收尾" ——
    #   明明跑完了、断言也过了，却和"脚本崩了"分不开。
    print(f"结果：{len(_oks)} 通过 / {len(_fails)} 失败")
    if _fails:
        for f in _fails:
            print(f"  ✗ {f}")
    print(f"截图与数据库快照见 {SHOTS}")
    print("=" * 68)
    if _fails:
        sys.exit(1)


if __name__ == "__main__":
    ARGS = None
    main()
