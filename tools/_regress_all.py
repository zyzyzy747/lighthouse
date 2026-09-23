# -*- coding: utf-8 -*-
"""灯塔 · 全量回归一条命令跑完（2026-09-22 加）。

背景：`lh_autologin` 自检开关被注入了**每一个**验收脚本的 `aa start` 行，
      登录门又加在了界面上 —— 于是"登录改了之后那批脚本还认不认路"必须整套重跑一遍。
      逐个手敲 12 条命令、再逐个翻结果，既慢又容易漏。

用法：
    python _regress_all.py                # 全部
    python _regress_all.py widget notify  # 只跑指定几个
    python _regress_all.py --parse        # ⭐ 不跑，只把已有的 _reg_*.txt 重新汇总
    python _regress_all.py --no-retry     # 关掉"红了自动单跑复验"

输出：每套一份 `_reg_<名字>.txt`，最后一张汇总表。
⚠ 判据取每套脚本自己打的那行总数，不自己解析断言。

★★ 连跑红 ⇒ 自动单跑复验（2026-09-22 加）

本工程的模拟器连跑半小时后负载很高，**固定 sleep 在负载下不够**，
于是反复出现「连跑红、单跑全绿」的假红：`voice`（14609ms 正好卡在旧的 15s 线上）、
`login`（解锁页 90s 没画出主界面）、`filter`（BACK 之后没回到快记页）都是同一类。
每次靠人手工逐套复验，既慢又容易漏。

所以把这条铁律写进脚本：**跑完一轮后，把红的几套集中单跑复验一次**，
汇总表里直接标成「连跑假红·单跑转绿」，人工只需盯**复验仍红**的那几套。

⚠ 复验转绿**不等于**没回归 —— 首轮的现场会被留成 `_reg_<名字>.first.txt`，
  要判断"到底红在哪"必须看那个文件（复验后的 `_reg_<名字>.txt` 已经是绿的了）。
"""
import os
import re
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

# 支持 --skip-build 的脚本（刚编译过就不必再编，省 20~60 秒/套）
SKIP_BUILD_OK = {"widget", "notify", "multidevice", "write"}

# 连跑红 ⇒ 是否自动单跑复验（见文件头）。--no-retry 可关。
RETRY_ON_RED = True

# 复验前让设备歇一会儿：假红的根因就是"设备刚从半小时连跑里出来"，
# 立刻重跑等于把同样的负载再压一遍，复验就没意义了。
SETTLE_S = 30

ALL = ["widget", "notify", "multidevice", "quickrecord", "jd",
       "filter", "voice", "voice_ui", "theme",
       "agent", "ai", "login", "layout", "avatar", "map",
       # ⚠ `layout` 排在这里是有意的：它读的正是「我的 / 助手」两页的最终版式，
       #   而且**这一套自己会 uninstall + install**（要干净的库才能验出
       #   「投出去 7 天没动静」卡，理由见 verify_layout.py 的【1】），
       #   所以必须排在依赖桌面卡片的那两套之后（widget / multidevice 在它前面）。
       # ⚠ `avatar` 与 `map` 一定放**最后**：它们自己 uninstall + install，
       #   而 `bm uninstall` 会连带删掉桌面卡片（见 skill 12.31）——
       #   排在 widget 前面会让"卡片还在不在"变成顺序敏感的假红。
       # ⚠ `map` 还多一层：它是**唯一会打真实网络请求**的一套（华为地点搜索）。
       #   断网 / 地图服务不可用时它必红，但那不代表代码坏了 ——
       #   先看 `地点解析` 日志是 search 还是 seed 兜底，别一上来就查代码。
       # ⚠ `voice_live` 故意不在默认列表里：它要**声音从宿主扬声器经空气进模拟器麦克风**，
       #   音量小 / 戴耳机 / 环境吵都会失败，而失败并不代表功能坏了
       #   （脚本自己的文件头就写着"别写进 CI"）。要跑就显式点它：
       #     python _regress_all.py voice_live
       ]

# ⚠ 各套脚本的收尾文案**不一样**，只认一种格式会让"全绿"被判成"没跑到收尾"。
#   实测三种并存：
#     结果：23/23 通过                 （widget / notify）
#     结果：通过 8 / 8，失败 0          （voice）
#     结果：26 通过 / 1 失败            （login）
_RES_PATTERNS = (
    (re.compile(r"结果：通过\s*(\d+)\s*/\s*(\d+)[，,]\s*失败\s*(\d+)"), "ok,total,ng"),
    (re.compile(r"结果：(\d+)\s*/\s*(\d+)\s*项?通过"), "ok,total"),
    (re.compile(r"结果：(\d+)\s*/\s*(\d+)\s*通过"), "ok,total"),
    (re.compile(r"结果：(\d+)\s*通过\s*/\s*(\d+)\s*失败"), "ok,ng"),
)


def parse_result(text):
    """从脚本输出里取 (通过, 失败)。取**最后一条**（有的脚本分多段跑）。"""
    got = None
    for line in text.splitlines():
        if "结果：" not in line:
            continue
        for pat, kind in _RES_PATTERNS:
            m = pat.search(line)
            if not m:
                continue
            if kind == "ok,total,ng":
                got = (int(m.group(1)), int(m.group(3)))
            elif kind == "ok,total":
                ok, total = int(m.group(1)), int(m.group(2))
                got = (ok, total - ok)
            else:
                got = (int(m.group(1)), int(m.group(2)))
    return got


def run(name):
    script = os.path.join(HERE, f"verify_{name}.py")
    if not os.path.isfile(script):
        return name, "缺脚本", 0.0, 0.0
    args = [PY, script]
    if name in SKIP_BUILD_OK:
        args.append("--skip-build")
    out_path = os.path.join(HERE, f"_reg_{name}.txt")
    t0 = time.time()
    with open(out_path, "w", encoding="utf-8") as f:
        subprocess.run(args, cwd=HERE, stdout=f, stderr=subprocess.STDOUT)
    return (name,) + read_one(out_path) + (time.time() - t0,)


def read_one(out_path):
    """读一份结果文件 → (判词, 耗时占位 0)。给 run() 和 --parse 共用。"""
    if not os.path.isfile(out_path):
        return "没有结果文件（没跑过？）", 0.0
    text = open(out_path, encoding="utf-8", errors="replace").read()
    got = parse_result(text)
    if got:
        ok, ng = got
        return ("全绿" if ng == 0 else f"{ng} 项失败（{ok} 通过）"), 0.0
    # 没有总数行 = 中途崩了。把最后几行带出来，别只报"失败"——
    # 崩溃点和"断言没过"是两种完全不同的排查方向。
    tail = [l for l in text.strip().splitlines() if l.strip()][-3:]
    return "没跑到收尾(" + " | ".join(tail)[:150] + ")", 0.0


def summarize(rows, title="汇总"):
    print("\n" + "=" * 78)
    print(f"{title}  {'脚本':<16}{'结果':<40}{'耗时'}")
    print("-" * 78)
    bad, good, flaky = 0, 0, 0
    for row in rows:
        name, verdict, dt = row[0], row[1], row[2]
        note = row[3] if len(row) > 3 else ""
        if verdict == "全绿":
            good += 1
        else:
            bad += 1
        if note:
            flaky += 1
        print(f"  verify_{name + '.py':<18}{(verdict + note):<40}{dt:>5.0f}s")
    print("=" * 78)
    print(f"总计 {len(rows)} 套，{good} 套全绿，{bad} 套要人看")
    if flaky:
        print(f"其中 {flaky} 套是「连跑红了、单跑复验转绿」—— 负载抖动，别当代码问题")
        print("   （首轮现场留在 `_reg_<名字>.first.txt`，要看真因去翻那个文件）")


def main():
    global RETRY_ON_RED
    argv = sys.argv[1:]
    if "--no-retry" in argv:
        RETRY_ON_RED = False
        argv = [a for a in argv if a != "--no-retry"]
    if "--parse" in argv:                      # 只重新读盘上已有的结果
        argv = [a for a in argv if a != "--parse"]
        want = argv or ALL
        summarize([(n,) + read_one(os.path.join(HERE, f"_reg_{n}.txt"))
                   for n in want], title="（重新汇总，未重跑）")
        return
    want = argv or ALL
    rows = []
    red = []
    for i, name in enumerate(want, 1):
        print(f"[{i}/{len(want)}] verify_{name}.py …", flush=True)
        name, verdict, _unused, dt = run(name)
        rows.append([name, verdict, dt, ""])
        if verdict != "全绿":
            red.append(name)
        print(f"          → {verdict}  ({dt:.0f}s)", flush=True)

    # ── 连跑红 ⇒ 集中单跑复验（见文件头「连跑红 ⇒ 自动单跑复验」）
    if red and RETRY_ON_RED:
        print("\n" + "-" * 78)
        print(f"⚠ {len(red)} 套连跑红：{' / '.join('verify_' + n + '.py' for n in red)}")
        print("  按工程铁律「连跑红 ≠ 代码坏」——先把首轮现场存成 .first.txt，"
              f"歇 {SETTLE_S}s 再逐套单跑复验。")
        print("  ⚠ 判断是不是真回归，必须看 .first.txt（复验后的同名文件已经被覆盖成绿的）")
        print("-" * 78, flush=True)
        time.sleep(SETTLE_S)
        for name in red:
            cur = os.path.join(HERE, f"_reg_{name}.txt")
            first = os.path.join(HERE, f"_reg_{name}.first.txt")
            try:
                if os.path.isfile(cur):
                    os.replace(cur, first)
            except OSError:
                pass
            print(f"[复验] verify_{name}.py …", flush=True)
            name, verdict2, _unused, dt2 = run(name)
            for row in rows:
                if row[0] == name:
                    row[2], row[3] = dt2, ("（连跑假红·单跑转绿）" if verdict2 == "全绿"
                                           else "（复验仍红 ⇒ 当回归处理）")
                    if verdict2 != "全绿":
                        row[1] = verdict2
                    break
            print(f"          → {verdict2}  ({dt2:.0f}s)", flush=True)

    summarize(rows)


if __name__ == "__main__":
    main()
