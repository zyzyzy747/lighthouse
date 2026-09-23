# -*- coding: utf-8 -*-
"""投递快记 · 列表筛选 + 「下一个节点」 验收

覆盖三件事：
  ① 卡片上真的画出了「下一个节点」（类型 · 时间 + 倒计时），且落在卡片自己的区间里
  ② 筛选真的生效（关键词搜索 → 清空恢复 → 聚合筛选「进行中」「有安排」）
  ③ 没排节点的记录不会出现在「有安排」里（负向由 ⑥ 的计数 + 排除项覆盖）

为什么用「进行中 / 有安排」这两个按钮做主要靶子：
  表单里的状态选择器和卡片状态标签也叫「面试」「笔试」——
  按文字点会先点到它们头上，改的是表单状态，不是筛选条件。
  「进行中」「有安排」这两个标签全页面唯一，不会误伤。

演示数据 8 条，节点分布（脚本里的期望值就是照这个写的）：
  精测电子 面试  +18h   → 显示
  光庭信息 笔试  +44h   → 显示
  明源云   截止  +120h  → 显示
  其余 5 条（中望/鼎捷/用友/金山/达梦）**都没有节点** → 不显示

⚠ 第一版把「用友网络」当成"已结束但有节点"的样本 —— 其实它第 9 个参数是 0，
  根本没排节点。读这种长参数表要**数到第 9 个**，别照注释猜。
  同时这也说明：**不该按状态藏节点**。漏掉一个真实面试的代价，
  远大于多显示一行；节点自带的 done 标记才是唯一真值来源（节点页划掉即消失）。

⚠⚠ 两个把第一版验收带沟里的坑，都留在这儿别再踩：
  1. **软键盘**：往搜索框打完字键盘会弹上来，盖住下半屏 ——
     ① 卡片"看不见"，会误判成没渲染；
     ② 后续 swipe_up 的落点 (628,2000) 正好压在键盘上，**变成在往输入框里打字**
        （实测搜到 box 里莫名多了 "5"/"55555"，筛选计数一路归零）。
     打完字必须 `hide_keyboard()`（BACK 键）再继续。
  2. **文字要先去重**：列表滚动时同一张卡会在多屏 dump 里重复出现，
     不去重的话"有几行倒计时"会数成 16（真值 3）。
     所以节点行改用**按卡片纵向区间**逐卡判定，而不是全屏计数。
  3. **长距离滚动不可靠**：想"滚到精测电子那张卡"（列表最后一张）时，
     实测连续 7 次 dump 内容一模一样 —— 手势被吞了，脚本却以为自己滚了。
     结论：断言尽量只用**当前屏第一张卡**（不用滚就完整可见），
     非要覆盖全列表就用 collect_texts() 那种"边 dump 边滚 + 去重"的扫描。
     另外滚动落点别贴屏幕上下缘（会被系统手势/Tabs 抢走，实测被送去过「我的」页）。

⚠ 全程不切 Tab：切走再回来 @State 可能被重建，筛选条件会被重置，
   「清空」按钮跟着消失 —— 验收脚本会因此误判成功能没做出来。
"""
import sys
import os
import re
import time
import subprocess

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_widget as vw  # noqa: E402

BUNDLE = "com.wuit.lighthouse"
HAP = r"D:\work\DevEcoStudioProject\Lighthouse\entry\build\default\outputs\default\entry-default-signed.hap"

# 卡片上「下一个节点」那行的型别（与 Types.ets 的 EVENT_TYPE_LIST 标签一致）
NODE_LABELS = ("面试", "笔试", "投递截止", "其他")

OK = 0
FAIL = 0


def check(cond, good, bad):
    global OK, FAIL
    if cond:
        OK += 1
        print(f"  ✓ {good}")
    else:
        FAIL += 1
        print(f"  ✗ {bad}")
    return bool(cond)


def hdc(*args):
    return subprocess.run([vw.HDC, *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace")


def bounds(a):
    if not a.get("bounds"):
        return None
    nums = [int(v) for v in re.findall(r"-?\d+", a["bounds"])]
    return nums if len(nums) == 4 else None


def walk(lay):
    stack = [lay]
    while stack:
        n = stack.pop()
        yield n
        for c in (n.get("children") or []):
            stack.append(c)


def hit(lay, text, exact=True):
    """按文字找控件，返回 bounds 列表（按屏幕从上到下排序）"""
    hits = []
    for n in walk(lay):
        a = n.get("attributes", {})
        t = (a.get("text") or "").strip()
        ok = (t == text) if exact else (text in t)
        b = bounds(a)
        if ok and b:
            hits.append(b)
    hits.sort(key=lambda b: (b[1], b[0]))
    return hits


def rect(lay, text, exact=True):
    h = hit(lay, text, exact)
    return h[0] if h else None


def tap_rect(b):
    vw.shell(f"uinput -T -c {(b[0] + b[2]) // 2} {(b[1] + b[3]) // 2}")


def tap(lay, text, exact=True):
    b = rect(lay, text, exact)
    if b is None:
        return False
    tap_rect(b)
    return True


def swipe_up():
    """⚠ 落点固定在中段 (628,2350)→(628,1450)。

    原来用 (628,2000)→(628,1100)：列表滚到边界时这个手势**会被系统/Tabs 吃掉** ——
    实测把人送去了「我的」页，还下拉出过通知中心，于是后面的断言全对着错误的界面，
    报出来的却是"找不到清空按钮"。手势留在中段就稳。
    """
    vw.shell("uinput -T -m 628 2350 628 1450 400")
    time.sleep(1.0)


def swipe_down():
    vw.shell("uinput -T -m 628 1450 628 2350 400")
    time.sleep(1.0)


def on_quick_tab(lay):
    return rect(lay, "投递快记") is not None


def ensure_quick_tab():
    """每步开头的自查：swipe 偶尔会把页面带走，先确认还在快记页"""
    lay = vw.dump_layout("flt_guard")
    if on_quick_tab(lay):
        return True
    tap(lay, "快记")
    time.sleep(2.5)
    return on_quick_tab(vw.dump_layout("flt_guard2"))


def scroll_to_top():
    for _ in range(8):
        swipe_down()
    # 滚回顶部后自查：手势偶尔会把页面带走（去过「我的」）
    for _ in range(3):
        lay = vw.dump_layout("flt_topchk")
        if on_quick_tab(lay):
            return lay
        tap(lay, "快记")
        time.sleep(2.5)
    return None


def hide_keyboard():
    """收起软键盘。

    ⚠ 不能用"点一下空白处"那一套：实测在 ArkUI 上点标题区**不会**让输入框失焦，
    键盘照旧挂着，后面每一个 swipe_up 的落点都压在键盘上 ——
    于是验收脚本开始"打字"：搜索框里莫名出现 "5"/"5555"，筛选结果一路归零。
    BACK 键才是可靠的（键盘在前台时第一次 BACK 只收键盘，不会退页面）。
    """
    vw.shell("uinput -K -d 2 -u 2")
    time.sleep(2.5)
    # 键盘收起有动画，dump 太早会读到半屏 —— 给它两次机会再下结论
    for _ in range(2):
        if on_quick_tab(vw.dump_layout("flt_kb")):
            return
        time.sleep(2.0)
    print("  ！BACK 之后读不到快记页，重新拉起应用")
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1")
    time.sleep(6)


def search_box(lay):
    """搜索框 = 屏幕最下面那个 TextInput（表单里两个在上，筛选栏那个在下）

    搜索框的 text 只有输入后才有值，占位文字不在控件树里，
    所以只能按型别找 —— 别去按「搜公司 / 岗位 / 城市」的文案找。
    """
    hits = []
    for n in walk(lay):
        a = n.get("attributes", {})
        b = bounds(a)
        if a.get("type") == "TextInput" and b:
            hits.append(b)
    if not hits:
        return None
    hits.sort(key=lambda b: (b[1], b[0]))
    return hits[-1]


def collect_texts(rounds=9):
    """滚一遍列表汇总文字。**必须去重** —— 同一张卡会出现在多屏 dump 里。"""
    seen = []
    uniq = set()
    for i in range(rounds):
        lay = vw.dump_layout(f"flt_scan{i}")
        for s in vw.texts_of(lay):
            if s not in uniq:
                uniq.add(s)
                seen.append(s)
        swipe_up()
    return " ".join(seen)


def node_lines_of(lay, company):
    """找某张卡片纵向区间内的「下一个节点」行，用于**逐卡**断言。

    返回 None 表示这张卡不在当前屏；返回 [] 表示在屏但没挂节点行。
    """
    cb = rect(lay, company)
    if cb is None:
        return None
    y0 = cb[1]
    out = []
    for n in walk(lay):
        a = n.get("attributes", {})
        t = (a.get("text") or "").strip()
        if " · " not in t or not t.startswith(NODE_LABELS):
            continue
        b = bounds(a)
        # 卡片高度约 360px，往上留 80px 余量吞掉四舍五入
        if b and (y0 - 80) <= b[1] <= (y0 + 420):
            out.append(t)
    return out


def main():
    print("=" * 62)
    print("投递快记 · 筛选 + 下一个节点 验收")
    print("=" * 62)

    # ── ① 重装 + 载入演示数据（保证节点数据齐全）
    print("\n-- ① 重装并载入演示数据 --")
    vw.shell(f"aa force-stop {BUNDLE}")
    time.sleep(1)
    hdc("uninstall", BUNDLE)
    time.sleep(2)
    hdc("install", HAP)
    time.sleep(2)
    # 「载入演示数据」已搬进设置页 —— 不再去界面上找按钮（那要先切「我的」→进设置→滚动，
    # 长距离滚动在这个模拟器上不可靠），走 lh_load_demo 开关带参启动，一次到位。
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1 --pi lh_load_demo 1")
    time.sleep(10)
    print("  演示数据已载入（lh_load_demo 开关）")

    lay = vw.dump_layout("flt1")
    tap(lay, "快记")
    time.sleep(2.5)

    # ── ② 「下一个节点」渲染
    print("\n-- ② 卡片上的「下一个节点」 --")
    scroll_to_top()
    lay = vw.dump_layout("flt_nodes0")
    vw.shot("flt_1_nodes.jpeg")
    full = collect_texts()

    check("面试 · " in full and "笔试 · " in full and "投递截止 · " in full,
          "卡片上画出节点行：面试 / 笔试 / 投递截止 三种都在",
          "卡片上缺节点行 —— 「下一个节点」没渲染出来")

    # 逐卡判定：节点行必须落在**这张卡自己的纵向区间**里。
    # ⚠ 只判屏上第一张卡（明源云）—— 长距离滚动在模拟器上不稳（实测连续 7 次 dump
    #   内容一模一样），用不着为了一条断言去赌手势。
    #   "没节点的记录不挂行"由 ⑥ 的「有安排」筛选覆盖（计数 3 + 排除鼎捷/金山）。
    # ⚠ 先回顶再滑半屏：collect_texts 会把页面滚到**底部**，不回顶的话
    #   这里滑完停在列表中段，明源云根本不在屏上（node_lines_of 返回 None）。
    #   另外表单加了备注区（语音速记）后变高，明源云的节点行被挤出首屏 ——
    #   不滑的话 dump 里只有卡头没有节点行，看着像"节点没渲染"，
    #   其实是"被屏幕底边裁掉了"。回顶 + 滑半屏后首卡正好完整露出。
    scroll_to_top()
    swipe_up()
    time.sleep(1.5)
    lay = vw.dump_layout("flt_nodes1")
    rows = node_lines_of(lay, "明源云")
    check(rows is not None and len(rows) >= 1,
          f"「明源云」卡片区间里找到它自己的节点行：{rows}",
          f"「明源云」卡片区间里没有节点行：{rows}")
    # ── ③ 关键词搜索
    print("\n-- ③ 关键词搜索「北京」 --")
    scroll_to_top()
    lay = vw.dump_layout("flt_sch0")
    b = search_box(lay)
    if b is None:
        check(False, "", "找不到搜索框（TextInput）")
        return
    vw.shell(f"uitest uiInput inputText {(b[0] + b[2]) // 2} {(b[1] + b[3]) // 2} \u5317\u4eac")
    time.sleep(2.5)
    hide_keyboard()
    # 收完键盘直接看一眼就行：命中只剩 1 条，它就在筛选栏下面，不用滚
    lay = vw.dump_layout("flt_sch1")
    vw.shot("flt_4_search.jpeg")
    t = " ".join(vw.texts_of(lay))
    if "\u5317\u4eac" not in t:
        check(False, "", "搜索词没输进去（模拟器输入法限制）—— 这步没验到")
    else:
        check("筛出 1 / 8 条" in t,
              "搜「北京」筛出 1 / 8 条",
              f"搜索结果计数不对：{t[:160]}")
        check("用友网络" in t,
              "命中的正是北京的「用友网络」",
              f"搜到「北京」却没出现用友网络：{t[:160]}")

    # ── ④ 清空筛选
    print("\n-- ④ 点「清空」恢复全量 --")
    lay = vw.dump_layout("flt_clr")
    if not tap(lay, "清空", exact=False):
        check(False, "", "找不到「清空」按钮（有筛选条件时才出现）")
        return
    time.sleep(2)
    t = " ".join(vw.texts_of(vw.dump_layout("flt_clr1")))
    vw.shot("flt_5_cleared.jpeg")
    check("筛出" not in t and "8 条" in t,
          "清空后恢复「8 条」（全量）",
          f"清空后没恢复：{t[:160]}")

    # ── ⑤ 聚合筛选「进行中」
    print("\n-- ⑤ 筛选「进行中」 --")
    scroll_to_top()
    lay = vw.dump_layout("flt_act0")
    if not tap(lay, "进行中"):
        check(False, "", "找不到「进行中」筛选按钮")
        return
    time.sleep(1.5)
    t = collect_texts(rounds=4)
    vw.shot("flt_2_active.jpeg")
    check("筛出 5 / 8 条" in t,
          "「进行中」筛出 5 / 8 条（已投递×2 + 沟通中 + 笔试 + 面试）",
          f"「进行中」计数不对：{t[:160]}")
    check("金山办公" not in t,
          "已拿 Offer 的「金山办公」被筛掉（Offer 不算进行中）",
          "「进行中」里混进了已 Offer 的记录")

    # ── ⑥ 聚合筛选「有安排」（要查节点表，比状态筛选更复杂）
    print("\n-- ⑥ 筛选「有安排」 --")
    scroll_to_top()
    lay = vw.dump_layout("flt_node0")
    if not tap(lay, "有安排"):
        check(False, "", "找不到「有安排」筛选按钮")
        return
    time.sleep(1.5)
    t = collect_texts(rounds=4)
    vw.shot("flt_3_node.jpeg")
    check("筛出 3 / 8 条" in t,
          "「有安排」筛出 3 / 8 条（精测·面试 / 光庭·笔试 / 明源云·截止）",
          f"「有安排」计数不对（期望 3 条）：{t[:200]}")
    check("鼎捷软件" not in t and "金山办公" not in t,
          "没排节点的「鼎捷软件」「金山办公」被筛掉",
          "「有安排」里混进了没有节点的记录")
    check("明源云" in t,
          "只有「投递截止」节点的「明源云」也在（截止同样是节点）",
          "「有安排」漏掉了只有截止节点的记录")

    print(f"\n{'=' * 62}")
    print(f"结果：{OK} 通过 / {FAIL} 失败")
    print(f"截图：tools/_shots/flt_*.jpeg")
    print(f"{'=' * 62}")


if __name__ == "__main__":
    main()
