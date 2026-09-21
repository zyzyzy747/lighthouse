#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
从模拟器截图里定位指定颜色的可点区域（按钮/标签），输出屏幕坐标。

为什么需要它：本机 Agent 读不了图片内容，但能读像素。
用颜色找块 → 算中心 → 交给 hdc uinput 点击，是当前唯一可靠的
"看见界面"的手段。

用法:
  python find_button.py shot.jpeg --color FF B0 20            # 找橙色按钮
  python find_button.py shot.jpeg --color 4A 9E FF --min-area 8000
  python find_button.py shot.jpeg --list                      # 列出所有显著色块

参数:
  --color R G B     目标颜色（hex，可带 # 或空格分隔）
  --tol N           颜色容差，默认 24
  --min-area N      最小像素面积，默认 3000
  --top N           只报告面积最大的前 N 块，默认 5
  --list            列出图里所有占比 >=1% 的颜色，用于校准目标色
"""
import sys
import argparse
from collections import Counter

import numpy as np
from PIL import Image

sys.stdout.reconfigure(encoding="utf-8")


def parse_color(vals):
    """把 ['FF','B0','20'] 或 ['#FFB020'] 转成 (r,g,b)"""
    if len(vals) == 1:
        h = vals[0].lstrip("#")
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
    return tuple(int(v, 16) if isinstance(v, str) else int(v) for v in vals)


def label_components(mask):
    """两遍扫描的连通域标记（4 邻接），返回 (labels, count)。纯 numpy 实现，
    避免依赖 scipy。"""
    h, w = mask.shape
    labels = np.zeros((h, w), dtype=np.int32)
    parent = [0]

    def find(x):
        root = x
        while parent[root] != root:
            root = parent[root]
        while parent[x] != root:      # 路径压缩
            parent[x], x = root, parent[x]
        return root

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    nxt = 1
    for y in range(h):
        row = mask[y]
        for x in range(w):
            if not row[x]:
                continue
            up = labels[y - 1, x] if y > 0 else 0
            left = labels[y, x - 1] if x > 0 else 0
            if up and left:
                labels[y, x] = min(up, left)
                union(up, left)
            elif up or left:
                labels[y, x] = up or left
            else:
                parent.append(nxt)
                labels[y, x] = nxt
                nxt += 1

    # 统一改写为根标签
    remap = {}
    for y in range(h):
        for x in range(w):
            lb = labels[y, x]
            if lb:
                r = find(lb)
                if r not in remap:
                    remap[r] = len(remap) + 1
                labels[y, x] = remap[r]
    return labels, len(remap)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--color", nargs="+")
    ap.add_argument("--tol", type=int, default=24)
    ap.add_argument("--min-area", type=int, default=3000)
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    img = Image.open(args.image).convert("RGB")
    arr = np.asarray(img)
    h, w = arr.shape[:2]
    print(f"图像尺寸: {w} x {h}")

    if args.list:
        flat = arr.reshape(-1, 3)
        cnt = Counter(map(tuple, flat[::7]))     # 抽样加速
        total = sum(cnt.values())
        print("占比 >=1% 的颜色:")
        for (r, g, b), n in cnt.most_common(24):
            pct = n * 100.0 / total
            if pct >= 1.0:
                print(f"  #{r:02X}{g:02X}{b:02X}  ({r:3d},{g:3d},{b:3d})  {pct:5.2f}%")
        return

    if not args.color:
        print("错误: 需要 --color 或 --list")
        sys.exit(2)

    tr, tg, tb = parse_color(args.color)
    print(f"目标色: #{tr:02X}{tg:02X}{tb:02X}  容差 ±{args.tol}")

    diff = np.abs(arr.astype(np.int16) - np.array([tr, tg, tb], dtype=np.int16))
    mask = (diff <= args.tol).all(axis=2)
    print(f"匹配像素: {int(mask.sum())}")

    if mask.sum() == 0:
        print("没找到该颜色 —— 用 --list 看看图里有哪些主色")
        sys.exit(1)

    # 先用 numpy 快速切出行/列投影，避免对整图做慢速连通域标记
    ys, xs = np.where(mask)
    print(f"整体范围: x {xs.min()}~{xs.max()}, y {ys.min()}~{ys.max()}")

    # 按行投影切分垂直分离的色带（按钮往往在同一列，纵向可能有两个）
    rowsum = mask.sum(axis=1)
    bands = []
    in_band = False
    start = 0
    for y in range(h):
        if rowsum[y] > 0 and not in_band:
            in_band, start = True, y
        elif rowsum[y] == 0 and in_band:
            in_band = False
            if y - start >= 8:
                bands.append((start, y - 1))
    if in_band and h - start >= 8:
        bands.append((start, h - 1))

    print(f"检出 {len(bands)} 条色带:")
    for (y0, y1) in bands:
        sub = mask[y0:y1 + 1]
        colsum = sub.sum(axis=0)
        xs2 = np.where(colsum > 0)[0]
        if len(xs2) == 0:
            continue
        x0, x1 = int(xs2.min()), int(xs2.max())
        area = int(sub.sum())
        if area < args.min_area:
            continue
        cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
        print(f"  y {y0:4d}~{y1:4d}  x {x0:4d}~{x1:4d}  "
              f"面积 {area:7d}  中心 ({cx}, {cy})  尺寸 {x1-x0+1}x{y1-y0+1}")
        print(f"      → hdc uinput -T -c {cx} {cy}")


if __name__ == "__main__":
    main()
