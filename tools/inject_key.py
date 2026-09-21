#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
灯塔 Lighthouse · DeepSeek 密钥注入

为什么不把 key 直接写在代码里？
  hap 包内的 ArkTS 字节码可被反编译，硬编码密钥一定会泄露。
  所以密钥单独放一个可随时抹掉的文件（AiSecret.ets），由本脚本读写。

用法：
  # 1. 把你的 key 写进 secrets/deepseek.key（一行，无需引号）
  # 2. 注入到工程
  python inject_key.py
  # 3. 交稿 / 上传仓库前抹掉
  python inject_key.py --strip

  # 也可以直接传 key（会顺手写入 secrets 文件）
  python inject_key.py --key sk-xxxxxxxx

检查当前状态：
  python inject_key.py --status
"""

import argparse
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                                   # lighthouse-guanggu/
KEY_FILE = os.path.join(ROOT, "secrets", "deepseek.key")

# 工程位置可用环境变量覆盖，默认按本机实际路径
PROJECT = os.environ.get("LIGHTHOUSE_PROJECT", r"D:\work\DevEcoStudioProject\Lighthouse")
TARGET = os.path.join(PROJECT, "entry", "src", "main", "ets", "common", "AiSecret.ets")

HEADER = """/**
 * 灯塔 Lighthouse · 内置演示密钥
 * ------------------------------------------------------------------
 * ⚠ 本文件由 tools/inject_key.py 生成/覆盖，**不要手工提交真实密钥**。
 *   - 写入：python inject_key.py            （读 secrets/deepseek.key）
 *   - 抹除：python inject_key.py --strip    （交稿前跑，key 变回空串）
 *
 * 为什么单独拆一个文件：密钥是唯一需要"能随时抹掉"的东西。
 * 把它从 AiTypes.ets 里剥出来，交稿前只动这一个文件，
 * 就不会顺手改坏别的常量（端点、超时、模型名）。
 *
 * ⚠ 安全底线：hap 包内字节码可被反编译，硬编码密钥**一定会泄露**。
 *   所以这里只放一个"单独申请、只充少量余额、设了消费限额"的演示 key，
 *   绝不能放主账号 key。正式口径是 BYOK（用户自带密钥），见设置页。
 */
export const BUILTIN_DEMO_KEY: string = '{value}';
"""


def mask(key: str) -> str:
    if not key:
        return "(空)"
    if len(key) <= 10:
        return key[:3] + "***"
    return key[:6] + "..." + key[-4:]


def read_current() -> str:
    """读回工程里当前生效的 key，用于 --status 和 --strip 校验"""
    if not os.path.isfile(TARGET):
        return ""
    with open(TARGET, "r", encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"BUILTIN_DEMO_KEY:\s*string\s*=\s*'([^']*)'", text)
    return m.group(1) if m else ""


def read_key_file() -> str:
    if not os.path.isfile(KEY_FILE):
        return ""
    with open(KEY_FILE, "r", encoding="utf-8") as f:
        return f.read().strip()


def write_target(value: str) -> None:
    if not os.path.isdir(os.path.dirname(TARGET)):
        print(f"✗ 找不到工程目录：{os.path.dirname(TARGET)}")
        print("  用环境变量指定：set LIGHTHOUSE_PROJECT=D:\\path\\to\\Lighthouse")
        sys.exit(1)
    with open(TARGET, "w", encoding="utf-8", newline="\n") as f:
        f.write(HEADER.replace("{value}", value))
    print(f"✓ 已写入 {TARGET}")
    print(f"  内置演示密钥 = {mask(value)}")


def main() -> None:
    ap = argparse.ArgumentParser(description="灯塔 Lighthouse 密钥注入")
    ap.add_argument("--key", help="直接提供 key（会同时写入 secrets/deepseek.key）")
    ap.add_argument("--strip", action="store_true", help="抹除工程内的 key（交稿前必跑）")
    ap.add_argument("--status", action="store_true", help="只看当前状态，不改文件")
    args = ap.parse_args()

    current = read_current()

    if args.status:
        print(f"工程内当前 key : {mask(current)}")
        print(f"secrets 文件   : {KEY_FILE}")
        print(f"  └ 存在       : {'是' if os.path.isfile(KEY_FILE) else '否'}")
        print(f"  └ 内容       : {mask(read_key_file())}")
        print(f"目标文件       : {TARGET}")
        if not current:
            print("\n提示：当前没有内置 key，应用会走本地引擎。")
            print("      要启用云端 AI，先写 secrets/deepseek.key 再跑 inject_key.py")
        return

    if args.strip:
        write_target("")
        print("\n已抹除。此版本的 hap 不含任何密钥，启动后会走本地引擎或提示用户填 key。")
        return

    key = (args.key or "").strip()

    if not key:
        key = read_key_file()

    if not key:
        print(f"✗ 没找到密钥。请把 key 写进：\n  {KEY_FILE}\n")
        print("  内容格式：一行，只有 key 本身，不要引号、不要换行、不要 'Bearer' 前缀")
        print("  也可以直接：python inject_key.py --key sk-xxxxxxxx")
        sys.exit(1)

    # 清理常见粘贴事故：带引号、带 Bearer、带空格、带换行
    key = key.strip().strip('"').strip("'").strip()
    if key.lower().startswith("bearer "):
        key = key[7:].strip()

    if not key.startswith("sk-"):
        print(f"⚠ 这个 key 不以 'sk-' 开头（实际开头：{key[:6]}），DeepSeek 的 key 通常形如 sk-xxxx")
        print("  如果确认无误可以忽略这条警告。")
    if "\n" in key or " " in key:
        print("✗ key 里有换行或空格，说明复制时带进了多余内容。请只保留一行。")
        sys.exit(1)

    # 顺手回写 secrets 文件，保证两边一致
    os.makedirs(os.path.dirname(KEY_FILE), exist_ok=True)
    with open(KEY_FILE, "w", encoding="utf-8", newline="\n") as f:
        f.write(key + "\n")

    write_target(key)
    print(f"  同时保存到 {KEY_FILE}（下次不用重输）")


if __name__ == "__main__":
    main()
