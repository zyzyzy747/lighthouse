"""
灯塔 · 布局留白 验收

干什么：把「内容挤在中间、上下两边太空」这件事**量成数字**，并把改后的样子锁死。

为什么值得单开一套：
  留白是**纯几何**问题，靠截图目测只能得出"看着空"这种不可复现的结论。
  而 dumpLayout 里写得很清楚 —— `Scroll` 的 bounds 是**视口**，它第一个子节点的
  bounds 是**内容**，两者相减就是留白。

  ⚠ ArkUI 的 `Scroll` 在内容不足一屏时**默认垂直居中**，于是上下留白会近似相等。
    这个特征本身就是判据：
      · 上下近似相等  ⇒ 还在居中，病没治
      · 上小下大（或下为负）⇒ 已经顶格
    （2026-09-22 实测：我的 350/351px、助手 529/530px，各自只差 1px。）

改前基线（防回归）：
  我的页  内容高 1621px  上 350px  下 351px
  助手页  内容高 1263px  上 529px  下 530px

⚠ 本套还顺带钉住一个**不是几何问题**的回归：ProfileView 的「投出去 N 天没动静」
  卡依赖 ApplicationRepo 在 insert 时保留调用方给的 updatedAt。详见【3b】注释。
  它和留白同属"页面看起来不对"，但根因在仓库层，别只盯着布局改。

⛔ 另一个量留白时必须知道的坑：**内容比视口高时 `dumpLayout` 会把 bounds 截到视口下沿**，
  于是 `ch` 会恰好等于 `vh`、下留白算出来是 0，看着像"正好填满一屏"，
  其实是"已经溢出、屏幕外的部分压根没量到"。
  实测证据：内容子树里最靠下的节点 bottom 与视口 bottom **精确相等**。
  ⇒ `page_geom` 会额外给出 `clipped`，此时 `ch` 只能当**下界**看。
  配套的【5b】断言"真能滚到底、页脚可达" ——
  「上下都不空」的代价如果是"底部内容永远在屏幕外"，那还不如不补。
"""
import os
import re
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_widget as vw

BUNDLE = "com.wuit.lighthouse"
HAP = r"D:\work\DevEcoStudioProject\Lighthouse\entry\build\default\outputs\default\entry-default-signed.hap"
TOOLS = os.path.dirname(os.path.abspath(__file__))
SHOT_DIR = os.path.join(TOOLS, "_shots")

# 1256×2688 的模拟器，密度 3.5 ⇒ px ÷ 3.5 = vp
DENSITY = 3.5
# 「顶格」判定：内容顶端离视口顶端不超过这么多像素
TOP_TOL_PX = 40
# 改前基线（内容高 / 上留白，px）
BEFORE_MINE = 1621
BEFORE_MINE_TOP = 350
BEFORE_ASST = 1263
BEFORE_ASST_TOP = 529
# 「投出去 N 天没动静」的阈值，必须和 ProfileView.ets 的 STALE_DAYS 一致
STALE_DAYS = 7


# ---------------------------------------------------------------- 几何工具

def nums(b):
    return [int(x) for x in re.findall(r"-?\d+", b or "")]


def box(lay, text, exact=False):
    """按文字取 bounds。find_text_node 返回 (cx, cy, bounds)"""
    hit = vw.find_text_node(lay, text, exact)
    if hit is None:
        return None
    b = hit[2]
    v = [int(x) for x in b] if isinstance(b, (list, tuple)) else nums(b)
    return v if len(v) == 4 else None


def texts(lay):
    return vw.texts_of(lay) if lay else []


def has(ts, s):
    """ts 是文字**列表**，`in` 判的是全等 —— 想按子串找必须显式 any"""
    return any(s in t for t in ts)


def numeric_in_band(lay, y0, y1):
    """取某个纵向区间里的**纯数字**节点。用来验"数字真的画出来了"，光验标签不够。"""
    out = []
    for n in vw.walk_nodes(lay):
        a = n.get("attributes", {}) or {}
        t = str(a.get("text") or "").strip()
        if not t.isdigit():
            continue
        b = nums(a.get("bounds", ""))
        if len(b) == 4 and y0 <= b[1] <= y1:
            out.append(int(t))
    return out


def page_geom(tag):
    """取「页面级 Scroll」的视口 / 内容 bounds。

    ⚠ 必须取**最高的那个 Scroll**：有的页面里还嵌着横滑 chips 之类的小 Scroll，
      按 DFS 取第一个会拿到它（实测拿到过 112px 高的），留白算出来全是垃圾。

    ⛔⛔ **内容比视口高时，`dumpLayout` 会把 bounds 截到视口下沿** ——
      于是 `ch` 会恰好等于 `vh`、下留白算出来是 0，看着像"正好填满一屏"，
      实际是"已经溢出、屏幕外的部分根本没量到"。
      实测证据：内容子树里最靠下的节点 bottom == 视口 bottom（精确相等），
      而那个节点的自然高度不可能刚好落在视口下沿上。
      ⇒ 所以这里额外算一个 `clipped`，让调用方知道 **ch 是下界、不是真值**。
    """
    lay = vw.dump_layout(tag)
    if lay is None:
        return None, None
    best = None
    for n in vw.walk_nodes(lay):
        a = n.get("attributes", {}) or {}
        if "Scroll" not in str(a.get("type") or ""):
            continue
        v = nums(a.get("bounds", ""))
        if len(v) != 4:
            continue
        if best is None or (v[3] - v[1]) > (best[0][3] - best[0][1]):
            best = (v, n)
    if best is None:
        return lay, None
    kids = best[1].get("children") or []
    if not kids:
        return lay, None
    ka = kids[0].get("attributes", {}) or {}
    c = nums(ka.get("bounds", ""))
    if len(c) != 4:
        return lay, None
    return lay, {
        "vp": best[0],
        "c": c,
        "top": c[1] - best[0][1],
        "bot": best[0][3] - c[3],
        "vh": best[0][3] - best[0][1],
        "ch": c[3] - c[1],
        "kind": str(ka.get("type") or ""),
        # 内容子树真实下沿 >= 视口下沿 ⇒ bounds 被截过，ch 只能当下界看
        "clipped": deepest(kids[0]) >= best[0][3],
    }


def deepest(node):
    """子树里最靠下的 bottom。用来判断 bounds 是不是被视口截过。"""
    m = 0
    for n in vw.walk_nodes(node):
        b = nums((n.get("attributes", {}) or {}).get("bounds", ""))
        if len(b) == 4:
            m = max(m, b[3])
    return m


def report_geom(name, g):
    # ★ 先打一行**机器可读**的几何。
    #   ⚠ 下游（_layout_cmp.py 画对比图）原先是用正则去正则化上面那几句人话的 ——
    #     结果措辞一改（clipped 分支换了个说法）正则就静默失配，
    #     表现成"解析不到几何，先跑 verify_layout.py"，而日志明明在这儿。
    #     凡是给人看的文案都会随时间改，别拿它当数据源。
    print(f"GEOM\t{name}\tvh={g['vh']}\tch={g['ch']}\ttop={g['top']}\t"
          f"bot={g['bot']}\tclipped={1 if g.get('clipped') else 0}")
    if g.get("clipped"):
        print(f"   {name}：视口高 {g['vh']}px，内容 **≥ {g['vh']}px**"
              f"（填满整屏并且溢出 —— 超出视口的部分被 dumpLayout 截到视口下沿，"
              f"真实高度量不出来），上留白 {g['top']}px（{g['top'] / DENSITY:.0f}vp）")
        return
    print(f"   {name}：视口高 {g['vh']}px，内容高 {g['ch']}px，"
          f"上留白 {g['top']}px（{g['top'] / DENSITY:.0f}vp），"
          f"下留白 {g['bot']}px（{g['bot'] / DENSITY:.0f}vp）")


def check_flat(name, g, before_h, before_top):
    """三条通用判据。

    ⚠ 别写「上下留白必须差够多」那种判据：改后内容可能正好差不多填满一屏，
      下留白只剩几十像素，那条会**误报**。
      真正的信号是「上留白塌下去了」—— 改前 350/529px，改后 ~0px，没有歧义。
    """
    vw.check(g["top"] <= TOP_TOL_PX, f"{name}：内容顶格（上留白 {g['top']}px ≤ {TOP_TOL_PX}）",
             f"{name}：上留白还有 {g['top']}px —— 内容仍被居中，Scroll 的 align 没生效")
    vw.check(g["top"] < before_top // 2,
             f"{name}：上留白比改前（{before_top}px）塌下去一大半",
             f"{name}：上留白 {g['top']}px，和改前的 {before_top}px 一个量级，等于没改")
    # ⚠ clipped 时 ch 被截成 vh，拿它比 before_h 仍然成立（vh > before_h），
    #   但措辞要说清是"至少" —— 别把截断后的数字当精确值报出去。
    vw.check(g["ch"] > before_h,
             (f"{name}：内容已填满整屏（≥ {g['ch']}px，改前 {before_h}px）" if g.get("clipped")
              else f"{name}：内容确实变多了（{before_h} → {g['ch']}px）"),
             f"{name}：内容高 {g['ch']}px 没有超过改前的 {before_h}px，补的内容没生效")


# ---------------------------------------------------------------- 步骤

def cold_start(settle=14):
    """冷启动并载入演示数据。

    ⚠ `aa force-stop` 报「成功」不等于进程没了（会自己重启，见 SKILL 12.32），
      所以走 vw.force_stop 轮询等它真退。
    """
    if not vw.force_stop(BUNDLE):
        print("     ⚠ 进程没停干净，冷启动结果可能不可信")
    vw.clear_logs()
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1 --pi lh_load_demo 1")
    time.sleep(settle)


def go_tab(lay_tag, label, tries=4):
    """切到主 Tab 并确认真的到了（Tab 是主壳，不存在二级页问题）"""
    for _ in range(tries):
        if vw.tap_tab(label):
            time.sleep(1.5)
            lay = vw.dump_layout(lay_tag)
            if lay is not None and len(texts(lay)) > 3:
                return lay
    return None


def main():
    print("=" * 62)
    print("灯塔 · 布局留白 验收")
    print("=" * 62)

    # ── ① 干净安装（**必须卸载**，理由见下）
    #
    # ⚠ 为什么这一套非要卸载、不能像以前那样只覆盖安装：
    #   本套有一条断言依赖**演示数据里种的时间戳**（「投出去 7 天没动静」卡，
    #   见【3b】）。而 `DemoData.load()` 是"库非空就跳过"，
    #   `updated_at` 又是在**插入那一刻**定死的 ——
    #   覆盖安装会留着上一次装机灌进去的旧数据（updated_at 全是那会儿的"现在"），
    #   新代码根本没机会重新种一遍。
    #   那就是典型的「顺序一变就红/绿」：结论取决于上一套脚本有没有顺手清过库。
    #   所以这一套自己把库清干净，不赌别人的状态。
    #
    # ⚠ 卸载会连带删掉桌面卡片（见 SKILL 12.31）。这是**安全的**：
    #   依赖卡片的 widget / multidevice 排在它前面，avatar / map 排在它后面，
    #   且 avatar / map 自己也会卸载重装、都不依赖卡片。
    print("\n【1】卸载 + 干净安装（带演示数据）")
    vw.force_stop(BUNDLE)
    out = vw.hdc("uninstall", BUNDLE)
    print(f"   uninstall：{(out or '')[:80]}")
    out = vw.hdc("install", HAP)
    print(f"   install：{(out or '')[:80]}")
    dump = vw.shell(f"bm dump -n {BUNDLE}")
    vw.check("com.wuit.lighthouse" in dump, "hap 已安装（按 bm dump 实查）",
             "hap 没装上 —— 后面全是无效结论")
    cold_start()
    vw.check(vw.wait_ui_ready(), "主界面已画出", "主界面没画出来")

    # ── ② 我的页：几何
    print("\n【2】「我的」页 · 留白几何")
    # ⚠ 必须先切 Tab！冷启动落在「快记」，不切就会把**新增投递表单**当个人页量，
    #   而且快记页里的横向 Scroll 只有 112px 高，算出来的留白全是垃圾。
    if go_tab("lay_mine_raw", "我的") is None:
        vw.check(False, "", "切不到「我的」页")
        return
    lay, g = page_geom("lay_mine")
    if g is None:
        vw.check(False, "", "取不到「我的」页的 Scroll 视口/内容 bounds")
        return
    if not has(texts(lay), "我的数据"):
        vw.check(False, "", f"当前屏不像「我的」页：{texts(lay)[:12]}")
        return
    report_geom("我的", g)
    check_flat("我的页", g, BEFORE_MINE, BEFORE_MINE_TOP)
    if g["clipped"]:
        print("   （内容已溢出视口 ⇒ 这一页需要滚动，属正常；页脚可达性见【5b】）")
    p = vw.shot("lay_mine.jpeg")
    print(f"   截图：{p}")

    # ── ③ 我的页：内容
    print("\n【3】「我的」页 · 补进去的内容")
    ts = texts(lay)
    # ⚠ 漏斗刻度用**全等**判（`lab in ts` 就是列表全等），不能用子串 ——
    #   「投递」是「已投递」的子串，快记页那些状态 chip 会把它蒙过去。
    for lab in ("投递", "推进", "面试", "Offer"):
        vw.check(lab in ts, f"漏斗刻度「{lab}」在", f"漏斗刻度「{lab}」不在：{ts[:14]}")
    vw.check(has(ts, "面试转化率"), "转化率文案在",
             f"没有转化率文案：{ts[:14]}")
    vw.check(has(ts, "最近要跑"), "「最近要跑」卡片在", f"没有「最近要跑」：{ts[:14]}")
    vw.check(has(ts, "去看地图"), "「去看地图」出口在", "没有「去看地图」出口")
    vw.check(has(ts, "我的数据"), "「我的数据」标题保留（验收脚本拿它当锚点）",
             "「我的数据」不见了 —— verify_login / verify_avatar 会跟着失效")
    vw.check(has(ts, "设置"), "设置入口在", "设置入口不见了")
    vw.check(has(ts, "高级认证"), "资质标注在（评委看的加分项）",
             f"没有资质标注：{ts[:14]}")

    # ⚠ 光验「标签在不在」是不够的。实测踩过一次：ForEach 的 key 没带 value，
    #   数据到位后 key 不变 ⇒ 那四格**不重建**，屏幕上是首帧的 0；
    #   而同一张卡里不在 ForEach 内的「面试转化率 33%」却是对的 ——
    #   画面自相矛盾（"全是 0 但转化率 33%"），标签断言却全绿。
    #   所以必须验**数字本身画出来了**。
    b_head = box(lay, "我的数据", exact=True)
    b_chip = box(lay, "待办节点")
    if b_head and b_chip:
        vals = numeric_in_band(lay, b_head[3], b_chip[1])
        print(f"   漏斗区间内的数字节点：{vals}")
        vw.check(len(vals) >= 4, f"漏斗四格都画出了数字（{vals}）",
                 f"漏斗区间里只有 {len(vals)} 个数字节点：{vals}")
        vw.check(len(vals) > 0 and max(vals) > 0,
                 "漏斗数字不是全 0（载了演示数据，投递必然 > 0）",
                 f"漏斗数字全是 0 ⇒ ForEach 没随数据重建：{vals}")
    else:
        vw.check(False, "", f"取不到漏斗区间：head={b_head} chip={b_chip}")

    # ── ③b「投出去 N 天没动静」跟进提醒卡
    #
    # ⚠ 这张卡曾经**永远不出现**，且装死装得很像"数据问题"：
    #   ApplicationRepo.toBucket() 把 updated_at 硬写成 now，插入时把调用方给的
    #   updatedAt 丢掉；而 staleApplied() 的判据是 `WHERE updated_at < 截止时间`
    #   ⇒ 每条记录的 updated_at 都等于"刚装完 App 的那一刻"，一条都够不着阈值，
    #     不管 DemoData 里把 appliedDaysAgo 改成多大都没用（卸载重装也一样）。
    #   表面看只是少一张卡，实质是"库里的历史被抹平成全是刚刚"。
    #   修法 = insert 时尊重调用方给的 updatedAt。这条断言就是钉住那个修复。
    print(f"\n【3b】「投出去 {STALE_DAYS} 天没动静」跟进提醒卡")
    vw.check(has(ts, "没动静"), f"跟进提醒卡在（表头「投出去 {STALE_DAYS} 天没动静」）",
             f"没有跟进提醒卡：{ts[:16]}")
    vw.check(has(ts, "中望软件"), "卡里列出了该跟进的公司在列（中望软件）",
             "卡在但没列出公司 —— ForEach 可能没渲染，或 staleApplied 查回空")
    vw.check(has(ts, "天没有更新"), "每行都标了静默天数（「N 天没有更新」）",
             "没有「N 天没有更新」的说明行")

    # ── ④ 我的页：版式顺序（防止卡片顺序被改乱）
    print("\n【4】「我的」页 · 版式顺序")
    b_mine = box(lay, "我的数据", exact=True)
    b_next = box(lay, "最近要跑", exact=True)
    b_set = box(lay, "设置", exact=True)
    if b_mine and b_next:
        vw.check(b_next[1] > b_mine[3], "「最近要跑」排在「我的数据」下面",
                 f"顺序不对：我的数据 y={b_mine}，最近要跑 y={b_next}")
    else:
        vw.check(False, "", f"取不到卡片坐标：我的数据={b_mine} 最近要跑={b_next}")
    # ⚠ 不判「设置必须在首屏内」：内容加厚之后这一页本来就需要轻微滚动，
    #   拿屏幕高度当判据会误报。只确认它在「最近要跑」下面（顺序没被改乱）。
    if b_set and b_next:
        vw.check(b_set[1] > b_next[3], "设置入口排在内容卡片下方（顺序正确）",
                 f"顺序不对：最近要跑 y={b_next}，设置 y={b_set}")
    else:
        # 内容加厚之后「设置」可能落在首屏外，dump 里不保证有它。
        # 存在性由上一步的文字判据兜着，这里缺失就不判 —— 不编一条假通过。
        print(f"   ⚠ 取不到「设置」坐标（可能在首屏外），跳过顺序判据：{b_set}")

    # ── ⑤ 出口能跳到地图页
    print("\n【5】「最近要跑」的出口真能跳到地图")
    hit = vw.find_text_node(lay, "去看地图")
    if hit is None:
        vw.check(False, "", "点不到「去看地图」")
    else:
        vw.tap(hit[0], hit[1], wait=2.5)
        lay_map = vw.dump_layout("lay_map")
        tmap = texts(lay_map)
        vw.check(not has(tmap, "我的数据") and (has(tmap, "作战地图") or has(tmap, "求职地图")),
                 "点一下就切到了地图页",
                 f"没切过去，当前屏：{tmap[:12]}")
    # 回「我的」
    vw.tap_tab("我的")
    time.sleep(1.5)

    # ── ⑤b 溢出之后，底部文案真的能滚出来吗
    #
    # 「上下都不空」的代价如果是"底部内容永远在屏幕外"，那还不如不补。
    # 所以补的内容必须**可达** —— 这条断言就是钉这个的。
    # ⚠ 必须在【5】之后做：滚动会让 `lay` 里的坐标全部失效，
    #   而【5】要点「去看地图」（在页面顶部）。
    print("\n【5b】「我的」页 · 能滚到底、页脚可达")
    if g.get("clipped"):
        # ⛔ 别断言"滚到底后顶部标题必须消失"。第一版就是这么写的，然后红了 ——
        #   因为溢出量可能只有几十像素（内容 2380 vs 视口 2322），
        #   滚到底只上移那几十像素，顶部卡片照样在视野里。
        #   真正要证明的是**内容相对视口位移了**，所以拿同一个节点的 y 前后对比。
        b_before = box(lay, "我的数据", exact=True)
        vw.scroll_content(times=3)
        time.sleep(1.5)
        lay_b = vw.dump_layout("lay_mine_bot")
        tb = texts(lay_b)
        vw.shot("lay_mine_bottom.jpeg")
        # dumpLayout 只返回**可见**节点（见 SKILL 2.1）⇒ 页脚出现在 dump 里就等于它在屏幕上
        vw.check(has(tb, "灯塔 v1.0"), "往下滚到底能看到页脚「灯塔 v1.0 · 想睡觉队」",
                 f"滚到底也没看到页脚，收口文案被挤到屏幕外了：{tb[-8:]}")
        b_after = box(lay_b, "我的数据", exact=True)
        if b_before and b_after:
            dy = b_before[1] - b_after[1]
            print(f"   「我的数据」y：{b_before[1]} → {b_after[1]}（上移 {dy}px）")
            vw.check(dy > 10,
                     f"页面确实滚动了（内容上移 {dy}px）—— 溢出部分不是白丢的",
                     f"滚动后内容只上移了 {dy}px ⇒ 这页根本滚不动，溢出内容看不到")
        else:
            vw.check(False, "",
                     f"取不到位移对照：滚前={b_before} 滚后={b_after}")
    else:
        vw.check(has(texts(lay), "灯塔 v1.0"),
                 "内容没溢出，页脚本来就在首屏内",
                 "内容没溢出但看不到页脚 —— 页脚压根没渲染")

    # ── ⑥ 助手页：几何
    print("\n【6】「助手」页 · 留白几何")
    lay_a = go_tab("lay_asst_raw", "助手")
    lay_a, ga = page_geom("lay_asst")
    if ga is None:
        vw.check(False, "", "取不到「助手」页的 Scroll bounds")
        return
    report_geom("助手", ga)
    check_flat("助手页", ga, BEFORE_ASST, BEFORE_ASST_TOP)
    p = vw.shot("lay_asst.jpeg")
    print(f"   截图：{p}")

    # ── ⑦ 助手页：输入区吸底
    print("\n【7】「助手」页 · 输入区吸底")
    send = box(lay_a, "发送", exact=True)
    tab = box(lay_a, "快记", exact=True)
    if send is None or tab is None:
        vw.check(False, "", f"取不到坐标：发送={send} 快记={tab}")
    else:
        tab_top = tab[1]
        gap = tab_top - send[3]
        print(f"   「发送」底 {send[3]} · TabBar 顶 {tab_top} · 间距 {gap}px")
        vw.check(0 <= gap <= 140,
                 f"「发送」紧贴在 TabBar 上方（间距 {gap}px）—— 输入区真的吸底了",
                 f"输入区不在底部：与 TabBar 的间距 {gap}px")
        vw.check(ga["vp"][3] <= send[1] + 30,
                 "输入区在 Scroll 之外（消息区下沿在输入区之上）",
                 f"Scroll 下沿 {ga['vp'][3]} 压过了输入区顶 {send[1]} —— 输入区还在滚动流里")

    # ── ⑧ 助手页：空态内容
    print("\n【8】「助手」页 · 空态")
    ta = texts(lay_a)
    vw.check(has(ta, "可以这样问"), "「可以这样问」在（verify_agent 拿它当锚点）",
             f"没有「可以这样问」：{ta[:14]}")
    for hint in ("查节点日历", "查投递库", "查能力雷达", "查岗位库"):
        vw.check(has(ta, hint), f"示范问句的注脚「{hint}」在", f"缺注脚「{hint}」")
    for lab in ("投递", "待办节点", "面试复盘", "能力雷达"):
        vw.check(has(ta, lab), f"概览条「{lab}」在", f"概览条缺「{lab}」")
    vw.check(has(ta, "断网也能答") or has(ta, "云端兜底已就绪"),
             "联网标注还在（verify_agent 按它判真假）",
             f"联网标注不见了：{ta[:14]}")

    total = len(vw.RESULTS)
    ok = sum(1 for r in vw.RESULTS if r)
    print(f"\n{'=' * 62}")
    print(f"结果：{ok} 通过 / {total - ok} 失败")
    print("截图：tools/_shots/lay_*.jpeg")
    print(f"{'=' * 62}")
    return 0 if ok == total else 1


if __name__ == "__main__":
    sys.exit(main())
