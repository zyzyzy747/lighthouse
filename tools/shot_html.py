"""把本地 HTML 渲染成 PNG（自查版式用）。

本机没有 LibreOffice/poppler，`slidep screenshot` 又踩 SDK 路径 bug；但 Edge 在
（`channel="msedge"`），所以直接用 playwright 驱动系统 Edge 截图 —— 不用下载 Chromium。

用法：
  python shot_html.py <html路径> <输出png> [--full] [--width 1600] [--wait 800]
"""
import argparse
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

from playwright.sync_api import sync_playwright   # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("html")
    ap.add_argument("out")
    ap.add_argument("--full", action="store_true", help="整页截图")
    ap.add_argument("--width", type=int, default=1500)
    ap.add_argument("--height", type=int, default=1000)
    ap.add_argument("--wait", type=int, default=900, help="等渲染的毫秒数（图片解码）")
    args = ap.parse_args()

    url = "file:///" + os.path.abspath(args.html).replace("\\", "/")
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)

    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        pg = b.new_page(viewport={"width": args.width, "height": args.height},
                        device_scale_factor=1)
        pg.goto(url, wait_until="load")
        pg.wait_for_timeout(args.wait)
        pg.screenshot(path=args.out, full_page=args.full)
        b.close()
    print(f"✓ {args.out}  ({os.path.getsize(args.out)/1024:.0f} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
