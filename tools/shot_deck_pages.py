"""把 deck.html 里的每一页（.pg）单独截一张图，便于逐页核对版式。

用法：python shot_deck_pages.py <deck.html> <输出目录> [--scale 0.6]
"""
import argparse
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

from playwright.sync_api import sync_playwright   # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("html")
    ap.add_argument("outdir")
    args = ap.parse_args()

    html = os.path.abspath(args.html).replace("\\", "/")
    os.makedirs(args.outdir, exist_ok=True)

    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge", headless=True)
        pg = b.new_page(viewport={"width": 1200, "height": 900}, device_scale_factor=1)
        pg.goto("file:///" + html, wait_until="load")
        pg.wait_for_timeout(1200)
        els = pg.query_selector_all(".pg")
        print(f"页数 {len(els)}")
        for i, el in enumerate(els, 1):
            el.screenshot(path=os.path.join(args.outdir, f"p{i:02d}.png"))
        b.close()
    print("✓ 完成 →", args.outdir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
