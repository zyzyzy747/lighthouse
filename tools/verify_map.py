# -*- coding: utf-8 -*-
"""真实求职地图验收（Map Kit）

这一套的存在意义只有一个：**证明地图到底画不画得出来**。

为什么不能靠"看着像"：MapComponent 在没有地图权益时会**静默白屏** ——
编译能过、装得上、界面不报错，只是那块区域一片空白。所以这里用两条独立证据：

  ① 应用自己的结论行 —— 地图自检结论：PASS / FAIL（FAIL 会带 code）
  ② 截图的像素统计 —— 地图区域的颜色方差与唯一色数。
     真地图（路网 + 底图 + 标注）方差远大于一块纯色白板。

两条一起看才能定性：日志说 PASS 但截图是纯色，说明"初始化成功但没渲染"；
截图看着花但日志 FAIL，说明那可能压根不是地图。
"""
import sys
import os
import re
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_widget as vw  # noqa: E402

BUNDLE = "com.wuit.lighthouse"
HAP = r"D:\work\DevEcoStudioProject\Lighthouse\entry\build\default\outputs\default\entry-default-signed.hap"
SHOT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_shots")


def logs(pattern, tail=200):
    """读 hilog。⚠ 地图服务跑在独立进程，系统侧的日志也要一起看。"""
    return vw.shell(f"hilog -x 2>/dev/null | grep -E '{pattern}' | tail -{tail}")


def region_of_map(lay):
    """借「求职地图」标题反推地图区域（仅在自动探测失败时用作参考）。

    ⚠ `find_text_node` 返回的是 **(cx, cy, bounds)** 三元组，不是节点字典 ——
      第一版按 dict 用，直接 AttributeError。bounds 是 [x1, y1, x2, y2]。
    """
    node = vw.find_text_node(lay, "求职地图", exact=False)
    if not node:
        return None
    _cx, _cy, bounds = node
    if not bounds or len(bounds) != 4:
        return None
    x1, y1, x2, y2 = bounds
    return (x1, y2, x2, y2 + 600)


def find_rich_band(path, band=40, min_std=20, min_uniq=2000):
    """自动找出屏幕上「颜色最丰富的一段连续横带」。

    为什么不用硬编码区域：地图卡片的纵坐标取决于它上面有几个节点、设备密度是多少，
    写死一个 `(30,300,384,500)` 在换设备/改布局后必然失效，而且**失效时是假绿还是假红
    完全看运气**。真地图的特征是「颜色极多 + 局部对比强」，直接找这个特征，
    布局怎么变都不影响（这也是 skill 里「别写死坐标」那条）。

    返回 (y0, y1) 或 None（None = 屏幕上根本没有这样的区域 = 地图没渲染）。
    """
    from PIL import Image
    import numpy as np

    a = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    H = a.shape[0]
    spans = []
    for y in range(0, H - band, band):
        b = a[y:y + band]
        spans.append((y, float(b.std()), len(np.unique(b.reshape(-1, 3), axis=0))))

    best = None
    cur = None
    for y, sd, uq in spans:
        if sd > min_std and uq > min_uniq:
            if cur is None:
                cur = [y, y + band]
            else:
                cur[1] = y + band
        else:
            if cur is not None:
                if best is None or (cur[1] - cur[0]) > (best[1] - best[0]):
                    best = cur
                cur = None
    if cur is not None and (best is None or (cur[1] - cur[0]) > (best[1] - best[0])):
        best = cur
    return (best[0], best[1]) if best else None


def pixel_stats(path, box):
    """一块区域的颜色丰富度。真地图 vs 白板，一眼分得开。"""
    from PIL import Image
    import numpy as np

    im = Image.open(path).convert("RGB")
    W, H = im.size
    x1, y1, x2, y2 = box
    x1 = max(0, x1); y1 = max(0, y1)
    x2 = min(W, x2); y2 = min(H, y2)
    if x2 <= x1 or y2 <= y1:
        return None
    arr = np.asarray(im.crop((x1, y1, x2, y2))).astype(np.float32)
    dark = float((arr.max(axis=2) < 130).mean())   # 地图标注文字 / 路网线
    return {
        "std": float(arr.std()),
        "uniq": len(np.unique(arr.reshape(-1, 3), axis=0)),
        "mean": arr.mean(axis=(0, 1)),
        "dark": dark,
        "px": arr.shape[0] * arr.shape[1],
    }


def main():
    print("=" * 64)
    print("灯塔 · 真实求职地图 验收（Map Kit）")
    print("=" * 64)

    if not os.path.isfile(HAP):
        print(f"  ✗ 找不到 hap：{HAP}")
        return 2
    print(f"  产物 {os.path.getsize(HAP)} B  {time.strftime('%H:%M:%S', time.localtime(os.path.getmtime(HAP)))}")

    # ── ① 重装（Profile 刚重签过，覆盖安装有签名不匹配的风险，直接卸了重装最稳）
    print("\n【1】安装与冷启动")
    vw.force_stop(BUNDLE)
    u = vw.hdc("uninstall", BUNDLE)
    print(f"   uninstall：{u[:60]}")
    time.sleep(2)
    i = vw.hdc("install", HAP)
    print(f"   install：{i[:80]}")
    # ⚠ 不能拿 install 的输出判成败 —— 它的成功信息走 stderr，而 vw.hdc 只收 stdout。
    #   直接问系统「这个包在不在」，这是实测而不是转述。
    time.sleep(2)
    dumped = vw.shell(f"bm dump -n {BUNDLE} 2>&1 | head -4")
    vw.check(BUNDLE in dumped, "hap 安装成功（bm dump 查得到）", f"bm dump：{dumped[:160]}")

    vw.shell("hilog -r")
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_load_demo 1 --pi lh_autologin 1")
    vw.check(vw.ensure_main_ui(), "冷启动进入主界面", "主界面没画出来")

    # ── ② 进地图页
    print("\n【2】进入作战地图页")
    vw.enter_tab_shell()
    vw.tap_tab("地图")

    # 地图异步初始化。**轮询结论日志**而不是写死 sleep（skill：能观察到"完成"就别用固定等待）
    concl = ""
    for _ in range(30):
        concl = logs("地图自检结论", tail=20)
        if "地图自检结论" in concl:
            break
        time.sleep(1)

    lay = vw.dump_layout("map_page")
    ts = vw.texts_of(lay)
    vw.check("求职地图" in ts, "地图卡片出现在页面上", f"页面文字：{ts[:12]}")

    # ── ③ 应用侧结论
    print("\n【3】应用侧自检结论")
    print("   " + concl.strip().replace("\n", "\n   ")[:400])
    vw.check("地图自检结论：PASS" in concl, "MapComponent 初始化成功（PASS）",
             "不是 PASS —— 带 code 的话对照官方 FAQ《地图无法加载显示》")

    # ── ④ 坐标解析
    #    解析是逐个异步做的（每家公司一次网络请求），8 家要好几秒。
    #    ⚠ 必须**轮询到收尾那条日志**，不能读一次就断言 —— 第一版就是读太早，
    #      明明在正常解析，却报「一条解析日志都没有」。
    print("\n【4】地点解析（公司名 → 真实经纬度）")
    resolved = ""
    for _ in range(40):
        resolved = logs("地点解析|地图标记 ", tail=80)
        if "地图标记 " in resolved:
            break
        time.sleep(1)

    res = "\n".join(l for l in resolved.splitlines() if "地点解析" in l)
    print("   " + res.strip().replace("\n", "\n   ")[:900])
    n_search = res.count("地点解析 search")
    n_seed = res.count("地点解析 seed")
    n_city = res.count("地点解析 city")
    print(f"   搜索命中 {n_search} · 种子兜底 {n_seed} · 城市中心 {n_city}")
    vw.check(n_search + n_seed + n_city > 0, "至少解析出一个地点",
             "一条解析日志都没有 —— reload 可能抛异常了")
    vw.check(n_search > 0, "走的是「华为地点搜索」拿到了真 POI 坐标",
             f"没有任何搜索命中（search={n_search}）—— 检查网络与地图服务")

    marks = "\n".join(l for l in resolved.splitlines() if "地图标记 " in l)
    print("   " + marks.strip()[-400:])
    vw.check("地图标记 " in marks, "标记已下发到地图", marks.strip()[-120:])

    # ── ⑤ 像素证据
    print("\n【5】截图像素证据")
    p = vw.shot("map_1.jpeg")
    band = find_rich_band(p)
    print(f"   自动探测到的高信息量区域：{band}")
    hint = region_of_map(lay)
    if hint:
        print(f"   （按标题推算的参考区域：{hint[1]}~{hint[3]}）")
    vw.check(band is not None, "屏幕上存在「真地图级」的颜色丰富区域",
             "整屏找不到一段有内容的区域 —— 地图没渲染（白屏）")

    # ⚠ 闭环：光有"某处颜色丰富"是不够的 —— 别的控件（雷达图、封面图）也可能丰富。
    #   必须证明这段区域**落在「求职地图」这张卡片上**，否则这条判据可以假绿。
    if band is not None and hint is not None:
        overlap = band[0] < hint[3] and band[1] > hint[1]
        vw.check(overlap, "探测到的丰富区域与地图卡片位置吻合",
                 f"探测 {band} 与标题推算 {hint[1]}~{hint[3]} 不重叠 —— 颜色丰富的可能是别的东西")

    if band is not None:
        from PIL import Image
        W = Image.open(p).size[0]
        box = (20, band[0], W - 20, band[1])
        st = pixel_stats(p, box)
        print(f"   区域 {box}  高 {band[1] - band[0]}px")
        print(f"   颜色标准差 {st['std']:.1f} · 唯一色 {st['uniq']} · 均值 RGB {st['mean'].round(1)} · 深色像素占比 {st['dark'] * 100:.2f}%")
        vw.check(st["uniq"] > 3000, "颜色数量达到地图量级（底图+路网+标注）",
                 f"唯一色仅 {st['uniq']}")
        vw.check(st["dark"] > 0.001, "有地图标注/路网线条（深色像素）",
                 f"深色像素占比 {st['dark'] * 100:.3f}% 过低，不像地图")
        # 裁出来存档，供人工复核
        crop = os.path.join(SHOT_DIR, "map_region.png")
        Image.open(p).crop(box).save(crop)
        print(f"   已裁出地图区 → {crop}")

    # ── ⑥ 城市筛选
    print("\n【6】城市筛选（把镜头从全国收到一个城市）")
    if "武汉" in ts:
        n_before = logs("地图视野已调整", tail=60).count("地图视野已调整")
        shot_a = vw.shot("map_all.jpeg")
        node = vw.find_text_node(lay, "武汉", exact=True)
        if node is None:
            vw.check(False, "", "布局里找不到「武汉」城市 chip")
        else:
            cx, cy, _b = node
            vw.tap(cx, cy)
            time.sleep(3)
            after = logs("地图视野已调整", tail=60)
            print("   " + after.strip().splitlines()[-1][-120:] if after.strip() else "   （无新日志）")
            vw.check(after.count("地图视野已调整") > n_before, "点击城市后触发了视野切换",
                     "点了「武汉」但没有新的视野调整日志")

            shot_b = vw.shot("map_wuhan.jpeg")
            # 镜头真的动过 ⇒ 地图区域像素必然大改
            import numpy as np
            from PIL import Image
            a1 = np.asarray(Image.open(shot_a).convert("L")).astype(np.int16)
            a2 = np.asarray(Image.open(shot_b).convert("L")).astype(np.int16)
            y0, y1 = band[0], band[1]
            d = (np.abs(a1[y0:y1, 20:-20] - a2[y0:y1, 20:-20]) > 26).sum()
            print(f"   地图区变化像素 {int(d)}")
            vw.check(d > 20000, "地图画面确实变了（镜头移动生效）",
                     f"只变了 {int(d)} 像素，镜头可能没动")
    else:
        vw.check(True, "只有一座城市的点，城市筛选不显示（跳过）", "")

    # ── ⑦ 降级兜底
    print("\n【7】降级兜底")
    if "地图自检结论：FAIL" in concl:
        vw.check(any("地图没能加载出来" in t for t in ts), "地图失败时显示降级文案",
                 f"页面文字：{ts[:12]}")
    else:
        vw.check(True, "地图正常，无需降级（跳过）", "")

    total = len(vw.RESULTS)
    passed = sum(1 for r in vw.RESULTS if r)
    print(f"\n{'=' * 64}")
    print(f"结果：{passed}/{total} 通过")
    print("=" * 64)
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
