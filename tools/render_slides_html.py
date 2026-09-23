"""把 slides/*.slide 渲染成一个自包含 HTML 预览页（用来肉眼验收版式）。

为什么需要它：
  · 本机没有 LibreOffice / poppler，`slidep screenshot` 又踩着 SDK 的
    `file:///workspace/...` 路径 bug（见 harmonyos 侧的同类经验：交付前要
    有能自己看的产物）。
  · .slide 是类 JSX + flex 的写法，与 CSS flex 几乎同构，所以这条路
    保真度够用来**查版式事故**（溢出、错位、缺图），不是拿来当成品交付。

映射规则（够用即可，不求完备）：
  Slide/Box/Text/span → div/div/div/span，Box 默认 flex-direction: row（ArkUI 同款）
  Image → img；style 里 camelCase 转 kebab-case；裸数字补 px
  ⚠ lineHeight 小于 3 的按**倍数**处理（源文件里 1.7 这种是倍数写法，
    补成 px 会把行高压成 1.7px —— 全篇文字挤成一坨）。

用法：
  python render_slides_html.py                    # → _preview/deck.html
  python render_slides_html.py --out x.html
"""
import argparse
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)                      # lighthouse-guanggu/
DECK = os.path.join(PROJ, "submit", "灯塔作品介绍")
SLIDES = os.path.join(DECK, "slides")

TAG_RE = re.compile(r"<(/?)([A-Za-z]+)([^>]*?)(/?)>")

# 这些属性在 CSS 里必须是**无单位**的数字
UNITLESS = {"flex", "flexGrow", "flexShrink", "opacity", "zIndex",
            "fontWeight", "order", "lineClamp"}


def camel_to_kebab(k: str) -> str:
    return re.sub(r"[A-Z]", lambda m: "-" + m.group(0).lower(), k)


def _split_top(raw: str):
    """按顶层逗号切分（跳过括号与引号内部的逗号）。"""
    out, buf, depth, quote = [], [], 0, ""
    for ch in raw:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = ""
            continue
        if ch in "'\"":
            quote = ch
            buf.append(ch)
        elif ch in "([":
            depth += 1
            buf.append(ch)
        elif ch in ")]":
            depth -= 1
            buf.append(ch)
        elif ch == "," and depth == 0:
            out.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if buf:
        out.append("".join(buf))
    return out


def parse_style(raw: str) -> str:
    """把 { flexDirection: 'row', gap: 18 } 变成 CSS 声明串。"""
    decls = []
    for part in _split_top(raw):
        if ":" not in part:
            continue
        key, val = part.split(":", 1)
        key, val = key.strip(), val.strip()
        if not key:
            continue
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
            val = val[1:-1]                     # 字符串：原样用
        else:                                    # 裸数字：ArkUI 的 vp ⇒ px
            try:
                num = float(val)
                if key in UNITLESS or (key == "lineHeight" and abs(num) < 3):
                    val = val
                else:
                    val = f"{val}px"
            except ValueError:
                pass
        decls.append(f"{camel_to_kebab(key)}: {val}")
    return "; ".join(decls)


def split_attrs(attrs: str):
    """抽出 style={{...}} 与其余属性（src/class 等）。"""
    style = ""
    i = attrs.find("style=")
    if i >= 0:
        j = attrs.find("{", i)
        depth, k = 0, j
        while k < len(attrs):
            if attrs[k] == "{":
                depth += 1
            elif attrs[k] == "}":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        raw = attrs[j + 1:k].strip()
        if raw.startswith("{") and raw.endswith("}"):
            raw = raw[1:-1]
        style = parse_style(raw)
        attrs = attrs[:i] + attrs[k + 1:]
    rest = {}
    for m in re.finditer(r'(\w+)\s*=\s*"([^"]*)"', attrs):
        rest[m.group(1)] = m.group(2)
    return style, rest


def convert(markup: str, img_prefix: str) -> str:
    out, pos = [], 0
    stack = []
    for m in TAG_RE.finditer(markup):
        out.append(markup[pos:m.start()])
        pos = m.end()
        closing, name, attrs, selfclose = m.group(1), m.group(2), m.group(3), m.group(4)
        style, rest = split_attrs(attrs)

        if name == "br":
            out.append("<br>")
            continue

        if closing:
            out.append(f"</{ {'span': 'span'}.get(name, 'div') }>")
            if stack:
                stack.pop()
            continue

        if name in ("Slide", "Box", "Text", "span"):
            tag = "span" if name == "span" else "div"
            css = style
            if name in ("Slide", "Box"):
                pre = "display: flex; "
                # 源文件已写 flexDirection 就别再塞一个 row，避免重复声明
                if "flex-direction" not in css:
                    pre += "flex-direction: row; "
                css = (pre + css).strip("; ")
                if name == "Slide":
                    css += ("; width: 1280px; height: 720px; box-sizing: border-box;"
                            " position: relative; overflow: hidden")
            # ⚠ 自闭合标签（<Box style={{height:12}} />）必须自己闭合：
            #   否则后面的 </Box> 会弹错栈，整页 DOM 结构错位（页脚会跑到顶上去）。
            if selfclose:
                out.append(f'<{tag} style="{css}"></{tag}>')
            else:
                out.append(f'<{tag} style="{css}">')
                stack.append(tag)
        elif name == "Image":
            src = rest.get("src", "")
            if not src.startswith(("http", "data:")):
                src = img_prefix + src[len("assets/"):] if src.startswith("assets/") else img_prefix + src
            out.append(f'<img src="{src}" style="{style}">')
        else:
            out.append(markup[m.start():m.end()])
    out.append(markup[pos:])
    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(DECK, "_preview", "deck.html"))
    ap.add_argument("--scale", type=float, default=0.60)
    args = ap.parse_args()

    files = sorted(f for f in os.listdir(SLIDES) if f.endswith(".slide"))
    if not files:
        print(f"⚠ {SLIDES} 下没有 .slide")
        return 1

    outdir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(outdir, exist_ok=True)
    # 从输出目录回到项目根再进 assets/，图片才找得到
    img_prefix = os.path.relpath(os.path.join(DECK, "assets"), outdir).replace("\\", "/") + "/"

    W, H = int(1280 * args.scale), int(720 * args.scale)
    pages = []
    for f in files:
        with open(os.path.join(SLIDES, f), encoding="utf-8") as fh:
            markup = fh.read()
        body = convert(markup, img_prefix)
        pages.append(
            f'<section class="pg"><div class="cap">{f}</div>'
            f'<div class="vp" style="width:{W}px;height:{H}px">'
            f'<div style="width:1280px;height:720px;transform:scale({args.scale});'
            f'transform-origin:top left">{body}</div></div></section>'
        )

    html = f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>灯塔 · 作品介绍 分页预览</title>
<style>
  body {{ margin: 0; padding: 28px 24px 60px; background: #05090F; color: #E6EDF7;
         font-family: "Microsoft YaHei", "PingFang SC", sans-serif; }}
  h1 {{ font-size: 19px; font-weight: 600; margin: 0 0 4px; }}
  .hint {{ font-size: 13px; color: #7C8CA6; margin-bottom: 24px; }}
  .pg {{ margin: 0 auto 30px; width: {W}px; }}
  .cap {{ font-size: 12px; color: #6B7A93; margin-bottom: 6px; letter-spacing: .5px; }}
  .vp {{ overflow: hidden; border-radius: 8px; box-shadow: 0 10px 34px rgba(0,0,0,.55);
         border: 1px solid rgba(255,255,255,.09); background: #0A1120; }}
  img {{ display: block; }}
</style></head><body>
<h1>灯塔 Lighthouse · 作品介绍 — 分页预览（{len(files)} 页）</h1>
<div class="hint">这是按 .slide 源码 1:1 映射出的版式预览，用于快速核对排版；正式交付以 .pptx 为准。</div>
{''.join(pages)}
</body></html>
"""
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(html)
    print(f"✓ 已生成 {args.out}（{len(files)} 页，缩放 {args.scale}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
