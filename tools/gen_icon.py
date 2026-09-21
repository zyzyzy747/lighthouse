# -*- coding: utf-8 -*-
"""
灯塔 · 应用图标 / 启动页图标 生成器

产出三张图（覆盖工程里的默认模板）：

    AppScope/resources/base/media/foreground.png     分层图标 · 前景层
    AppScope/resources/base/media/background.png     分层图标 · 背景层
    entry/src/main/resources/base/media/foreground.png     （entry 侧同一套）
    entry/src/main/resources/base/media/background.png
    entry/src/main/resources/base/media/startIcon.png     启动页图标（152×152）

为什么是"画"出来的而不是找一张图：

  ① **分层图标有硬性安全区。** 系统会把前景层按缩放比放大后再套用圆形 / 圆角方形 / 水滴
     等裁切形状，外部素材几乎不可能刚好落进安全区 —— 最常见的翻车就是塔尖被切掉。
     程序化绘制可以把图形约束在中心安全区内，一次画对。
  ② 图形本身是几何形（梯形塔身 + 扇形光束 + 渐变海面），代码比手工描图更精确。
  ③ 改配色 / 粗细 / 位置只改下面的常量，不用重新导出素材，也天然没有版权问题。

用法：
    python gen_icon.py                # 生成并写入工程
    python gen_icon.py --preview      # 只在 _shots/ 里出预览图，不动工程
    python gen_icon.py --out <目录>    # 输出到指定目录
"""

import os
import sys
import shutil
import datetime

import numpy as np
from PIL import Image, ImageDraw

# ----------------------------------------------------------------------------
# 画布与安全区
# ----------------------------------------------------------------------------
S = 1024                     # 图标画布边长（鸿蒙分层图标标准尺寸）
SS = 4                       # 超采样倍数：形状先在大画布上画，最后 LANCZOS 缩回来，边缘才干净
W = S * SS

# 分层图标安全区：前景图形全部落在中心 SAFE 见方的区域内。
# 系统对前景层有放大比（约 1.75×）再裁切，超出这个范围的部分在部分图标形状下会被切掉。
SAFE = 585.0

# ----------------------------------------------------------------------------
# 调色（与 common/Theme.ets 的 Palette 保持一致，桌面图标和应用内是一个色系）
# ----------------------------------------------------------------------------
DEEP_IN = (23, 48, 79)        # 海面深处偏亮的蓝
DEEP_OUT = (6, 13, 25)        # 边缘近黑
SEA = (58, 122, 190)          # 海面反光
TOWER = (241, 246, 255)       # 塔身近白
TOWER_DIM = (178, 199, 229)   # 塔身背光面
STRIPE = (30, 78, 140)        # 塔身条纹（深蓝）
BASE_C = (16, 34, 58)         # 底座
BASE_HI = (60, 106, 158)      # 底座受光边
LAMP = (255, 214, 108)        # 灯室
BEAM = (255, 201, 77)         # 光束
STAR = (200, 224, 255)

# ----------------------------------------------------------------------------
# 灯塔几何（在 S=1024 的画布坐标里，全部按"中心安全区"约束过）
# ----------------------------------------------------------------------------
CX = S / 2.0

SPIRE_Y = 262.0               # 塔尖
CAP_Y = 306.0                 # 尖顶三角与灯室的交界
LAMP_TOP_Y = 306.0            # 灯室上沿
LAMP_BOT_Y = 380.0            # 灯室下沿
GALLERY_BOT_Y = 396.0         # 观景台（栏杆）下沿

BODY_TOP_Y = 396.0            # 塔身顶部
BODY_BOT_Y = 720.0            # 塔身底部
BODY_TOP_HW = 50.0            # 塔身顶部半宽
BODY_BOT_HW = 86.0            # 塔身底部半宽

BASE_TOP_Y = 720.0
BASE_BOT_Y = 762.0
BASE_TOP_HW = 96.0
BASE_BOT_HW = 116.0

LAMP_HW = 58.0                # 灯室半宽
GALLERY_HW = 72.0             # 观景台半宽

STRIPES = [(452.0, 482.0), (548.0, 578.0)]   # 两道塔身条纹的 y 区间

BEAM_ORIGIN_Y = 344.0         # 光束发射点
BEAM_LEN = 320.0              # 光束长度（最外缘已经很淡，稍微出界无妨）
BEAM_TILT = 9.0               # 光束中心向上仰角（度）
BEAM_SPREAD = 8.5             # 光束角向高斯宽（度）；调小会让边缘发硬、像贴了两块色块


def _hw_at(y):
    """塔身在给定高度处的半宽（线性插值）。条纹靠它贴合梯形，不会露边。"""
    t = (y - BODY_TOP_Y) / (BODY_BOT_Y - BODY_TOP_Y)
    return BODY_TOP_HW + t * (BODY_BOT_HW - BODY_TOP_HW)


def _pts(pairs):
    """把 S 空间的点换算到超采样画布。"""
    return [(x * SS, y * SS) for x, y in pairs]


# ----------------------------------------------------------------------------
# 前景层
# ----------------------------------------------------------------------------
def _beam_and_glow():
    """光束 + 灯室光晕（numpy 算，因为要平滑的角度/距离衰减）。

    三角形叠加做不出干净的扇形衰减 —— 手画的多边形边缘会有明显折角，
    而桌面图标只有几十像素，折角会直接变成难看的锯齿。
    """
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    dx = xx - CX
    dy = yy - BEAM_ORIGIN_Y
    r = np.sqrt(dx * dx + dy * dy)

    # 与水平方向的夹角（向上为正），左右对称地取绝对值
    ang = np.degrees(np.arctan2(-dy, np.abs(dx)))

    # 距离衰减 + 角向高斯 → 扇形。
    # ⚠ 灯室的光晕一定要比光束**小得多**。第一版把光晕半径开到 205、强度 0.55，
    #   结果圆形光晕整个把扇形盖住了 —— 图标看上去只有一团黄光，认不出是灯塔。
    #   光束才是"灯塔"的识别特征，光晕只是让它不显得干巴。
    prof = np.clip(1.0 - (r - 26.0) / BEAM_LEN, 0.0, 1.0) ** 1.05
    angular = np.exp(-((ang - BEAM_TILT) / BEAM_SPREAD) ** 2)
    beam = prof * angular
    beam *= np.clip((r - 40.0) / 55.0, 0.0, 1.0)      # 灯室边上淡出，避免糊在灯上
    beam *= (np.abs(dx) > 30.0).astype(np.float32)    # 挖掉正后方（那里是塔身，不该发光）
    beam_a = np.clip(beam, 0.0, 1.0) * 0.92

    glow_a = np.exp(-(r / 112.0) ** 2) * 0.50

    img = np.zeros((S, S, 4), dtype=np.float32)
    alpha = np.maximum(beam_a, glow_a)
    # 颜色按各自贡献加权：光束偏暖黄，光晕偏亮白（模拟灯芯过曝）
    wsum = np.maximum(beam_a + glow_a, 1e-6)
    for i in range(3):
        img[..., i] = (BEAM[i] * beam_a + LAMP[i] * glow_a) / wsum
    img[..., 3] = alpha * 255.0

    return Image.fromarray(img.astype(np.uint8), 'RGBA')


def build_foreground():
    """灯塔前景层（透明底）。"""
    layer = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # --- 底座（先画，被塔身压住一点没关系） ---
    d.polygon(_pts([
        (CX - BASE_BOT_HW, BASE_BOT_Y), (CX + BASE_BOT_HW, BASE_BOT_Y),
        (CX + BASE_TOP_HW, BASE_TOP_Y), (CX - BASE_TOP_HW, BASE_TOP_Y),
    ]), fill=BASE_C + (255,))
    # 底座受光上沿
    d.polygon(_pts([
        (CX - BASE_TOP_HW, BASE_TOP_Y), (CX + BASE_TOP_HW, BASE_TOP_Y),
        (CX + BASE_TOP_HW, BASE_TOP_Y + 9.0), (CX - BASE_TOP_HW, BASE_TOP_Y + 9.0),
    ]), fill=BASE_HI + (255,))

    # --- 塔身 ---
    d.polygon(_pts([
        (CX - BODY_BOT_HW, BODY_BOT_Y), (CX + BODY_BOT_HW, BODY_BOT_Y),
        (CX + BODY_TOP_HW, BODY_TOP_Y), (CX - BODY_TOP_HW, BODY_TOP_Y),
    ]), fill=TOWER + (255,))

    # 背光面：右半边叠一层半透明冷灰，塔就有体积了（小尺寸下也能看出是立体的）
    d.polygon(_pts([
        (CX, BODY_BOT_Y), (CX + BODY_BOT_HW, BODY_BOT_Y),
        (CX + BODY_TOP_HW, BODY_TOP_Y), (CX, BODY_TOP_Y),
    ]), fill=TOWER_DIM + (150,))

    # --- 塔身条纹（严格贴合梯形宽度） ---
    for y0, y1 in STRIPES:
        d.polygon(_pts([
            (CX - _hw_at(y0), y0), (CX + _hw_at(y0), y0),
            (CX + _hw_at(y1), y1), (CX - _hw_at(y1), y1),
        ]), fill=STRIPE + (255,))

    # --- 观景台（栏杆） ---
    d.polygon(_pts([
        (CX - GALLERY_HW, LAMP_BOT_Y), (CX + GALLERY_HW, LAMP_BOT_Y),
        (CX + GALLERY_HW, GALLERY_BOT_Y), (CX - GALLERY_HW, GALLERY_BOT_Y),
    ]), fill=STRIPE + (255,))

    # --- 灯室 ---
    d.polygon(_pts([
        (CX - LAMP_HW, LAMP_BOT_Y), (CX + LAMP_HW, LAMP_BOT_Y),
        (CX + LAMP_HW, LAMP_TOP_Y), (CX - LAMP_HW, LAMP_TOP_Y),
    ]), fill=LAMP + (255,))

    # --- 尖顶 ---
    d.polygon(_pts([
        (CX - LAMP_HW, CAP_Y), (CX + LAMP_HW, CAP_Y), (CX, SPIRE_Y),
    ]), fill=TOWER + (255,))

    # --- 灯室竖栅（几条深色细杆，小尺寸下靠它认出"这是灯"） ---
    for k in (-1, 0, 1):
        x = CX + k * 30.0
        d.polygon(_pts([
            (x - 4.0, LAMP_TOP_Y + 10.0), (x + 4.0, LAMP_TOP_Y + 10.0),
            (x + 4.0, LAMP_BOT_Y - 6.0), (x - 4.0, LAMP_BOT_Y - 6.0),
        ]), fill=(214, 162, 60, 220))

    layer = layer.resize((S, S), Image.LANCZOS)
    out = Image.alpha_composite(_beam_and_glow(), layer)
    return out


# ----------------------------------------------------------------------------
# 背景层
# ----------------------------------------------------------------------------
def build_background():
    """深海夜 + 海面反光。铺满整张画布（系统会按图标形状裁切，不需要留边）。"""
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)

    # 以灯塔为中心的大范围径向渐变
    d = np.sqrt((xx - CX) ** 2 + (yy - 470.0) ** 2) / 760.0
    t = np.clip(d, 0.0, 1.0) ** 0.9

    img = np.zeros((S, S, 3), dtype=np.float32)
    for i in range(3):
        img[..., i] = DEEP_IN[i] * (1 - t) + DEEP_OUT[i] * t

    # 海面：越往下越亮，横向中间最亮（像月光铺在水面）
    sea_v = np.clip((yy - 660.0) / 364.0, 0.0, 1.0) ** 0.8
    sea_h = np.exp(-((xx - CX) / 560.0) ** 2)
    sea_a = sea_v * sea_h * 0.42
    for i in range(3):
        img[..., i] = img[..., i] * (1 - sea_a) + SEA[i] * sea_a

    # 海面波纹：高斯带画正弦线，比 PIL 画线平滑（不会有折线锯齿）
    for y0, amp, wl, al in [(704.0, 5.0, 250.0, 0.16),
                            (764.0, 8.0, 320.0, 0.13),
                            (840.0, 11.0, 400.0, 0.10),
                            (930.0, 14.0, 470.0, 0.07)]:
        band = np.exp(-((yy - (y0 + amp * np.sin(xx / wl * 2 * np.pi))) / 3.2) ** 2) * al
        band *= np.exp(-((xx - CX) / 620.0) ** 2)
        for i in range(3):
            img[..., i] = img[..., i] * (1 - band) + (188, 222, 255)[i] * band

    # 星点：稀疏、暗淡，只在画面上半部分（下半是海）
    rng = np.random.default_rng(20260919)      # 固定种子 —— 每次生成结果一致，可复现
    stars = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(stars)
    for _ in range(84):
        x = float(rng.uniform(40, S - 40))
        y = float(rng.uniform(30, 640))
        # 越靠上越亮，避免下半部分出现"海里的星星"
        a = int(rng.uniform(40, 150) * (1.0 - y / 720.0) + 18)
        r = float(rng.uniform(1.0, 2.6))
        sd.ellipse([x - r, y - r, x + r, y + r], fill=STAR + (max(20, min(200, a)),))

    base = Image.fromarray(img.astype(np.uint8), 'RGB').convert('RGBA')
    return Image.alpha_composite(base, stars)


# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
PROJECT = r"D:\work\DevEcoStudioProject\Lighthouse"

TARGETS = [
    (r"AppScope\resources\base\media\foreground.png", "foreground"),
    (r"AppScope\resources\base\media\background.png", "background"),
    (r"entry\src\main\resources\base\media\foreground.png", "foreground"),
    (r"entry\src\main\resources\base\media\background.png", "background"),
]

START_ICON_SIZE = 152
SPLASH_LOGO_SIZE = 420


def build_logo(fg, bg, size):
    """圆角方形图标：把合成好的整图从中心裁一块出来，再缩到 size。

    为什么裁而不是直接把 1024 整张缩下去 —— 那样灯塔只占 1024 里的 62%，
    启动页上看着又小又空。裁到 704 见方再缩，灯塔刚好占满，视觉上才立得住。
    """
    full = Image.alpha_composite(bg, fg)
    side = 704
    off = (S - side) // 2
    crop = full.crop((off, off - 26, off + side, off + side - 26))

    # 圆角：方形也能看，但圆角更贴 HarmonyOS 的观感
    radius = 168
    mask = Image.new('L', (side, side), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, side - 1, side - 1], radius=radius, fill=255)
    crop.putalpha(mask)

    return crop.resize((size, size), Image.LANCZOS)


def build_start_icon(fg, bg):
    """系统启动窗口的图标（152×152，由 startWindowIcon 引用）。"""
    return build_logo(fg, bg, START_ICON_SIZE)


def build_splash_logo(fg, bg):
    """应用内启动页的图标（420×420）。

    单独出一张大图，是因为 152px 的原图在高密度屏上放大到 100vp
    （1256px 宽的机器约 350px）会明显发虚。系统启动窗口那张尺寸是定死的，
    改不了，所以应用内这张自己出。
    """
    return build_logo(fg, bg, SPLASH_LOGO_SIZE)


def main():
    args = sys.argv[1:]
    preview_only = "--preview" in args
    out_dir = None
    if "--out" in args:
        out_dir = args[args.index("--out") + 1]

    print("绘制前景层 / 背景层 …")
    fg = build_foreground()
    bg = build_background()
    start = build_start_icon(fg, bg)
    splash = build_splash_logo(fg, bg)

    shots = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_shots")
    os.makedirs(shots, exist_ok=True)

    # 预览图：三种裁切形状各来一张，**这是唯一能提前发现"塔尖被切掉"的办法**
    composite = Image.alpha_composite(bg, fg)
    prev = Image.new('RGBA', (3 * 340 + 40, 380), (16, 20, 30, 255))
    for i, (name, shape) in enumerate([("circle", "circle"), ("squircle", "squircle"), ("square", "square")]):
        ic = composite.copy()
        m = Image.new('L', (S, S), 0)
        dm = ImageDraw.Draw(m)
        if shape == "circle":
            dm.ellipse([8, 8, S - 8, S - 8], fill=255)
        elif shape == "squircle":
            dm.rounded_rectangle([8, 8, S - 8, S - 8], radius=230, fill=255)
        else:
            dm.rounded_rectangle([8, 8, S - 8, S - 8], radius=60, fill=255)
        ic.putalpha(m)
        ic = ic.resize((320, 320), Image.LANCZOS)
        prev.paste(ic, (20 + i * 340, 20), ic)
        prev.paste(start.resize((72, 72), Image.LANCZOS), (20 + i * 340 + 320 - 80, 300))
    prev.convert('RGB').save(os.path.join(shots, "icon_preview.png"))
    print(f"  预览 → {os.path.join(shots, 'icon_preview.png')}")

    if preview_only:
        print("仅预览，未改动工程。")
        return

    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        fg.save(os.path.join(out_dir, "foreground.png"))
        bg.save(os.path.join(out_dir, "background.png"))
        start.save(os.path.join(out_dir, "startIcon.png"))
        splash.save(os.path.join(out_dir, "splash_logo.png"))
        print(f"  已输出到 {out_dir}")
        return

    # 备份模板原图（万一要对比 / 回退）
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    bak = os.path.join(shots, f"_icon_template_backup_{stamp}")
    os.makedirs(bak, exist_ok=True)
    for rel, _ in TARGETS:
        src = os.path.join(PROJECT, rel)
        if os.path.exists(src):
            flat = rel.replace("\\", "__")
            shutil.copy2(src, os.path.join(bak, flat))
    old_start = os.path.join(PROJECT, r"entry\src\main\resources\base\media\startIcon.png")
    if os.path.exists(old_start):
        shutil.copy2(old_start, os.path.join(bak, "startIcon.png"))
    print(f"  模板原图已备份 → {bak}")

    for rel, kind in TARGETS:
        dst = os.path.join(PROJECT, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        (fg if kind == "foreground" else bg).save(dst)
        print(f"  写入 {rel}  ({os.path.getsize(dst)} B)")

    dst = os.path.join(PROJECT, r"entry\src\main\resources\base\media\startIcon.png")
    start.save(dst)
    print(f"  写入 entry\\src\\main\\resources\\base\\media\\startIcon.png  ({os.path.getsize(dst)} B)")

    dst = os.path.join(PROJECT, r"entry\src\main\resources\base\media\splash_logo.png")
    splash.save(dst)
    print(f"  写入 entry\\src\\main\\resources\\base\\media\\splash_logo.png  ({os.path.getsize(dst)} B)")
    print("完成。")


if __name__ == "__main__":
    main()
