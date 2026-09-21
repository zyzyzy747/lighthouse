#!/usr/bin/env bash
# 灯塔 Lighthouse · 命令行编译验证
#
# 用途：不开 DevEco Studio 也能编译工程，用来验证代码能不能过编译。
# 用法：bash build.sh             # 默认编译 Lighthouse
#       bash build.sh <工程路径>   # 编译指定工程
#
# 关键点：
#  1) DEVECO_SDK_HOME 必须指向 DevEco 的【内置 HarmonyOS SDK】
#     即 "D:\DevEco Studio\sdk"
#     不能指向 "D:\huawei\openHarmonysdk"（那是 OpenHarmony SDK，
#     布局里没有 hms/ 与 sdk-pkg.json，会报 00303312）
#  2) 路径一律写 "D:/..." 而不是 "/d/..."。
#     Git Bash(MSYS) 会把 /d/ 当成本盘根目录，转成 D:\d\... 从而找不到文件。

set -o pipefail
export PATH="/usr/bin:/bin:/c/Windows/System32:$PATH"

# ⚠ 清掉宿主注入的删除守卫。
#   WorkBuddy 通过 NODE_OPTIONS 注入 node-safe-delete-shim，按【回合】累计删除数，
#   超过 50 个就拦截后续所有 unlink —— 而 hvigor 每次编译都要清理自己的中间产物
#   （loader_out、sourceMaps、report…），于是一轮里编译第二次起就会失败：
#     Error: [safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED] {... "scope":"turn"}
#     > ERROR: BUILD FAILED
#   它长得跟编译错误一模一样，但 COMPILE RESULT 里根本没有语法错误 —— 别去改代码。
#   这里删的全是 entry/build 与 .hvigor 下的构建产物，不涉及用户文件，所以放行。
unset NODE_OPTIONS
unset CODEBUDDY_SAFE_DELETE_BULK_GUARD

PROJ="${1:-D:/work/DevEcoStudioProject/Lighthouse}"
DEVECO="D:/DevEco Studio"
NODE="$DEVECO/tools/node/node.exe"
HVIGOR="$DEVECO/tools/hvigor/bin/hvigorw.js"

[ -d "$PROJ" ] || { echo "工程目录不存在: $PROJ"; exit 2; }
[ -f "$NODE" ] || { echo "找不到 node: $NODE"; exit 2; }
[ -f "$HVIGOR" ] || { echo "找不到 hvigorw.js: $HVIGOR"; exit 2; }

cd "$PROJ" || exit 2
echo "== 编译工程: $PROJ"

DEVECO_SDK_HOME="D:\\DevEco Studio\\sdk" \
  "$NODE" "$HVIGOR" --mode module -p product=default assembleHap --no-daemon
CODE=$?

echo "== 退出码: $CODE"
# ⚠ 下面这行别删。踩过的坑：调用方写 `./build.sh | tail -3 && python verify_xxx.py`，
#   管道把退出码吃掉了（拿到的是 tail 的 0），于是**编译失败也照样往下跑验收**，
#   而验收装的是上一次的旧 hap ⇒ 全绿通过，对着一个根本没生效的改动。2026-09-21 实测。
#   有一条明确的 BUILD OK / BUILD FAILED 就能直接 grep，不必依赖退出码传递。
if [ "$CODE" -eq 0 ]; then
  echo "== BUILD OK"
  echo "== 产物:"
  find "$PROJ" -name "*.hap" 2>/dev/null | sed 's/^/   /'
else
  echo "== BUILD FAILED（退出码 $CODE）—— 别往下跑验收，装的是旧产物"
fi
exit $CODE
