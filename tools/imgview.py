#!/usr/bin/env python3
"""
把截图降成字符网格，让"看不见图"的环境也能判断版面结构。

用途：模拟器截图后，先跑这个看清"哪里有什么"，再用 find_button.py 精确取坐标。
两者分工：imgview 回答「版面对不对」，find_button 回答「点哪里」。

用法：
    python imgview.py shot.jpeg                 # 默认 64 列
    python imgview.py shot.jpeg --cols 96       # 更细
    python imgview.py shot.jpeg --crop 0,0,1256,1400   # 只看上半部分

字符含义（按色相/亮度归类）：
    ' ' 近白        '.' 浅灰       ':' 中灰      '+' 深灰
    '*' 更深        '#' 近黑
    'O' 橙黄        'Y' 黄         'G' 绿        'B' 蓝
    'P' 紫          'R' 红
有色字符大写=饱和鲜艳，小写=淡（接近灰）
"""
import argparse
import colorsys
import sys

from PIL import Image


# 需要重点关注的品牌色：命中时按精确色标出，便于一眼定位
LANDMARKS = [
    ("橙 #FFB020 accent", (255, 176, 32), 26, "O"),
    ("蓝 #4A9EFF primary", (74, 158, 255), 26, "B"),
    ("绿 #3DD68C ok", (61, 214, 140), 26, "G"),
    ("红 #FF5C5C danger", (255, 92, 92), 26, "R"),
    ("紫 #A78BFA purple", (167, 139, 250), 26, "P"),
]


def classify(r, g, b):
    h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
    deg = h * 360.0
    # ⚠ 亮度太低时色相不可辨：本项目的深色底 #0A1120 饱和度高达 0.69，
    #   若先按色相分类会被判成「鲜艳蓝」，和真正的亮蓝完全混淆。
    #   所以亮度优先 —— v < 0.30 一律按灰阶处理。
    if v < 0.30:
        if v > 0.22:
            return '+'
        if v > 0.12:
            return '*'
        return '#'
    if s < 0.14:
        if v > 0.93:
            return ' '
        if v > 0.76:
            return '.'
        if v > 0.52:
            return ':'
        if v > 0.36:
            return '+'
        return '*'
    # 有彩色：饱和度越高越大写
    upper = s >= 0.42
    if deg < 15 or deg >= 330:
        ch = 'R'
    elif deg < 45:
        ch = 'O'
    elif deg < 70:
        ch = 'Y'
    elif deg < 165:
        ch = 'G'
    elif deg < 260:
        ch = 'B'
    elif deg < 330:
        ch = 'P'
    else:
        ch = 'R'
    return ch if upper else ch.lower()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--cols", type=int, default=64, help="字符列数，默认 64")
    ap.add_argument("--crop", default="", help="x0,y0,x1,y1 只渲染该区域")
    ap.add_argument("--rows", type=int, default=0, help="覆盖行数（默认按字符 2:1 宽高比推算）")
    args = ap.parse_args()

    img = Image.open(args.image).convert("RGB")
    if args.crop:
        x0, y0, x1, y1 = [int(v) for v in args.crop.split(",")]
        img = img.crop((x0, y0, x1, y1))
    w, h = img.size

    cols = args.cols
    rows = args.rows if args.rows > 0 else max(1, int(cols * (h / w) / 2.0))
    small = img.resize((cols, rows), Image.BOX)
    px = small.load()

    print(f"图像 {w}x{h} → 网格 {cols}x{rows}（每格约 {w/cols:.0f}x{h/rows:.0f} px）")
    print("    " + "".join(str((i // 10) % 10) for i in range(cols)))
    print("    " + "".join(str(i % 10) for i in range(cols)))

    for y in range(rows):
        line = []
        for x in range(cols):
            r, g, b = px[x, y]
            # 命中品牌色优先标出 —— 这些通常是可点控件或关键信息
            tagged = None
            for _name, (tr, tg, tb), tol, ch in LANDMARKS:
                if abs(r - tr) <= tol and abs(g - tg) <= tol and abs(b - tb) <= tol:
                    tagged = ch
                    break
            line.append(tagged if tagged else classify(r, g, b))
        y0 = int(y * h / rows)
        y1 = int((y + 1) * h / rows)
        print(f"{y0:>4} " + "".join(line))

    print()
    print("每行行首数字 = 该行在【原图】里的 y 起始像素")
    print("列号见顶部两行；x = 列号 * %d" % (w // cols))


if __name__ == "__main__":
    sys.exit(main())
