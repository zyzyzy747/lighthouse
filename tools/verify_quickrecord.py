# -*- coding: utf-8 -*-
"""快记页验收：城市候选 / 编辑已有记录
   ① 城市下拉选项数
   ② 编辑已有记录（含投递时间不变）
"""
import sys
import os
import re
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_widget as vw  # noqa: E402

BUNDLE = "com.wuit.lighthouse"


def rect(lay, text, exact=True, topmost=False):
    """按文本找节点，返回 [x1, y1, x2, y2]

    ⚠ topmost 很关键：「武汉」这种词在屏幕上出现多次（表单的城市选择器、
      以及列表里每条武汉记录的标签），随便取一个会点到列表卡片上去 ——
      结果弹出的是卡片菜单，而你以为在下拉城市列表上做断言。
    """
    hits = []
    stack = [lay]
    while stack:
        n = stack.pop()
        a = n.get("attributes", {})
        t = (a.get("text") or "").strip()
        hit = (t == text) if exact else (text in t)
        if hit and a.get("bounds"):
            nums = [int(v) for v in re.findall(r"-?\d+", a["bounds"])]
            if len(nums) == 4:
                hits.append(nums)
        for c in (n.get("children") or []):
            stack.append(c)
    if not hits:
        return None
    hits.sort(key=lambda b: (b[1], b[0]))
    return hits[0] if topmost else hits[0]


def tap(lay, text, exact=True, topmost=False):
    b = rect(lay, text, exact, topmost)
    if b is None:
        print(f"  ✗ 找不到「{text}」")
        return False
    vw.shell(f"uinput -T -c {(b[0] + b[2]) // 2} {(b[1] + b[3]) // 2}")
    return True


def long_press(lay, text, exact=False, ms=900):
    b = rect(lay, text, exact)
    if b is None:
        print(f"  ✗ 找不到「{text}」")
        return False
    x = (b[0] + b[2]) // 2
    y = (b[1] + b[3]) // 2
    vw.shell(f"uinput -T -m {x} {y} {x} {y} {ms}")
    return True


def boot():
    """冷启动到「有演示数据的主界面」。

    ⚠ 两个改动（2026-09-22，全量回归时这套挂了）：

    ① **必须自己带 `lh_load_demo`**。原来只 `aa start`，靠**上一套脚本留下的数据** ——
       于是它过不过取决于"跑在它前面的是谁"，跟快记页本身没有任何关系。
       而 `DemoData.load()` 是幂等的（库非空就 `demo data skipped`），
       所以带上这个开关既能让它在空库上自足，又不会把已有的数据搞成两份。
    ② 用 `ensure_main_ui` 等界面真的画出来，别赌固定 sleep。
    """
    vw.shell(f"aa force-stop {BUNDLE}")
    time.sleep(1.5)
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1 --pi lh_load_demo 1")
    vw.ensure_main_ui(timeout=40)


# 演示数据里的全部 8 家公司（`DemoData.ets` 的 DEMO_APPS）。
#
# ⚠ 这里**必须列全**。原来只写了 4 家（金山办公/精测电子/光庭信息/达梦数据库），
#   而列表是按紧急度排序的 —— 首屏排到的那几条正好落在这 4 家之外时，
#   脚本会打出「列表里没找到已知公司名，跳过编辑验证」，
#   看着像"快记页的数据没了"，其实是**判据自己的名单不全**。
#   同一类坑在 verify_login 里也踩过一次：白名单比真实数据窄 ⇒ 假失败。
DEMO_COMPANIES = ("精测电子", "光庭信息", "中望软件", "鼎捷软件",
                  "用友网络", "金山办公", "达梦数据库", "明源云")


def run_steps():
    boot()
    lay = vw.dump_layout("qr0")
    texts = vw.texts_of(lay)
    print(f"  启动后文本数 {len(texts)}｜前 6：{texts[:6]}")

    # ── ① 城市下拉
    print("\n-- ① 城市下拉选项 --")
    # ⚠ 必须取最靠上的「武汉」—— 那是表单里的选择器，下面的那个是记录卡片标签
    city_box = rect(lay, "武汉", topmost=True)
    if not tap(lay, "武汉", topmost=True):
        return
    time.sleep(2.5)
    lay = vw.dump_layout("qr_city")
    vw.shot("qr_city_list.jpeg")
    cities = ["武汉", "北京", "上海", "深圳", "广州", "杭州", "南京", "成都",
              "西安", "苏州", "长沙", "重庆", "天津", "合肥", "郑州",
              "青岛", "厦门", "济南", "宁波", "无锡", "福州", "远程"]
    seen = [c for c in cities if rect(lay, c) is not None]
    print(f"  下拉首屏可见城市 {len(seen)} 个：{'/'.join(seen)}")
    vw.check(len(seen) >= 9, f"下拉里能看到 {len(seen)} 个城市（原来最多只有 8 个）",
             f"只看到 {len(seen)} 个，改动没生效")

    # 选一个新增的城市，确认能选上 —— 这比数数量更能说明问题
    if rect(lay, "南京") is not None:
        tap(lay, "南京")
        time.sleep(2)
        lay = vw.dump_layout("qr_nj")
        vw.shot("qr_city_picked.jpeg")
        b = rect(lay, "南京")
        # 判据 = 「南京」出现在**城市选择器那一行**（和原「武汉」同一个 y）。
        # ⚠ 不能写死 y 阈值：选择器在输入框下面两行，y 随字号/边距变，
        #   第一版写死 <700 就把已经生效的结果判成了失败。
        same_row = (b is not None and city_box is not None
                    and abs(b[1] - city_box[1]) < 40)
        vw.check(same_row,
                 "选中「南京」（旧选项里没有的城市）后回填到城市选择器",
                 f"选了南京但选择器没变（南京落在 {b}，选择器原位置 {city_box}）")
    else:
        vw.check(False, "", "下拉首屏看不到「南京」，无法验证新城市可选")

    # ── ② 编辑已有记录
    print("\n-- ② 编辑已有记录 --")
    lay = vw.dump_layout("qr1")
    # 找一条记录卡片上的公司名（列表里的第一张卡片）
    first = None
    for name in DEMO_COMPANIES:
        if rect(lay, name) is not None:
            first = name
            break
    if first is None:
        vw.check(False, "",
                 f"列表里一条演示公司都没找到（找的是 {len(DEMO_COMPANIES)} 家全名单）"
                 " —— 要么演示数据没进来，要么列表没渲染")
        return
    print(f"  目标记录：{first}")

    # bindMenu 默认是点击触发（不是长按），先点，不行再长按
    tap(lay, first)
    time.sleep(2.5)
    lay = vw.dump_layout("qr_menu")
    if rect(lay, "编辑这条") is None:
        print("  单击没出菜单，改试长按")
        long_press(lay, first)
        time.sleep(2.5)
        lay = vw.dump_layout("qr_menu")
    vw.shot("qr_menu.jpeg")
    ok = vw.check(rect(lay, "编辑这条") is not None,
                  "卡片菜单里第一项是「编辑这条」",
                  "菜单里没有「编辑这条」")

    if not ok:
        return
    tap(lay, "编辑这条")
    time.sleep(2.5)
    lay = vw.dump_layout("qr_edit")
    vw.shot("qr_edit_form.jpeg")
    vw.check(rect(lay, "编辑中") is not None,
             "表单进入编辑态（出现「编辑中」提示）",
             "没看到「编辑中」，表单可能没切到编辑态")
    vw.check(rect(lay, "保存修改") is not None,
             "按钮变成「保存修改」",
             "按钮文案没变")
    vw.check(rect(lay, "取消") is not None,
             "出现「取消」按钮（可以退出编辑）",
             "没有取消入口")

    print("\n完成。截图见 tools/_shots/qr_*.jpeg")


def main():
    print("=" * 62)
    print("快记页改动验收")
    print("=" * 62)

    # ⚠ 收尾统计放在最外层：原来这套脚本**一条总数都不打**，
    #   于是全量回归的汇总器只能把它判成"没跑到收尾"，
    #   哪怕里面 4 条断言全过也一样。走到哪一步都要留下可解析的结论。
    try:
        run_steps()
    finally:
        ok = sum(1 for r in vw.RESULTS if r)
        total = len(vw.RESULTS)
        print("\n" + "=" * 62)
        print(f"结果：{ok} 通过 / {total - ok} 失败")
        print("=" * 62)


if __name__ == "__main__":
    main()
