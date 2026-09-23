# -*- coding: utf-8 -*-
"""
灯塔 · 一多适配（一次开发，多端部署）验证

断点什么：
  1  应用图标 / 启动页资源真的换了（不是工程模板那张默认图）
  2  竖屏 = 手机形态：底部 Tab + 单列
  3  横屏 = 宽屏形态（≈788vp ≥ 600 断点）：切左侧栏
  4  ★ 内容双栏（把断点临时调到 380vp 触发）：地图 / 复盘 / 快记 / 我的 四页真出双栏
  5  ★ 折叠屏悬停分栏：上半「作战简报」+ 下半内容
  6  桌面图标已经是灯塔（回主屏截图）

为什么 4 和 5 需要"开关"：
  本机只有 Pura 90 Pro 一个模拟器镜像（1256×2760 @560dpi ≈ 359×788vp），
  横过来也只有 ≈788vp，够得着侧栏断点（600），够不着双栏断点（840）；
  而悬停分栏只在折叠屏半折叠时出现。这两段布局如果没有开关，
  就等于"写完永远看不到"，出了问题也发现不了。
  所以 Layout 提供了两个**只在带参拉起时生效**的预览开关：
      --ps lh_bp_two 380          临时调小双栏断点
      --ps lh_hover_preview true  强制当作悬停中
  正常从桌面点图标进来不会带这些参数，真实形态不受影响。

⚠ 旋转为什么不按"转一次就完事"写（踩过两次的坑）：

  ① **旋转只对前台应用生效。** 桌面（Launcher）是竖屏锁定的，在桌面上按旋转，
     模拟器照样回 "Scenario simulation success."，但窗口纹丝不动 ——
     报成功 ≠ 生效。所以每一步都必须"先拉起应用，再旋转"。
     早期脚本写成 `force-stop → rotate → start_app`，旋转全被桌面吃掉，
     于是 step3/step4 双双失败，而日志上看起来像"断点没生效"，排查方向完全跑偏。

  ② **`-rotation` 是累积的，不是绝对的。** 连按两次 right 得到 180° 倒竖屏，
     此时 `is_landscape()` 为 False，看起来"已经竖屏了"，
     但 UI 是上下颠倒的，Tab 跑到了屏幕顶部 —— 于是 step2 报"Tab 不在底部"，
     误判成"竖屏被当成了宽屏"。所以判据不能只看"是不是横的"，
     要直接断言**目标形态本身**（Tab 在底部 / Tab 在左侧），转不对就再转一次。

用法：
    python verify_multidevice.py                # 全流程（含编译安装）
    python verify_multidevice.py --skip-build   # 跳过编译
    python verify_multidevice.py --from 4       # 从第 N 步开始
"""

import os
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

import verify_widget as vw

HDC = vw.HDC
BUNDLE = vw.BUNDLE
ABILITY = vw.ABILITY

TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = vw.PROJECT
SHOTS = vw.SHOTS

EMU_DIR = r"D:/DevEco Studio/tools/emulator"
EMU = os.path.join(EMU_DIR, "Emulator.exe")
# ⚠ 实例名是「设备面板里显示的型号名」，不是 Huawei_Phone 这类模板名 ——
#   写模板名会得到 "The emulator is not started or does not exist"。
#   型号名的权威来源是 <Huawei>/Emulator26.0/productConfig.json 里 isInDevicePanel=true 的那条。
INSTANCE = "Pura 90 Pro"

TABS = ["快记", "地图", "复盘", "我的"]


# ---------------------------------------------------------------- 屏幕与控制
def rotate(direction):
    """场景化模拟旋转。direction: left / right

    ⚠ 只在前台有应用时才会真正作用于窗口（见文件头说明①）。
    """
    try:
        r = subprocess.run([EMU, "-instance", INSTANCE, "-rotation", direction],
                           cwd=EMU_DIR, capture_output=True, text=True, timeout=45)
    except Exception as e:
        print(f"  旋转失败：{e}")
        return False
    txt = ((r.stdout or "") + (r.stderr or "")).strip()
    ok = "success" in txt.lower()
    print(f"  旋转 {direction} → {'回报成功' if ok else '回报失败'}  {txt[:50]}")
    time.sleep(3)
    return ok


def root_bounds():
    lay = vw.dump_layout("mb_root")
    if not lay:
        return None
    return vw._bounds_of(lay)


def is_landscape():
    b = root_bounds()
    if not b:
        return False
    return (b[2] - b[0]) > (b[3] - b[1])


def tab_boxes():
    """四个 Tab 文字的 bounds。用来判断导航是底部横排还是左侧竖排。"""
    lay = vw.dump_layout("mb_tabs")
    out = {}
    for t in TABS:
        hit = vw.find_text_node(lay, t, exact=True)
        if hit:
            out[t] = hit[2]
    return out


def tabs_at_bottom():
    """手机形态：四个 Tab 横排在屏幕下缘。"""
    boxes = tab_boxes()
    b = root_bounds()
    if len(boxes) != 4 or not b:
        return False
    h = b[3] - b[1]
    return all((bx[1] + bx[3]) / 2 > h * 0.75 for bx in boxes.values())


def tabs_on_left():
    """宽屏形态：四个 Tab 竖排在屏幕左缘。"""
    boxes = tab_boxes()
    b = root_bounds()
    if len(boxes) != 4 or not b:
        return False
    w = b[2] - b[0]
    return all((bx[0] + bx[2]) / 2 < w * 0.22 for bx in boxes.values())


def rotate_until(pred, want, max_tries=4):
    """反复顺时针转 90°，直到 pred() 成立。

    ⚠ 应用必须已经在前台，否则旋转会被桌面丢掉（文件头说明①）。
    因为是累积 90°，从任意初始朝向出发，最多 4 次一定能覆盖四种朝向，
    所以"转到对为止"比"算好该转几次"稳得多（文件头说明②）。
    """
    for i in range(max_tries):
        if pred():
            return True
        print(f"  当前还不是{want}，继续旋转（第 {i + 1}/{max_tries} 次）")
        rotate("right")
        time.sleep(2.5)
    return pred()


def tap_text(text, exact=True, wait=3.0, tries=3):
    """在当前界面点某段文字（自带重试）。

    ⚠ 重试是**必需**的，不是保险：`dump_layout` 拉不到控件树时会**明确返回 None**
      （见其文档），单次调用碰上一次拉取失败就报「点不到 X」——
      而那句话会被读成"这个控件不存在"，把排错方向引到文字匹配上去。
      实测：同一台设备上手工 dump 明明能命中，脚本却报"点不到「复盘」Tab"。
    """
    for _ in range(tries):
        hit = vw.find_text_node(vw.dump_layout("mb_tap"), text, exact=exact)
        if hit:
            vw.tap(hit[0], hit[1], wait=wait)
            return True
        time.sleep(1.0)
    return False


def start_app(*ps_pairs):
    """带可选 want 参数拉起应用。ps_pairs 形如 ('lh_bp_two', '380')"""
    cmd = f"aa start -a {ABILITY} -b {BUNDLE} --pi lh_autologin 1"
    for k, v in ps_pairs:
        cmd += f" --ps {k} {v}"
    vw.shell(cmd)
    time.sleep(7)


def restart_app(*ps_pairs):
    """强制冷启动（先杀掉再拉起）——需要 onCreate 路径生效时用这个。"""
    vw.shell(f"aa force-stop {BUNDLE}")
    time.sleep(2)
    start_app(*ps_pairs)


def app_ready():
    """等界面真的画出来（就绪后才有 Tab）"""
    for _ in range(10):
        if tab_boxes():
            return True
        time.sleep(2)
    return False


# ---------------------------------------------------------------- 断点
def step1_resources():
    print("\n== 1/6 图标与启动页资源已替换 ==")
    ok = True

    fg = os.path.join(PROJECT, r"AppScope\resources\base\media\foreground.png")
    bg = os.path.join(PROJECT, r"AppScope\resources\base\media\background.png")
    si = os.path.join(PROJECT, r"entry\src\main\resources\base\media\startIcon.png")

    # 模板默认图很小（前景 15KB / 背景 92KB / startIcon 14KB），
    # 自己画的图是满画布渐变 + 多层图形，字节数差一个量级 —— 拿它当"换过了"的判据很稳。
    for path, name, min_b in [(fg, "前景层 foreground.png", 120_000),
                              (bg, "背景层 background.png", 100_000),
                              (si, "启动页图标 startIcon.png", 8_000)]:
        if not os.path.isfile(path):
            ok = check(False, "", f"{name} 不存在：{path}") and ok
            continue
        size = os.path.getsize(path)
        ok = check(size >= min_b, f"{name} 已是自制图（{size // 1024} KB）",
                   f"{name} 只有 {size} B，像是模板默认图") and ok

    # 尺寸必须是鸿蒙分层图标规范的 1024×1024
    import struct
    with open(fg, "rb") as f:
        head = f.read(33)
    w, h = struct.unpack(">II", head[16:24])
    ok = check((w, h) == (1024, 1024), f"前景层尺寸 {w}×{h} 符合分层图标规范",
               f"前景层尺寸 {w}×{h}，应为 1024×1024") and ok

    # 启动页底色：必须**与该主题自己的应用底色一致**，否则从启动页切进应用会闪一下。
    #
    # ⚠ 判据写的是 `== lh_bg`（同文件比对），不是某个写死的色值。
    #   原来写死 `== "#0A1120"`（深色底）—— 那是在应用只有深色主题时定的。
    #   后来补了浅色主题（base: lh_bg=#F2F5FA / dark: lh_bg=#0A1120），
    #   浅色那套就被判成"会闪一下白"，而它其实**完全正确**（浅色下本来就该是浅底）。
    #   ★ 判据要对着"不变量"写：要的是两处颜色**一致**，不是等于某个具体值。
    #     两套资源都查一遍，以后再加主题也不用改这里。
    import json
    bad_themes = []
    for theme in ("base", "dark"):
        cj = os.path.join(PROJECT, "entry", "src", "main", "resources",
                          theme, "element", "color.json")
        if not os.path.isfile(cj):
            continue
        with open(cj, encoding="utf-8") as f:
            colors = {c["name"]: (c["value"] or "").upper() for c in json.load(f)["color"]}
        splash = colors.get("start_window_background", "")
        bg = colors.get("lh_bg", "")
        if splash != bg:
            bad_themes.append(f"{theme}: 启动页 {splash or '未定义'} ≠ 应用底色 {bg}")
    ok = check(not bad_themes,
               "启动页底色 = 该主题的应用底色（深浅两套都比对过，不会闪）",
               "启动页底色和应用底色对不上，切进应用会闪一下 —— " + "；".join(bad_themes)) and ok

    # 跟随旋转：不声明的话平板/折叠屏上转过来界面不动
    mj = os.path.join(PROJECT, r"entry\src\main\module.json5")
    with open(mj, encoding="utf-8") as f:
        raw = f.read()
    ok = check('"orientation": "auto_rotation"' in raw,
               "已声明 auto_rotation，跟随系统旋转",
               "没声明 orientation，横屏/平板上界面不会转") and ok

    # 桌面显示名。模板会残留 app_name="Lighthouse" / EntryAbility_label="label"，
    # 后者会让桌面图标下方直接显示英文单词 label —— 改了图标不改名字，等于白换。
    import json as _j
    appstr = os.path.join(PROJECT, r"AppScope\resources\base\element\string.json")
    with open(appstr, encoding="utf-8") as f:
        names = {s["name"]: s["value"] for s in _j.load(f)["string"]}
    ok = check(names.get("app_name") == "灯塔",
               "AppScope 应用名 = 灯塔",
               f"应用名还是 {names.get('app_name')!r}") and ok

    est = os.path.join(PROJECT, r"entry\src\main\resources\base\element\string.json")
    with open(est, encoding="utf-8") as f:
        en = {s["name"]: s["value"] for s in _j.load(f)["string"]}
    ok = check(en.get("EntryAbility_label") == "灯塔",
               "Ability 标签 = 灯塔（桌面图标下方显示的中文名）",
               f"EntryAbility_label 还是 {en.get('EntryAbility_label')!r}") and ok

    # 应用内启动页 = logo + 一句介绍 + 最小停留时长，三件缺一不可。
    # 分开断言的理由：数据库在 EntryAbility.onCreate 里就绪，**没有最小停留时这一屏
    # 一帧都渲染不出来**；只断言 logo 和文案会得到"看起来都在、实际看不见"的假绿。
    sl = os.path.join(PROJECT, r"entry\src\main\resources\base\media\splash_logo.png")
    if not os.path.isfile(sl):
        ok = check(False, "", "启动页 logo splash_logo.png 不存在") and ok
    else:
        with open(sl, "rb") as f:
            sh2 = f.read(33)
        sw, sh = struct.unpack(">II", sh2[16:24])
        ok = check((sw, sh) == (420, 420),
                   f"启动页 logo 是专出的 {sw}×{sh} 高清图",
                   f"启动页 logo 尺寸 {sw}×{sh}，应为 420×420 "
                   f"—— 直接放大 152 的启动图标会发虚") and ok

    idx = os.path.join(PROJECT, r"entry\src\main\ets\pages\Index.ets")
    with open(idx, encoding="utf-8") as f:
        idraw = f.read()
    ok = check("把求职，变成一场有节奏的战役" in idraw,
               "启动页有应用介绍文案",
               "启动页的介绍文案不见了 —— 又变回只有一个转圈") and ok
    ok = check("SPLASH_MIN_MS" in idraw,
               "启动页有最短停留时长（否则它在首帧之前就被替换，等于不存在）",
               "最小停留被删掉了：数据库在 Ability.onCreate 就绪，splash 一帧都看不到") and ok
    return ok


def step2_portrait():
    print("\n== 2/6 竖屏 = 手机形态（底部 Tab） ==")
    restart_app()
    if not app_ready():
        return check(False, "", "应用界面没起来（找不到 Tab）")

    # ⚠ 先拉起应用再转（旋转只对前台应用生效）
    if not rotate_until(tabs_at_bottom, "手机竖屏形态", max_tries=4):
        b = root_bounds()
        return check(False, "", f"转不回竖屏手机形态（当前 root={b}）")

    b = root_bounds()
    boxes = tab_boxes()
    ok = check(len(boxes) == 4, f"四个 Tab 都在（{len(boxes)}/4）",
               f"只找到 {len(boxes)} 个 Tab：{list(boxes.keys())}")
    ok = check(not is_landscape(),
               f"窗口是竖屏（{b[2] - b[0]}×{b[3] - b[1]}px）",
               f"窗口还是横的（{b[2] - b[0]}×{b[3] - b[1]}px）") and ok
    ok = check(tabs_at_bottom(), "四个 Tab 排在屏幕底部（手机形态）",
               "Tab 不在底部 —— 竖屏被误判成宽屏了") and ok
    vw.shot("md_1_portrait.jpeg")
    return ok


def step3_landscape_side():
    print("\n== 3/6 横屏 = 宽屏形态（左侧栏） ==")
    # 应用还在前台（step2 留下的），直接转；不用重启 ——
    # auto_rotation 下旋转会触发 onAreaChange，布局自己重算。
    if not rotate_until(lambda: is_landscape() and tabs_on_left(), "横屏侧栏形态"):
        b = root_bounds()
        return check(False, "", f"转不到横屏侧栏形态（当前 root={b}）")

    b = root_bounds()
    w = b[2] - b[0]
    ok = check(is_landscape(),
               f"窗口已经变成横向（{w}×{b[3] - b[1]}px ≈ {w / 3.5:.0f}vp）",
               "窗口还是竖的（旋转没传到应用）")

    boxes = tab_boxes()
    ok = check(tabs_on_left(), "四个 Tab 移到左侧栏（宽屏形态）",
               "Tab 还在底部 —— 断点没生效") and ok

    # 侧栏是竖排的，所以四个 Tab 的 x 几乎一致、y 依次增大
    if len(boxes) == 4:
        xs = sorted((bx[0] + bx[2]) // 2 for bx in boxes.values())
        ys = sorted((bx[1] + bx[3]) // 2 for bx in boxes.values())
        ok = check(xs[-1] - xs[0] < 40 and ys[-1] - ys[0] > 100,
                   f"Tab 竖直排列（x 跨度 {xs[-1] - xs[0]}px / y 跨度 {ys[-1] - ys[0]}px）",
                   f"Tab 不是竖直排列（x 跨度 {xs[-1] - xs[0]} / y 跨度 {ys[-1] - ys[0]}）") and ok
    vw.shot("md_2_landscape_sidebar.jpeg")
    return ok


def back_from_subpage():
    """从二级页（设置）退回主壳。点在「‹」上，不用 Back 键。

    ⛔ 别用 `uitest uiInput keyEvent Back` 代替：应用里没有可退的返回栈时，
       它会把应用**整个扔到后台**（和 SKILL 12.16 记的是同一个现象），
       后果一样是"下一步找不到 Tab"，但更难查 —— 因为提示完全一样。
    """
    if tap_text("‹", exact=True, wait=2.0):
        time.sleep(2)
        return True
    return False


def enter_tab_shell():
    """确保现在站在「有底部 Tab 的主壳」上；钻进了二级页就先退出来。

    ⚠⚠ 为什么要它（2026-09-22 实测，代价一轮验收）：
      底部 Tab 栏**只在主壳渲染**，设置页是二级页、不占 Tab。
      而 step4 里「我的」这一页的判据要**先钻进设置页**（「演示数据」卡片在宽屏右列），
      跑完不退出的话，**下一轮**点 Tab 必然落空 —— 报出来是「点不到「复盘」Tab」。
      实测那次的结果很有误导性：地图 ✓、快记 ✓、我的 ✓，然后复盘 ✗，
      看起来像"复盘这一个 Tab 有问题"，实际是"我们还站在设置页里"。
      ⇒ **任何会钻进二级页的步骤，都要负责把状态收回主壳**，
        而且最好收在**下一轮的入口**上（自愈），而不是依赖上一轮记得退。
    """
    for _ in range(4):
        if sum(1 for t in vw.texts_of(vw.dump_layout("shell")) if t in TABS) >= 3:
            return True
        if not back_from_subpage():
            break
    return sum(1 for t in vw.texts_of(vw.dump_layout("shell")) if t in TABS) >= 3


PAGES = [
    # (Tab, 进入后再点的路径, 判据文案候选, 至少出现几次, 说明, 命中必须在右半边)
    # 复盘页的右栏会**自动选中最近一场**，所以不能再拿「从左侧选一场面试」当判据 ——
    # 那句只在"没选中"时才出现。
    ("地图", ["作战地图"], 2, "地图页：左「投得怎么样」右「接下来做什么」", [], False),
    ("快记", ["左边填 · 右边立刻出现"], 1, "快记页：左表单右列表", [], False),
    # ⚠ 「演示数据」**不在「我的」页上**，它是 `SettingsView.colRight()` 里的卡片 ——
    #   也就是**设置页的宽屏右列**。原来这一步直接点「我的」就找「演示数据」，
    #   于是永远 0 命中，报成"双栏没生效"，把排错方向引到断点/旋转上去了。
    #   （2026-09-22：「载入演示数据」从「我的」搬到设置页之后，这条判据没跟着改。）
    #   它恰好只在宽屏右列渲染 ⇒ 用它判双栏是合适的，只是要多点一层。
    #   ⚠ 横屏下这个入口在**屏幕外**（dumpLayout 只给可见节点），所以先滚动。
    ("我的", ["演示数据"], 1, "设置页：宽屏右列出现「演示数据」卡片（双栏真的生效）",
     ["设置"], False),
    # ⚠ 复盘用**包含**匹配 + **必须落在右半边**，见 right_half_hit 的说明。
    ("复盘", ["能力雷达", "六维明细", "正在读这场面试", "云端模型", "本地引擎"], 1,
     "复盘页：右栏渲染出雷达区（已分析 / 未分析两种状态都算）", [], True),
]

# 哪些页用「包含」匹配（其余用严格相等，避免"顺手多匹配几个字"造成假通过）
CONTAINS_PAGES = {"复盘"}


def _counts(lay, markers, contains=False):
    """一份控件树里，各候选文案各出现几次（只 dump 一次，别每个候选各 dump 一遍）

    ⚠ 默认**严格相等**。改成"包含"会让「作战地图」这种判据把标题里的
      「作战地图 · 今天」也算进来 —— 一个本来要证明"左右各一栏"的断言，
      会因为顺带多匹配了几处而假通过。
    """
    texts = vw.texts_of(lay)
    if contains:
        return {m: sum(1 for t in texts if m in t) for m in markers}
    return {m: sum(1 for t in texts if t == m) for m in markers}


def right_half_hit(lay, markers):
    """右半边里有没有出现这些文案（包含匹配）；返回命中的文字或 None。

    ★ 为什么不能只数出现次数：「能力雷达」这个词在**左栏**的空态说明里也有
      （ReviewView 的「分析引擎会据此算出六维能力雷达」），
      光数次数的话，右栏整个没渲染也能凑够 1 次 —— 又是一个"看起来合理的假通过"。
      所以要求命中节点**中心落在屏幕右半边**。
    ★ 为什么用包含而不是相等：右栏那行来源标注带动态数据
      （「云端模型 deepseek-flash · 用时 3.4s · 1383 tokens」），写死整串必然对不上；
      而雷达图本身是 Canvas，轴标签根本不在控件树里。
    """
    b = vw._bounds_of(lay)
    if not b:
        return None
    mid = (b[0] + b[2]) / 2
    for n in vw.walk_nodes(lay):
        a = n.get("attributes", {})
        t = (a.get("text") or "").strip()
        if not t or not any(m in t for m in markers):
            continue
        nb = vw._bounds_of(n)
        if nb and (nb[0] + nb[2]) / 2 > mid:
            return t
    return None


def step4_two_pane():
    print("\n== 4/6 ★ 内容双栏（断点临时调小到 380vp 触发） ==")
    vw.clear_logs()
    # 冷启动带参：onCreate 里读开关最干净
    restart_app(("lh_bp_two", "380"))

    txt = "\n".join(vw.logs("Lighthouse", tail=200))
    ok = check("双栏断点本次临时改为 380vp" in txt,
               "自检开关已生效（日志确认断点被改成 380vp）",
               "没看到断点覆盖日志 —— --ps 参数可能没传到")
    if not ok:
        return False

    if not app_ready():
        return check(False, "", "应用界面没起来")

    # 应用已在前台，转成横屏（≈788vp ≥ 380 断点）
    if not rotate_until(lambda: is_landscape() and tabs_on_left(), "横屏侧栏形态"):
        return check(False, "", "转不到横屏，双栏无法触发")

    b = root_bounds()
    print(f"  当前窗口 {b[2] - b[0]}×{b[3] - b[1]}px ≈ {(b[2] - b[0]) / 3.5:.0f}vp 宽")
    # 把布局折算日志打出来：双栏没出时，一眼能看出是"没跑到"还是"算出来是 false"
    for line in vw.logs("Lighthouse", tail=120):
        if "多端：窗口" in line:
            print("  " + line.strip()[-110:])

    for tab, markers, need, desc, via, right_half in PAGES:
        # ⚠ 上一轮可能钻进了二级页（例如「我的」的判据要进设置页），先退回主壳再点 Tab
        if not enter_tab_shell():
            ok = check(False, "", f"退不回主壳（底部 Tab 不在），点不到「{tab}」") and ok
            continue
        if not tap_text(tab):
            ok = check(False, "", f"点不到「{tab}」Tab") and ok
            continue
        time.sleep(4)
        for step_text in via:          # 有的判据在下一层页面里（见 PAGES 的说明）
            # ⚠ 横屏下入口可能在屏幕外（见 tap_text_with_scroll 的说明）：找不到就滚一屏再找
            if not vw.tap_text_with_scroll(step_text, exact=True, rounds=3, tries=4):
                ok = check(False, "", f"点不到「{tab}」→「{step_text}」（滚动后也没找到）") and ok
                break
            time.sleep(3)
        else:
            lay = vw.dump_layout("mb_pane")
            if right_half:
                hit_text = right_half_hit(lay, markers)
                ok = check(hit_text is not None,
                           f"{desc}（右栏命中「{hit_text}」）",
                           f"{desc}：右半边没有 {'/'.join(markers)} 任何一种文案") and ok
            else:
                cs = _counts(lay, markers, contains=tab in CONTAINS_PAGES)
                n = max(cs.values())
                hit = max(cs, key=lambda k: cs[k])
                if need >= 2:
                    ok = check(n >= 2, f"{desc}（「{hit}」出现 {n} 次 = 左右各一栏）",
                               f"{desc}：只找到 {n} 次「{hit}」，看起来还是单列") and ok
                else:
                    ok = check(n >= 1, f"{desc}（出现「{hit}」）",
                               f"{desc}：{'/'.join(markers)} 一个都没出现，双栏没生效") and ok
            vw.shot(f"md_3_twopane_{tab}.jpeg")
    return ok


def step5_hover():
    print("\n== 5/6 ★ 折叠屏悬停分栏 ==")
    vw.clear_logs()
    # 悬停分栏是"上下"分栏，横屏高度只有 ≈359vp（< 640 紧凑阈值）不会启用，
    # 所以这一步要回到竖屏（≈788vp 高）。
    restart_app(("lh_hover_preview", "true"))

    txt = "\n".join(vw.logs("Lighthouse", tail=200))
    ok = check("收到悬停预览开关" in txt, "悬停预览开关已生效",
               "没看到悬停预览日志")
    ok = check("悬停由预览开关强制开启" in txt,
               "非折叠设备上也真的启用了悬停布局（开关优先于设备判定）",
               "日志显示开关收到后仍走了「非折叠设备」分支 —— 开关没生效") and ok
    if not app_ready():
        return check(False, "", "应用界面没起来")

    if not rotate_until(tabs_at_bottom, "手机竖屏形态"):
        return check(False, "", "转不到竖屏，悬停分栏需要高度")

    time.sleep(3)
    lay = vw.dump_layout("mb_hover")
    texts = vw.texts_of(lay)
    b = root_bounds()
    h = b[3] - b[1] if b else 0

    # 结构断言（不依赖库里有没有数据）：简报在上、内容在下，中间是折痕留白。
    chip = vw.find_text_node(lay, "悬停模式", exact=True)
    ok = check(chip is not None and chip[1] < h * 0.46,
               f"上半区出现「悬停模式」简报（y={chip[1] if chip else '-'} < {h * 0.46:.0f}）",
               "上半区没有「悬停模式」—— 悬停分栏没渲染") and ok

    content = None
    for t in ("投递快记", "作战地图", "面试复盘"):
        hit = vw.find_text_node(lay, t)
        if hit:
            content = (t, hit)
            break
    ok = check(content is not None and content[1][1] > h * 0.46,
               f"下半区仍是完整内容（找到「{content[0] if content else '-'}」在折痕以下）",
               "下半区内容不见了 —— 简报把内容顶掉而不是加在上方") and ok

    # 数据断言：倒计时单位 + 节点概况（WidgetData 的 head 文案）
    ok = check(any(("小时后" in t or "天后" in t or "分钟后" in t or "已逾期" in t)
                   for t in texts),
               "简报里读得到倒计时单位（天后 / 小时后）",
               "简报里没有倒计时") and ok
    ok = check(any("个节点" in t for t in texts) or any("等待第一个节点" in t for t in texts),
               "简报里读得到节点概况（N 个节点在等）",
               "简报里没有节点概况") and ok
    vw.shot("md_4_hover.jpeg")
    return ok


def step6_desktop_icon():
    print("\n== 6/6 桌面图标已经是灯塔 ==")
    # ⚠⚠ 转回竖屏必须**趁应用在前台**做（2026-09-22 修）。
    #   文件头说明①：应用不在前台时 rotate 会被**桌面直接丢掉**、还不报错。
    #   而上一轮的"折叠屏悬停"是靠 rotate 到横屏实现的 ⇒ 这一步开始时**必定是横屏**。
    #   原先的写法是先 `aa force-stop` 再 rotate：应用已经不在前台 ⇒ 转不动 ⇒
    #   设备停在横屏，横屏桌面的排布和竖屏不一样，`goto_card_page` 就找不到卡片了。
    #   于是 step6 挂在一个和"换图标"毫无关系的地方（而且它其实是崩在下面那行文案上，
    #   见下方 ⚠）。先把应用拉起来（幂等），转正了再杀掉。
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE}")
    time.sleep(5)
    rotate_until(lambda: not is_landscape(), "竖屏", max_tries=4)
    vw.shell(f"aa force-stop {BUNDLE}")
    time.sleep(2)
    # ⚠ 卡片会在 `bm uninstall` 时被系统一起删掉 —— 而本套的入口（install）就是重装。
    #   所以这里必须先确认桌面真有卡片，没有就补一张，否则下面 `goto_card_page`
    #   拿不到 FormComponent，第 6 步会红成一个跟"换图标"毫无关系的失败。
    if not vw.ensure_card(BUNDLE):
        print("    ⚠ 没能把卡片加到桌面")
    # 复用 verify_widget 里已经踩完坑的「回到卡片所在页」：
    # HOME 要按两下才回主屏，且卡片可能不在第一页，要左右滑动去找。
    lay, form = vw.goto_card_page()
    vw.shot("md_5_desktop.jpeg")
    ok = check(True, "桌面截图已保存 md_5_desktop.jpeg（人工确认图标是灯塔）", "")
    # 顺便确认桌面上的卡片还在（换图标不该影响卡片）
    #
    # ⚠ 文案必须**惰性**构造。原来写成
    #     check(form is not None, f"…{form[2] - form[0]}×…", "桌面上找不到卡片了")
    #   —— f-string 是**先求值**的：form 为 None 时直接 `TypeError: 'NoneType'
    #   object is not subscriptable`，脚本崩在最后一步。
    #   后果不只是难看：**那行本该打出来的「桌面上找不到卡片了」永远看不到**，
    #   报错方向从"卡片没了"变成了"脚本有 bug"。判据和它的文案要一起想。
    ok = check(form is not None,
               (f"桌面卡片仍在（{form[2] - form[0]}×{form[3] - form[1]}px，换图标没有连带影响）"
                if form else ""),
               "桌面上找不到卡片了") and ok
    return ok


def main():
    args = sys.argv[1:]
    skip_build = "--skip-build" in args
    from_step = 1
    if "--from" in args:
        from_step = int(args[args.index("--from") + 1])
    to_step = 6
    if "--to" in args:
        to_step = int(args[args.index("--to") + 1])

    print("=" * 68)
    print("灯塔 · 一多适配验证")
    print("=" * 68)

    if not skip_build and from_step <= 1:
        print("\n-- 编译并安装 --")
        r = subprocess.run(["bash", os.path.join(TOOLS, "build.sh")],
                           capture_output=True, text=True, timeout=900)
        if "BUILD SUCCESSFUL" not in (r.stdout or ""):
            print((r.stdout or "")[-2000:])
            print("编译失败，中止")
            return
        print("  编译通过")
        hap_dir = os.path.join(PROJECT, "entry", "build", "default", "outputs", "default")
        inst = subprocess.run([HDC, "install", "-r", "entry-default-signed.hap"],
                              cwd=hap_dir, capture_output=True, text=True, timeout=180)
        out = (inst.stdout or "") + (inst.stderr or "")
        print("  安装：" + ("成功" if "successfully" in out else out.strip()[-200:]))

    if from_step <= 1 <= to_step:
        step1_resources()
    if from_step <= 2 <= to_step:
        step2_portrait()
    if from_step <= 3 <= to_step:
        step3_landscape_side()
    if from_step <= 4 <= to_step:
        step4_two_pane()
    if from_step <= 5 <= to_step:
        step5_hover()
    if from_step <= 6 <= to_step:
        step6_desktop_icon()

    total = len(vw.RESULTS)
    good = sum(1 for x in vw.RESULTS if x)
    print("\n" + "=" * 68)
    print(f"结果：{good}/{total} 项通过")
    print("=" * 68)
    if good < total:
        print("未通过项见上面的 ✗ 行。")


def check(cond, ok_msg, bad_msg):
    return vw.check(cond, ok_msg, bad_msg)


if __name__ == "__main__":
    main()
