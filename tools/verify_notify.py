#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
「灯塔」节奏哨兵的端到端验证。

回答的问题是：提醒到底会不会真的响，以及**在应用没有打开的时候**还会不会响。

八个断点，每个都有硬判据（hilog / 系统控件树 / 进程列表），不靠"看起来正常"：

  1  权限与代码真的进了包        hap 内有 PUBLISH_AGENT_REMINDER；Sentinel/KvRepo 编进 abc
  2  通知授权                   UI 显示「● 通知已开启」（未授权时自动点掉系统弹窗）
  3  卡片已在桌面               没有卡片的定时唤醒就没有心跳，后面全靠它
  4  提醒真的发出去了            载入演示数据 → hilog「发出 N 条」N≥1
  5  通知真的落到系统通知栏      下拉通知中心 → 控件树里读得到提醒文案
  6  同一档位不重复打扰          再评估一次 → 「发出 0 条」
  7  ★ 应用退出后仍能提醒        改提前量清空去重 → **重启模拟器** → 等待系统自己把卡片
                                拉起来 → 断言提醒由卡片进程发出，且全程没有应用进程
                                （本步约 2 分钟：这是唯一忠实的触发方式，见下方注释）
  8  能力取舍如实呈现            代理提醒被拒 + 自检结论 + UI 降级提示（不假装排上了）

用法：
    python verify_notify.py                # 全流程（会卸载重装，清空数据库）
    python verify_notify.py --skip-build   # 跳过编译（源码没改时用）
    python verify_notify.py --keep         # 不重装，在现有数据上验证
    python verify_notify.py --from 7       # 只跑第 7、8 步

⚠ 第 7 步为什么要重启模拟器（踩过的坑，别再改回去）：
  想验证"应用没打开也能提醒"，就必须让**系统自己**去唤醒卡片进程。试过的手段都无效：
    · `aa start -a EntryFormAbility -b <bundle>` —— 命令回报 start ability successfully，
       `ps` 里也确实出现了 `com.wuit.lighthouse:form`，但**那个进程根本没执行我们的代码**：
      hilog 里既没有 onCreate 也没有 onAddForm，一条日志都没有
      （推断只是 appspawn 拉了个缓存进程，没有真正跑扩展）。
      只看 `ps` 会得出"卡片进程起来了"的错误结论 —— 这类假阳性最害人。
    · `hidumper -s FormMgr` 只有查询类选项（-h/-b/-v/-s/-t/-n/-i/-r/-a），没有强制刷新。
  唯一忠实的做法是重启：桌面与卡片由系统恢复，:form 进程被系统创建并跑完整个生命周期。
  而且它顺带给出最干净的证据 —— **重启后 hilog 缓冲区是空的、通知栏也是空的**，
  于是每一条相关日志和每一条通知都只可能来自卡片进程。
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_widget as vw                                   # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")

HDC = vw.HDC
PROJECT = vw.PROJECT
TOOLS = vw.TOOLS
SHOTS = vw.SHOTS
BUNDLE = vw.BUNDLE
ABILITY = vw.ABILITY
HAP_DIR = vw.HAP_DIR
HAP = vw.HAP

check = vw.check
shell = vw.shell
RESULTS = vw.RESULTS

TAB_PROFILE = (1099, 2560)

# 提醒文案的特征串：只要通知栏里出现其中之一，就说明通知真的落到了系统
NOTIFY_MARKS = ["还有不到", "还没标记完成", "开始 ·", "还有 "]


# ---------------------------------------------------------------- 辅助

# ★ 滚动手势：三个候选各有一个坑，最后是量出来选的（别再凭感觉改回去）
#
#   · `uinput -T -m ... 350`          ⏱ 0.6s  —— 快，但惯性会把内容一次甩过多屏。
#     踩过的坑：屏 0 还停在「提前量」，一次滑动后屏 1 直接到「演示数据」，
#     中间的「开始前 1 小时 / 免打扰 / 立刻评估提醒」整块被跳过 ——
#     dumpLayout 看不到它，脚本报"找不到按钮"，而按钮其实好好的。
#   · `uitest uiInput swipe ... 200`  ⏱ 17.7s —— 不跳屏，但**一次 locate 要 4 分钟**：
#     1100px ÷ 200px/s = 5.5s 的手势，而命令实测耗时是手势时长的 3 倍左右，
#     再乘上 locate_text 的 8 次翻页 + 6 次回顶 ⇒ 整个脚本 20 分钟起步（真发生过）。
#   · `uitest uiInput dircFling 2`    —— 实测**完全不动**（这个页面上方向参数无效），别用。
#
#   最终方案：**小位移 + 长 keep time** 的 `-T -m`（500px / 800ms，⏱ 1.05s）——
#   位移小到惯性甩不过一屏，实测连续 3 次逐屏推进、相邻两次内容有重叠 ⇒ 不会漏。
TO_TOP   = "uinput -T -m 628 900 628 2000 350"      # 回顶：惯性无害，越快越好
SEE_BELOW = "uinput -T -m 628 1700 628 1200 800"    # 往下看一屏：慢拖，不跳屏


def scroll_to_top(times=5):
    """把当前页滚回顶部。

    必须先回顶：`uitest dumpLayout` 只返回**当前可见**的控件节点，
    页面停在底部时上面的控件根本不在树里，往下翻多久都找不到。
    「我的」页顺序是 我的数据 → 面试复盘 → 桌面卡片 → 节奏哨兵 → 演示数据 → AI → 关于，
    哨兵面板在中间偏下，踩过的坑就是"页面停在底部还继续往下翻"。

    这里用**带惯性的快速手势**且多滚几次：回顶时甩过头是无害的（到顶就停住），
    所以怎么快怎么来 —— 每次 0.6s，5 次 3 秒，比一个低速拖动还便宜。
    """
    for _ in range(times):
        shell(TO_TOP)
        time.sleep(0.25)
    time.sleep(0.3)


def locate_text(text, exact=False, tries=6):
    """先回顶、再往下翻，返回文字控件的 (cx, cy, bounds)；找不到返回 None。不点击。

    `tries` 给 6 是够的：整页约 7 屏，扣掉回顶那次 dump 已经能看到 1 屏。
    """
    scroll_to_top()
    for i in range(tries):
        hit = vw.find_text_node(vw.dump_layout(f"locate_{i}"), text, exact=exact)
        if hit is not None:
            return hit
        shell(SEE_BELOW)
        time.sleep(0.85)
    return None


def tap_text(text, exact=False, tries=6):
    """在页面上找文字控件并点它。

    比记死坐标可靠：哨兵面板的 y 会随上面几张卡片的高度变化整体移动。
    """
    hit = locate_text(text, exact=exact, tries=tries)
    if hit is None:
        return False
    vw.tap(hit[0], hit[1], wait=2.5)
    return True


def text_on_screen(text):
    """页面上有没有这段文字（会先回顶再往下翻，只看可见节点）。"""
    return locate_text(text) is not None


def all_logs(tail=400):
    return vw.logs("Lighthouse", tail=tail)


def open_notify_panel(tries=4):
    """下拉通知中心，返回控件树。

    ⚠ 手势偶发不生效（尤其刚开机、桌面还在铺的时候）。失效时 dump 出来的是**桌面**
      （里面是「设置 / 图库 / 文件管理」这些图标），这时去断言"通知栏里没有提醒"
      就会误报。所以这里自查一遍：看到桌面标志就重来。
    """
    lay = None
    for i in range(tries):
        shell("uinput -T -m 628 15 628 1900 500")
        time.sleep(2.5)
        lay = vw.dump_layout(f"notify_panel{i}")
        texts = vw.texts_of(lay)
        desktop_marks = ("图库", "文件管理", "日历", "设置")
        if sum(1 for t in texts if t in desktop_marks) >= 2:
            print("    （下拉没展开，重试）")
            time.sleep(1.5)
            continue
        return lay
    return lay


def uptime_secs():
    """设备开机时长（秒）；读不到返回 -1。

    ⚠ `cat /proc/uptime` 在本机是 **Permission denied**（新版本把 /proc 收紧了），
      `/proc/version`、`/proc/sys/kernel/random/boot_id` 同样被拒 —— 这条路走不通。
      但 busybox 的 **`uptime` 命令可用**，输出形如：
          `17:58:49 up 15 min,  0 users,  load average: 0.40, 0.49, 0.62`
          `up 2 days,  3:04,  0 users, ...`
      解析它才是本机唯一能拿到开机时长的办法。
    """
    try:
        out = shell("uptime", timeout=20)
    except Exception:
        return -1.0
    m = re.search(r"up\s+(?:(\d+)\s+days?,\s*)?(\d+):(\d+)", out)
    if m:
        days = int(m.group(1) or 0)
        return float(days * 86400 + int(m.group(2)) * 3600 + int(m.group(3)) * 60)
    m = re.search(r"up\s+(\d+)\s+min", out)
    if m:
        return float(int(m.group(1)) * 60)
    return -1.0


def reboot_and_wait(timeout=360):
    """重启模拟器并等到它真的起来（返回重启后的 uptime 秒数，失败返回 -1）。

    ⚠ 不能只等 `hdc list targets`：模拟器**从头到尾都在设备列表里**，
      那个信号永远不告诉你"已经重启完了"（上一轮就是这么被蒙过去的）。
      唯一骗不了人的判据是**开机时长被清零** —— 内核确实重新起了一次。
      起来之后再等 `bootevent.boot.completed`，最后留一段时间给桌面铺开 + 系统重建卡片。
    """
    print("  重启模拟器（系统会把桌面和卡片一起恢复，这一步才有说服力）…")
    shell("reboot")
    time.sleep(18)                      # 先给它时间真正下去
    up = -1.0
    t0 = time.time()
    while time.time() - t0 < timeout:
        up = uptime_secs()
        if 0 < up < 180:
            break
        time.sleep(4)
    if not (0 < up < 180):
        print(f"  ✗ 没等到开机时长清零（读到 uptime={up:.0f}）")
        return -1.0
    print(f"  内核已重启（uptime={up:.0f}s），等开机完成…")
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if "true" in shell("param get bootevent.boot.completed", timeout=15):
                break
        except Exception:
            pass
        time.sleep(3)
    time.sleep(18)                      # 桌面铺开 + 系统发起卡片渲染
    return up


def wait_log(pattern, timeout=180, tail=800):
    """轮询等日志里出现某个模式，返回 (全文, 命中行)。超时返回 ("", None)。"""
    t0 = time.time()
    while time.time() - t0 < timeout:
        text = "\n".join(all_logs(tail=tail))
        m = re.search(pattern, text)
        if m:
            return text, m.group(0)
        time.sleep(5)
    return "\n".join(all_logs(tail=tail)), None


def app_foreground(wait=3):
    """确保应用在前台。

    步与步之间可能停在桌面、卡片管理页或通知中心上 —— 那时候去点底部 Tab
    是点在壁纸/系统 UI 上，**不报任何错**，下一步就静默失败（最难查的一类）。
    """
    shell(f"aa start -a {ABILITY} -b {BUNDLE}")
    time.sleep(wait)


TAB_LABELS = ("快记", "地图", "复盘", "我的")


def wait_ui_ready(timeout=45):
    """等应用真的把界面画出来（底部 Tab 栏出现）。

    ⚠ **冷启动比看起来慢**：尤其是刚装完的第一次启动，建表 + 载入种子数据期间
      Index.ets 只渲染一个「正在点亮…」的转圈，Tabs 压根没建。
      这时候去点底部 Tab 是点在空气上（不报错），随后所有"按文字找控件"的步骤
      全部找不到 —— 表现为"授权按钮不见了"这种莫名其妙的失败。
      实测踩过一次：整轮 31 项里挂了 19 项，全是这一个原因级联下来的。
    """
    t0 = time.time()
    while time.time() - t0 < timeout:
        ts = vw.texts_of(vw.dump_layout("boot"))
        if sum(1 for t in ts if t in TAB_LABELS) >= 3:
            return True
        time.sleep(1.5)
    print("  ⚠ 等不到 Tab 栏，界面可能没起来")
    return False


def goto_profile(wait=2.0, timeout=30):
    """回到应用并切到「我的」页（哨兵面板在这里）。

    三件事都必须等：① 应用在前台 ② 界面已经画出来（Tab 栏在）
    ③ 点了 Tab 之后「我的」页的内容真的渲染完（切页动画 180ms + reload 是异步的）。
    """
    app_foreground()
    wait_ui_ready()
    vw.tap(*TAB_PROFILE, wait=wait)
    t0 = time.time()
    while time.time() - t0 < timeout:
        ts = vw.texts_of(vw.dump_layout("profile_ready"))
        if "我的数据" in ts:
            return True
        time.sleep(1.2)
    return False


def close_notify_panel():
    shell("uinput -K -d 2 -u 2")
    time.sleep(1.5)


def proc_cmds():
    """`ps -ef` 里所有进程的命令行（CMD 字段）。

    ⚠ 不能简单 `grep <bundle>`：**我们自己的注入命令行里也含 bundle 名**
    （`hdc shell "aa force-stop com.wuit.lighthouse; aa start -a EntryAbility …"`），
    会被当成"应用还活着" —— 上一轮就是这么假报了一次「应用进程还在」。
    必须取 CMD 字段整串比较，别在整行里找子串。
    """
    out = []
    for line in shell("ps -ef").splitlines():
        parts = line.split()
        if len(parts) >= 8:
            out.append(" ".join(parts[7:]))
    return out


def main_procs():
    """应用主进程（CMD 就是 bundle 名）。"""
    return [c for c in proc_cmds() if c == BUNDLE]


def form_procs():
    """卡片进程（CMD 是 bundle:form）。用完即退，别把"启动后消失"当失败。"""
    return [c for c in proc_cmds() if c == f"{BUNDLE}:form"]


# ---------------------------------------------------------------- 断点

def step1_packaged():
    print("\n== 1/8 权限与代码是否真的进了包 ==")
    hap = os.path.join(HAP_DIR, HAP)
    if not os.path.isfile(hap):
        return check(False, "", f"找不到 hap：{hap}")
    z = zipfile.ZipFile(hap)
    mj = json.loads(z.read("module.json").decode("utf-8"))
    perms = [p.get("name", "") for p in mj["module"].get("requestPermissions", [])]
    ok = check("ohos.permission.PUBLISH_AGENT_REMINDER" in perms,
               "声明了 PUBLISH_AGENT_REMINDER（代理提醒，普通权限）",
               "module.json 里没有 PUBLISH_AGENT_REMINDER")
    ok = check("ohos.permission.INTERNET" in perms, "网络权限仍在", "网络权限被弄丢了") and ok
    abc = [n for n in z.namelist() if n.endswith("ets/modules.abc")]
    size = z.getinfo(abc[0]).file_size if abc else 0
    ok = check(len(abc) == 1 and size > 100 * 1024,
               f"业务代码已编入 modules.abc（{size // 1024} KB）",
               "modules.abc 缺失或过小，代码没编进去") and ok
    return ok


def step2_grant():
    print("\n== 2/8 通知授权 ==")
    # ⚠ 这一步是整条链路的**总开关**：没授权时 Sentinel.evaluate() 会直接 return 0，
    #   卡片心跳、前台评估、去重表全都不动，后面 4~8 步会以各种"看起来像功能坏了"
    #   的方式失败（实测见过一次：31 项挂 19 项，全是这一个原因级联的）。
    #   所以这里允许重试，失败时 main() 直接中止，别浪费十分钟跑出个假结论。
    for attempt in range(1, 4):
        goto_profile()
        if text_on_screen("通知已开启"):
            return check(True, "通知已授权（UI 显示「● 通知已开启」）", "")

        print(f"  未授权 → 点「去开启」触发系统弹窗（第 {attempt} 次）")
        if not tap_text("去开启"):
            print("    找不到「去开启」→ 页面可能还没起来，重来")
            continue
        allow = None
        for _ in range(10):
            time.sleep(1.2)
            allow = vw.find_text_node(vw.dump_layout("perm_dialog"), "允许", exact=True)
            if allow is not None:
                break
        if allow is None:
            print("    系统授权弹窗没出现 → 重来")
            continue
        vw.tap(allow[0], allow[1], wait=4)
        for _ in range(10):
            if text_on_screen("通知已开启"):
                return check(True, "点「允许」后通知已开启（后续提醒才有可能发出来）", "")
            time.sleep(1.2)
        print("    点完仍未开启 → 重来")
    return check(False, "",
                 "3 次都没能把通知权限打开 —— 后面 4~8 步必然静默失败，先修这里")


def step3_card_on_desktop():
    print("\n== 3/8 卡片已在桌面（心跳的来源） ==")
    dump = shell(f"hidumper -s FormMgr -a '-n {BUNDLE}'")
    if "FormRecord" not in dump:
        print("  桌面上没有卡片 → 先去加一张")
        goto_profile(wait=2)
        tap_text("2×4 主卡", exact=True)
        time.sleep(5)
        lay = vw.dump_layout("mgr")
        add = vw.find_text_node(lay, "添加至桌面", exact=True)
        if add is None:
            return check(False, "", "卡片管理页里找不到「添加至桌面」")
        vw.tap(add[0], add[1], wait=6)
        dump = shell(f"hidumper -s FormMgr -a '-n {BUNDLE}'")
    ok = check("FormRecord" in dump and "rhythm_card" in dump,
               "系统 FormMgr 里有 rhythm_card 记录", "FormMgr 里查不到卡片")
    ok = check("RENDERED" in dump, "卡片状态 RENDERED", "卡片未渲染") and ok
    m = re.search(r"updateDuration \[(\d+)\]", dump)
    ms = int(m.group(1)) if m else -1
    ok = check(ms == 1800000,
               f"定时刷新 = {ms // 60000} 分钟（这就是哨兵的心跳周期）",
               f"updateDuration={ms}，心跳周期不对") and ok
    return ok


def step4_fire():
    print("\n== 4/8 提醒真的发出去了 ==")
    goto_profile()
    vw.clear_logs()
    if not tap_text("载入演示数据", exact=True):
        return check(False, "", "找不到「载入演示数据」按钮")
    time.sleep(8)

    text = "\n".join(all_logs())
    # ⚠ 不能取第一条匹配：「载入演示数据」会触发**多次**评估，第一条往往是
    #   "数据还没写完就评估"的那一次（发出 0 条），取首条会误判成"一条都没发出去"。
    fired_list = [int(x) for x in re.findall(r"哨兵评估\([^)]*\) 完成，发出 (\d+) 条", text)]
    fired = max(fired_list) if fired_list else -1
    ok = check(fired >= 1,
               f"哨兵发出 {fired} 条本地提醒（本步共 {len(fired_list)} 次评估）",
               f"哨兵发出 {fired} 条，一条都没发出去（评估 {len(fired_list)} 次：{fired_list}）")
    ok = check("即时通知已发出" in text, "通知已提交给系统", "没有提交通知") and ok
    m2 = re.search(r"档位=(\w+)", text)
    ok = check(m2 is not None, f"按档位触发（档位={m2.group(1) if m2 else '?'}）",
               "没有出现档位触发的日志") and ok
    return ok


def step5_in_panel():
    print("\n== 5/8 通知真的落到系统通知栏 ==")
    goto_profile(wait=1.5)
    lay = open_notify_panel()
    texts = vw.texts_of(lay)
    hits = [t for t in texts if any(k in t for k in NOTIFY_MARKS)]
    ok = check(len(hits) >= 1, f"通知栏里读到了提醒文案：{hits[0] if hits else ''}",
               f"通知栏里没有灯塔的提醒（读到 {len(texts)} 条文字）")
    titles = [t for t in texts if "光庭" in t or "精测" in t or "明源" in t]
    ok = check(len(titles) >= 1,
               f"通知标题是节点名（{'/'.join(sorted(set(titles))[:2])}）",
               "通知里没有节点标题") and ok
    vw.shot("notify_panel.jpeg")
    close_notify_panel()
    return ok


def step6_dedupe():
    print("\n== 6/8 同一档位不重复打扰 ==")
    goto_profile()
    vw.clear_logs()
    # exact=True：预览行里也有「还有不到 2 天」这类文字，子串匹配会点错节点
    if not tap_text("立刻评估提醒", exact=True):
        return check(False, "", "找不到「立刻评估提醒」按钮")
    time.sleep(5)
    text = "\n".join(all_logs())
    # 取**最后一条**：手动评估是这一屏最后一个动作，前面对应的是别的心跳，不能混进来
    ms = re.findall(r"哨兵评估\(手动\) 完成，发出 (\d+) 条，去重表 (\d+) 条", text)
    ok = check(len(ms) >= 1, f"手动评估执行了（{len(ms)} 次）", "手动评估没有执行")
    fired, sent_n = (int(ms[-1][0]), int(ms[-1][1])) if ms else (-1, -1)
    ok = check(fired == 0, f"再评估一次发出 0 条（去重生效，去重表 {sent_n} 条）",
               f"重复发了 {fired} 条 —— 去重没生效，会反复打扰") and ok
    ok = check(sent_n > 0, f"去重表里有 {sent_n} 条记录",
               "去重表是空的，说明记录没落库") and ok
    return ok


def step7_offline_heartbeat():
    print("\n== 7/8 ★ 应用退出后仍能提醒（卡片心跳） ==")
    print("  本步会重启模拟器，让**系统自己**去唤醒卡片进程（约 2 分钟）")
    goto_profile()
    vw.clear_logs()

    # 构造「该发未发」：改提前量 → save() 会清空去重表，但应用侧不会立刻评估（只重排系统提醒），
    # 于是"已经进入档位、却还没通知过"这个状态被留了下来。
    #
    # ⚠ 必须保证**真的变了一个值**：save() 只在 leadHours 变化时才清去重表。
    #   死点同一个选项（上一轮脚本就是这么栽的）日志会写「去重表保留」，
    #   场景根本构造不出来，最后表现为"卡片进程没发出提醒"——查错方向完全被带偏。
    #   先点 1 小时再点 2 天：无论起点是哪个，第二次点击一定发生了变化。
    if not tap_text("1 小时", exact=True):
        return check(False, "", "找不到「1 小时」提前量选项")
    time.sleep(3)
    vw.clear_logs()
    if not tap_text("2 天", exact=True):
        return check(False, "", "找不到「2 天」提前量选项")
    time.sleep(3)
    text = "\n".join(all_logs())
    ok = check("去重表已清空" in text, "改提前量后去重表已清空（构造出「该发未发」）",
               "改提前量没有清空去重表，无法构造验证场景 —— 见 save() 的 leadChanged 条件")
    if not ok:
        return False

    # ---------------------------------------------------------------- 交给系统
    up = reboot_and_wait()
    ok = check(up > 0, f"模拟器已重启（开机时长={up:.0f}s，说明内核确实重新起了一次）",
               "重启后没能确认内核重启（开机时长没被清零）") and ok

    # 等卡片心跳的日志出现（系统恢复桌面时会去重建卡片，:form 进程随之起来）
    text, hit = wait_log(r"哨兵评估\(卡片心跳\) 完成，发出 \d+ 条", timeout=180)
    ok = check(hit is not None, f"卡片进程跑了心跳评估（{hit}）",
               "重启后没等到卡片心跳 —— 桌面卡片可能没被恢复") and ok
    if hit is None:
        print("      —— 当前日志尾部 ——")
        for l in text.splitlines()[-12:]:
            print("      |", l)

    # 决定性判据之一：这次评估发生在**应用主进程不存在**的时候
    alive = main_procs()
    ok = check(len(alive) == 0, "应用主进程不存在（重启后没有任何应用被自动拉起）",
               f"应用进程居然在跑：{alive}") and ok
    leaked = [l for l in text.splitlines()
              if "ui ready" in l or "哨兵(前台)" in l or "哨兵(数据变更)" in l
              or "onWindowStageCreate" in l]
    ok = check(len(leaked) == 0,
               "全程没有应用进程参与（日志里没有 ui ready / 前台评估 / 窗口创建）",
               f"应用进程其实也起来了：{leaked[:2]}") and ok

    # 判据之二：卡片进程是**自己**把库初始化起来的（不同进程，不共享内存）
    ok = check("form: db ready" in text or "form: onCreate" in text or "onAddForm" in text,
               "卡片进程自己初始化了数据库（跨进程读的是同一份 RDB）",
               "日志里看不到卡片进程的初始化痕迹") and ok

    # 判据之三：提醒条数 ≥1
    m = re.search(r"哨兵评估\(卡片心跳\) 完成，发出 (\d+) 条", text) if hit else None
    fired = int(m.group(1)) if m else -1
    ok = check(fired >= 1, f"卡片进程独立发出 {fired} 条提醒",
               f"卡片进程没发出提醒（读到 fired={fired}）") and ok

    # 判据之四：真的落到了系统通知栏
    # 重启后通知栏本来是空的，所以这里读到的每一条都只可能来自卡片进程
    lay = open_notify_panel()
    texts = vw.texts_of(lay)
    hits = [t for t in texts if any(k in t for k in NOTIFY_MARKS)]
    ok = check(len(hits) >= 1, f"系统通知栏里确实有这条提醒：{hits[0] if hits else ''}",
               "通知栏里没有新提醒（重启后通知栏是空的，所以这里读到就一定是刚发的）") and ok
    vw.shot("notify_offline.jpeg")
    close_notify_panel()
    return ok


def step8_degrade_honest():
    print("\n== 8/8 代理提醒如实降级（不假装排上了） ==")
    # ⚠ 顺序是这一步的全部难点：自检**每个进程只跑一次**（Sentinel.diagnosed）。
    #   应用一启动，onForeground 里那次 sync 就会把自检跑掉、把结论写进日志；
    #   如果先 `aa start` 再 `clear_logs`，那唯一的自检结论正好被我们亲手擦掉，
    #   脚本随后读到"缺少自检结论"—— 而自检明明跑过了（上一轮就是这么假报的）。
    #   所以：**先清日志，再拉进程**，让自检的日志落在我们读的窗口里。
    vw.clear_logs()
    shell(f"aa force-stop {BUNDLE}")
    time.sleep(3)
    shell(f"aa start -a {ABILITY} -b {BUNDLE}")
    text, hit = wait_log(r"代理提醒自检：", timeout=60)
    ok = check(hit is not None, "应用启动后的那次同步触发了自检",
               "没等到自检日志（自检可能被前面的进程消耗掉了）")

    text = "\n".join(all_logs(tail=800))
    ok = check("1700002" in text, "日志里有系统的拒绝码 1700002", "日志里没有 1700002") and ok
    ok = check("代理提醒自检：系统内已有 0 条" in text,
               "自检说明：系统内 0 条却仍被拒 → 与参数无关",
               "缺少自检结论") and ok
    ok = check("探针同样被拒" in text,
               "连倒计时探针也被拒 → 是本机没有代理提醒配额",
               "探针结论缺失") and ok
    ok = check("系统代理提醒不可用" in text,
               "日志里如实写了降级，没有假装排上",
               "日志里没有降级记录") and ok

    goto_profile(wait=3)
    ok = check(text_on_screen("系统级代理提醒不可用"),
               "UI 上明确写了降级，而不是假装已排上",
               "UI 上没有降级提示 —— 这是最危险的情况：用户以为会被提醒") and ok
    vw.shot("sentinel_panel.jpeg")
    return ok


# ---------------------------------------------------------------- 主流程

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-build", action="store_true", help="跳过编译")
    ap.add_argument("--keep", action="store_true", help="不卸载重装，保留数据")
    ap.add_argument("--from", type=int, default=1, dest="from_step", help="从第几步开始")
    args = ap.parse_args()

    print("=" * 62)
    print("灯塔 · 节奏哨兵端到端验证")
    print("=" * 62)

    if args.from_step <= 1:
        step1_packaged()
    if args.from_step <= 2:
        if not vw.step2_install(args):
            print("\n安装失败，后续断点无法进行")
            return
        if not step2_grant():
            print("\n通知没授权 ⇒ 后面每一步都会静默失败（evaluate 直接 return 0），"
                  "跑下去只会得到一堆误导性的 ✗，所以在这里停住")
            print(f"结果：{sum(1 for r in RESULTS if r)}/{len(RESULTS)} 通过（已中止）")
            return
    if args.from_step <= 3:
        step3_card_on_desktop()
        step4_fire()
        step5_in_panel()
        step6_dedupe()
    if args.from_step <= 7:
        step7_offline_heartbeat()
    if args.from_step <= 8:
        step8_degrade_honest()

    print("\n" + "=" * 62)
    passed = sum(1 for r in RESULTS if r)
    print(f"结果：{passed}/{len(RESULTS)} 通过")
    if passed < len(RESULTS):
        print("存在未通过项，逐条看上面的 ✗")
    print("=" * 62)


if __name__ == "__main__":
    main()
