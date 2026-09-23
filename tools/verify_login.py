# -*- coding: utf-8 -*-
"""灯塔 · 本地档案（创建 / 解锁 / 卡片脱敏）验收

这套脚本要证明什么
------------------
不是"界面上多了个登录框"，而是四件**可以被证伪**的事：

1. **锁真的挡住了** —— 库里没档案时，冷启动停在「创建本地档案」而不是主界面。
2. **密码真的是唯一入口** —— 错密码进不去，而且失败后**必须还停在锁上**。
   （"报了个错但已经放行"是最恶心的假失败，必须专门排除。）
3. **密码真的没落明文** —— 这是"本地档案"这个功能唯一值钱的证据。
   设备上读不到应用私有目录（Permission denied + 没有 run-as），
   所以改成让应用自己把库里存的东西念进日志（`lh_auth_dump`），
   脚本拿密码原文去搜：**搜得到就是漏洞，搜不到才算过**。
4. **卡片真的脱敏了** —— 未解锁时桌面上不该出现公司名，解锁后又要恢复。
   只验"没解锁时卡住了"是不够的：那可能只是把卡片整个做没了，等于删功能。

⚠ 两个必须绕开的坑（都是实装实测踩出来的）
------------------------------------------
· **密码框会弹「安全键盘」**，它把整个表单上移、并把下面的输入框压成 2px 高
  （实测 `再输一次密码` 的 bounds 变成 `[98,1487][1158,1489]`）。
  所以**每次输入后都要收键盘再继续**，否则后面所有坐标都是错的 ——
  第一版就是栽在这：点「创建并进入」点在了键盘上，什么也没发生，
  看起来像"按钮没反应"。
· **收键盘用 Back**，但键盘没弹时 Back 会把应用退到后台。
  所以收完要确认还在登录页，不在就把它拉回来。
"""
import os
import re
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_widget as vw  # noqa: E402

BUNDLE = "com.wuit.lighthouse"
HAP = "entry-default-signed.hap"
HAP_DIR = "D:/work/DevEcoStudioProject/Lighthouse/entry/build/default/outputs/default"

USER = "zengyou"
PASS = "test123456"

HINT_USER = "怎么称呼你，如「小曾」"
HINT_PASS = "密码（至少 6 位）"
HINT_CONFIRM = "再输一次密码"

BTN_CREATE = "创建并进入"
BTN_UNLOCK = "解锁"

TITLE_CREATE = "创建本地档案"
TITLE_UNLOCK = "欢迎回来"
MAIN_MARK = "我的数据"
# ⚠⚠ 判断"在不在主界面"**必须**用下面这组底部 Tab 名字，不能用「我的数据」。
#
#   「我的数据」是「我的」Tab 里的内容，而解锁后默认停在**「快记」**Tab ——
#   屏幕上根本没有这四个字。第一版拿它当判据，于是：
#     · "没解锁时看不到主界面"（断言 not in）→ 通过（登录页确实没有）✓
#     · "解锁后进主界面"（断言 in）        → **失败**（快记 Tab 也没有）✗
#   两条断言同时"看起来合理"，但前者是假阳性 —— 它证明的是"页面上没有某段文字"，
#   而不是"锁拦住了主界面"。改用 Tab 栏：**只有主界面才会同时出现这些 Tab 名**。
TAB_NAMES = ("快记", "地图", "复盘", "助手", "我的")

# 演示数据里的公司名 + 事件类型标签。
# 卡片的标题是 `${company} ${事件标签}`，所以"有没有公司名"可以直接判脱敏有没有生效。
DEMO_COMPANIES = ("精测电子", "光庭信息", "中望软件", "鼎捷软件",
                  "用友网络", "金山办公", "达梦数据库", "明源云")
TYPE_LABELS = ("投递截止", "笔试", "面试", "其他")
# 卡片 UI 的脱敏前缀（见 WidgetData.build 的 mask）
MASK_WORD = "未解锁"


# ────────────────────────────────────────────────────────────── 基础动作

def hdc(*args, timeout=120):
    return subprocess.run([vw.HDC, *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=timeout)


_TAG = [0]


def tag(prefix="t"):
    _TAG[0] += 1
    return f"{prefix}{_TAG[0]}"


def screen():
    return " ".join(vw.texts_of(vw.dump_layout(tag("s"))))


def has(text):
    return text in screen()


def wait_for(text, tries=12, sleep=1.3):
    for _ in range(tries):
        if has(text):
            return True
        time.sleep(sleep)
    return False


def in_main_ui():
    """当前是不是已经进到主界面了（见 TAB_NAMES 上面那段说明）。

    双向判据：底部 Tab 栏在，且登录页的特征文字都不在了。
    单看前者可能被"登录页恰好也画了个同名文字"骗到；单看后者会把"界面画崩了"
    误判成"进去了"。两条一起才稳。
    """
    txt = screen()
    if TITLE_CREATE in txt or TITLE_UNLOCK in txt or BTN_UNLOCK in txt:
        return False
    return sum(1 for t in TAB_NAMES if t in txt) >= 3


def wait_main(tries=14, sleep=1.3):
    for _ in range(tries):
        if in_main_ui():
            return True
        time.sleep(sleep)
    return False


def tap_text(text, exact=True, tries=5):
    for _ in range(tries):
        lay = vw.dump_layout(tag("tp"))
        hit = vw.find_text_node(lay, text, exact=exact) if lay else None
        if hit is not None:
            vw.tap(hit[0], hit[1], wait=1.6)
            return True
        time.sleep(1.3)
    return False


def app_logs():
    return "\n".join(vw.logs("Lighthouse", tail=500))


def install():
    """卸载重装 = 清库 = 制造"这台设备上从来没建过档案"。

    ⚠ 卸载会连 RDB 一起删，这正是本脚本大多数步骤需要的前提
      （否则跑到第二次就已经有档案了，① 和 ④ 都无从测起）。
    """
    vw.shell(f"aa force-stop {BUNDLE}")
    time.sleep(1.2)
    hdc("uninstall", BUNDLE)
    time.sleep(2)
    out = subprocess.run([vw.HDC, "install", HAP], cwd=HAP_DIR,
                         capture_output=True, text=True, encoding="utf-8",
                         errors="replace", timeout=180)
    ok = "successfully" in (out.stdout or "").lower()
    print(f"  安装：{'成功' if ok else '失败 ' + (out.stdout or '')[-120:]}")
    time.sleep(2.5)
    return ok


def restart(extra=""):
    """冷启动。带 extra 就追加自检开关。"""
    vw.shell(f"aa force-stop {BUNDLE}")
    time.sleep(1.5)
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE}{extra}")
    time.sleep(9)


# ─────────────────────────────────────────── 输入（安全键盘那两个坑都在这）

def find_input(lay, hint):
    """按 placeholder 找输入框，返回中心坐标。

    ⚠ 为什么按 hint 而不是"取第 n 个输入框"：
      安全键盘一弹，表单整体上移，**被遮住的输入框 bounds 会被压扁**
      （实测 `再输一次密码` → 高 2px）。按顺序取会拿错人；
      按 hint 取，并且要求高度 > 20px，拿到的才是"现在真的能点"的那个。
    """
    if not lay:
        return None
    for n in vw.walk_nodes(lay):
        a = n.get("attributes", {})
        if "Input" in (a.get("type") or "") and (a.get("hint") or "").strip() == hint:
            b = vw._bounds_of(n)
            if b and (b[3] - b[1]) > 20:
                return ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)
    return None


def type_into(hint, text, tries=4):
    for _ in range(tries):
        pos = find_input(vw.dump_layout(tag("ti")), hint)
        if pos is not None:
            vw.shell(f"uitest uiInput inputText {pos[0]} {pos[1]} {text}")
            time.sleep(1.5)
            return True
        time.sleep(1.2)
    print(f"    ⚠ 找不到输入框「{hint}」")
    return False


def on_login_page():
    txt = screen()
    return TITLE_CREATE in txt or TITLE_UNLOCK in txt


def close_keyboard():
    """收起安全键盘。

    ⚠ 键盘没弹时 Back 会把应用退到后台（实测），所以按完要确认还在登录页 ——
      不在就拉回来。少了这一步，脚本会以"找不到按钮"的形式失败，
      而真因是"应用已经不在前台了"，两种症状差得很远。
    """
    vw.shell("uitest uiInput keyEvent Back")
    time.sleep(1.8)
    if not on_login_page():
        vw.shell(f"aa start -a EntryAbility -b {BUNDLE}")
        time.sleep(7)


def fill_create(user, p1, p2):
    """填创建页三个框。每填一个立刻收键盘。"""
    type_into(HINT_USER, user)
    close_keyboard()
    type_into(HINT_PASS, p1)
    close_keyboard()
    type_into(HINT_CONFIRM, p2)
    close_keyboard()


def fill_unlock(p):
    type_into(HINT_PASS, p)
    close_keyboard()


# ────────────────────────────────────────────────────────────── 卡片

def ensure_card():
    """确保桌面有一张卡片。

    没有卡片就没有 `updateForm`，也就没有「卡片已刷新 锁=N …」那条日志 ——
    而这正是本脚本判"脱敏有没有生效"的唯一依据。

    实现已收口到 `vw.ensure_card()`（2026-09-22）：卡片在 `bm uninstall` 时会被系统
    一起删掉，所以**重装过应用的脚本都得自己把卡片补回来**。这条需求不止本脚本有
    （verify_multidevice 第 6 步同样要），放在共享模块里才不会各写一份、各错一次。
    """
    return vw.ensure_card(BUNDLE)


def card_line():
    """取最近一条「卡片已刷新」日志，返回 (锁, 主位, 提示, 整行) 或 None。

    ⚠ 取整行是为了让"有没有泄露公司名"能在**整条日志**上判，
      而不是只看主位 —— 卡片还有 sub1/sub2/more 等字段，只盯主位会漏。
    ⚠ `提示` 是 `data['head']`（应用侧 2026-09-22 才加进日志的）。
      它存在的意义：脱敏前缀在**卡片 UI 上**才看得见，不把它带进日志，
      脚本就没法证明"未解锁"这三个字真的到了卡片，只能证明库里那串字符串对。
    """
    for line in reversed(vw.logs("卡片已刷新", tail=40)):
        m = re.search(r"锁=(\d) 主位=(.+?) 共\d+个节点(?: 提示=(.*))?", line)
        if m:
            return (m.group(1), m.group(2).strip(),
                    (m.group(3) or "").strip(), line.strip())
    return None


# ────────────────────────────────────────────────────────────── 主流程

def main():
    print("=" * 62)
    print("灯塔 · 本地档案（创建 / 解锁 / 卡片脱敏）验收")
    print("=" * 62)

    # ══ ① 锁真的挡住了
    print("\n-- ① 清库冷启动：停在锁上，而不是主界面 --")
    install()
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE}")
    time.sleep(9)
    vw.check(wait_for(TITLE_CREATE, tries=6),
             "冷启动停在「创建本地档案」—— 锁真的拦住了",
             "冷启动没停在创建页：锁没生效")
    vw.check(not in_main_ui(),
             "没解锁时主界面装不起来（底部 Tab 栏不在）",
             "没解锁就能看到主界面 —— 锁形同虚设")

    # ══ ② 短密码被拒
    print("\n-- ② 密码太短被拒 --")
    fill_create(USER, "123", "123")
    tap_text(BTN_CREATE)
    time.sleep(3)
    vw.check(wait_for("密码至少 6 位", tries=6),
             "3 位密码被拒绝（提示「密码至少 6 位」）",
             "短密码没有被拒绝")
    vw.check(TITLE_CREATE in screen(),
             "被拒后仍停在创建页",
             "被拒后离开了创建页 —— 可能已经放行了")

    # ══ ③ 两次不一致被拒
    #    重启是为了清空输入框（脚本没有可靠的"清空"手段，重启 8 秒换确定性）
    print("\n-- ③ 两次密码不一致被拒 --")
    restart()
    fill_create(USER, PASS, "test654321")
    tap_text(BTN_CREATE)
    time.sleep(3)
    vw.check(wait_for("两次输入的密码不一样", tries=6),
             "两次密码不一致被拒绝",
             "两次密码不一致却没有被拒绝")

    # ══ ④ 创建成功
    print("\n-- ④ 创建档案 --")
    restart()
    vw.clear_logs()
    fill_create(USER, PASS, PASS)
    tap_text(BTN_CREATE)
    time.sleep(4)
    vw.check(wait_main(),
             "创建后直接进主界面（底部 Tab 栏起来了）",
             "创建后没进主界面")
    # 进了主界面之后再切「我的」：这一步才用得上 MAIN_MARK ——
    # 它验证的是"数据页本身打得开"，不是"有没有进主界面"（两件事别混）。
    if vw.tap_tab("我的", wait=2):
        vw.check(wait_for(MAIN_MARK, tries=8),
                 "解锁后「我的」页正常打开（有「我的数据」）",
                 "进了主界面但「我的」页打不开")
    vw.check("本地档案已创建" in app_logs(),
             "日志确认「本地档案已创建」",
             "日志里没有创建记录 —— 界面进去了但库没写？")

    # ══ ⑤ 重启要解锁，不是重新创建
    print("\n-- ⑤ 重启后显示解锁页，而不是创建页 --")
    restart()
    vw.check(wait_for(TITLE_UNLOCK, tries=8),
             "重启后显示「欢迎回来」",
             "重启后没显示解锁页")
    txt = screen()
    vw.check(TITLE_CREATE not in txt,
             "已识别出本机有档案（没有再引导创建）",
             "已有档案却还在显示「创建本地档案」")
    vw.check(USER in txt,
             f"解锁页认得出是谁的档案（显示「{USER}」）",
             "解锁页没显示档案称呼")
    vw.check(not in_main_ui(),
             "重启后未解锁，主界面装不起来",
             "重启后没解锁就能看到主界面")

    # ══ ⑥ 错密码被拒
    print("\n-- ⑥ 错误密码被拒 --")
    fill_unlock("wrongpassword")
    tap_text(BTN_UNLOCK)
    time.sleep(4)
    vw.check(wait_for("密码不对", tries=7),
             "错误密码被拒绝（提示「密码不对」）",
             "错误密码没有被拒绝")
    vw.check(not in_main_ui(),
             "被拒后仍停在锁上，没有放行",
             "报了错但已经进主界面 —— 这是最危险的假失败")

    # ══ ⑦ 正确密码解锁
    print("\n-- ⑦ 正确密码解锁 --")
    restart()
    vw.clear_logs()
    fill_unlock(PASS)
    tap_text(BTN_UNLOCK)
    time.sleep(4)
    vw.check(wait_main(),
             "正确密码解锁并进入主界面",
             "正确密码也进不去")
    vw.check("已解锁" in app_logs(),
             "日志确认「已解锁」",
             "没有解锁日志")

    # ══ ⑧ 库里没有明文密码
    print("\n-- ⑧ 库里存的是派生值，不是密码原文 --")
    vw.clear_logs()
    restart(" --pi lh_auth_dump 1")
    text = app_logs()
    vw.check("档案自检：完成" in text,
             "档案自检跑完了（说明确实读到了库里的行）",
             "档案自检没跑起来 —— 这一大步的结论无效")
    vw.check(PASS not in text,
             f"日志里搜不到密码原文「{PASS}」",
             f"日志里出现了密码原文 —— 有一处把明文存下来了")
    m_hash = re.search(r"hash=([0-9a-f]+)\.\.len=(\d+)", text)
    vw.check(m_hash is not None and int(m_hash.group(2)) == 64,
             f"存的是 64 位十六进制派生值（{m_hash.group(1)}…）" if m_hash else "",
             "档案表里的 hash 形态不对 —— 要么没存派生值，要么算法不是 SHA256")
    m_salt = re.search(r"saltLen=(\d+)", text)
    vw.check(m_salt is not None and int(m_salt.group(1)) > 0,
             f"每行都有独立的盐（{m_salt.group(1)} 字符）" if m_salt else "",
             "没有盐 —— 相同密码会产生相同派生值，撞库就废了")

    # ══ ⑨ 解锁态：卡片显示完整信息
    print("\n-- ⑨ 已解锁：卡片显示完整信息（对照组）--")
    # ⚠ 先清库，再走自检登录。原因：`lh_autologin` 用的是**自检专用凭据**
    #   （Auth.SELFTEST_*），而上面那几步建的档案用的是脚本的密码 —— 两者不匹配，
    #   直接跑会得到「自检：自动登录失败（密码不对）」，看着像开关坏了。
    #   清库之后走的是 createAccount 分支，顺带把"自检能建档案"这条路径也覆盖了。
    install()
    vw.clear_logs()
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE}"
             " --pi lh_autologin 1 --pi lh_load_demo 1 --pi lh_dnd 0")
    time.sleep(15)
    vw.check("自检：自动登录成功" in app_logs(),
             "自检开关走的是**真实**注册/登录链路（不是绕过登录）",
             "自检自动登录没成功 —— 后面的卡片断言都不可信了")
    if not ensure_card():
        vw.check(False, "", "没能在桌面加上卡片 —— 卡片脱敏拿不到证据")
    else:
        time.sleep(8)
        row = card_line()
        if row is None:
            vw.check(False, "", "没等到「卡片已刷新」日志")
        else:
            lock, title, head, line = row
            vw.check(lock == "0",
                     "已解锁：卡片日志 锁=0",
                     f"已解锁但卡片仍报 锁={lock}")
            vw.check(any(c in title for c in DEMO_COMPANIES),
                     f"已解锁：卡片显示完整标题「{title}」",
                     f"已解锁但卡片标题里没有公司名：「{title}」")
            vw.check(MASK_WORD not in line,
                     "已解锁：卡片上没有脱敏字样",
                     f"已解锁但卡片仍带脱敏字样：「{line}」")

    # ══ ⑩ 未解锁态：卡片脱敏（本轮最重要的一条）
    print("\n-- ⑩ 未解锁：卡片必须脱敏 --")
    vw.clear_logs()
    restart()          # 不带 lh_autologin ⇒ 停在锁上 ⇒ 卡片应脱敏
    time.sleep(8)
    row = card_line()
    if row is None:
        vw.check(False, "", "重新锁上之后没等到卡片刷新日志")
    else:
        lock, title, head, line = row
        vw.check(lock == "1",
                 "未解锁：卡片日志 锁=1",
                 f"未解锁但卡片仍报 锁={lock} —— 锁没传到卡片")
        # ⚠ 在**整行**上找公司名，不只是主位：卡片还有 sub1/sub2/more，
        #   只盯主位的话，公司名从次要行漏出去也查不出来。
        leaked = [c for c in DEMO_COMPANIES if c in line]
        vw.check(len(leaked) == 0,
                 f"未解锁：卡片日志里没有任何公司名（主位显示「{title}」）",
                 f"未解锁却把公司名写在卡片上了：{leaked}")
        # ⚠ **不能用 `title in TYPE_LABELS`** —— 元组上的 `in` 是**整串相等**，
        #   而主位实际是「面试 明天 10:00」（类型 + 时间），永远不相等 ⇒ 断言恒假。
        #   第一版就这么写的：脱敏明明完全正确，却报「看不出是什么」。
        #   要问的是"还认不认得出这是什么事件"，所以必须 `any(t in title ...)`。
        kind = [t for t in TYPE_LABELS if t in title]
        vw.check(len(kind) > 0,
                 f"未解锁：主位保留了事件类型（「{title}」—— 看得出是{kind[0]}，看不出是哪家）"
                 "：是脱敏，不是删功能",
                 f"未解锁时主位变成了「{title}」，连事件类型都没了 —— 卡片是被做没了，不是脱敏")
        # 脱敏前缀必须**真的到卡片上**。只藏公司名、却不显示"锁着"，
        # 用户就不知道该去解锁看详情 —— 那是把功能做残，不是做隐私。
        vw.check(MASK_WORD in head,
                 f"未解锁：卡片提示行带了「{MASK_WORD}」字样（提示=「{head}」）—— 用户知道要解锁才看得到详情",
                 f"未解锁但卡片提示行没有任何锁的迹象（提示=「{head}」）—— 藏了公司名，却看不出在锁着")

    total = len(vw.RESULTS)
    ok = sum(1 for r in vw.RESULTS if r)
    print(f"\n{'=' * 62}")
    print(f"结果：{ok} 通过 / {total - ok} 失败")
    print("截图：tools/_shots/")
    print(f"{'=' * 62}")


if __name__ == "__main__":
    main()
