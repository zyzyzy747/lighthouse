# -*- coding: utf-8 -*-
"""灯塔 · 端侧智能体验收（② 编排层）

验的是「闭环」，不是「界面好看」：

    一句话 → 规划（本地优先） → 调工具 → 汇总 → 回答 + 工具轨迹

三条最值钱的断言 —— 也是它跟普通聊天机器人的分界线：
  ① 答案里的每个事实都能在库里找到对应记录（出现具体公司名 + 工具读到的原始行）；
  ② 库里没有的东西必须**直说没有**，不许拿别的记录来凑；
  ③ 完全听不懂的话如实说没听懂，而不是编一句像样的回答。

⚠ 为什么用 `--ps lh_ask "问话"` 而不是在界面上打字：
  模拟器没有可靠的中文输入法（`uinput` 只能注坐标，输不了文字），脚本给不出任意问话，
  就只能点那四个预设 chip —— 而 ②③ 恰恰要靠「问一句库里没有的」「问一句驴唇不对马嘴的」
  才测得到。这条通道是专门为可验证性加的（和 lh_load_demo / lh_dnd 同一套惯例）。

⚠ 每个问题之间都 force-stop：
  对话是**累积**的，不重启的话上一题的答案还挂在屏幕上，
  「回答里不许出现别的公司」这类断言就会被上一题的内容污染。
  代价是每题多花 ~8 秒冷启动，换确定性，值。

⚠ 什么时候会假红：设备时钟落在免打扰窗口（22:00–08:00）时，哨兵那部分会静默 ——
  本脚本不碰哨兵，不受影响；但如果库里没数据（①失败），后面每条「库里有」都会红，
  所以 ① 挂了就直接退出，别往下跑。
"""
import os
import re
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_widget as vw  # noqa: E402
import verify_filter as vf  # noqa: E402

BUNDLE = "com.wuit.lighthouse"
HAP = (r"D:\work\DevEcoStudioProject\Lighthouse\entry\build\default"
       r"\outputs\default\entry-default-signed.hap")

# 演示数据里**最早到来的**那个节点（18 小时后，另外两个是 44 / 120 小时，间隔很大不会飘）
DEMO_NEXT = "精测电子"
# 库里其余的投递。问「腾讯」时这些**一个都不许出现** —— 出现了就说明拿别的记录硬凑了
OTHER_COMPANIES = ("光庭信息", "中望软件", "鼎捷软件", "用友网络", "金山办公",
                   "达梦数据库", "明源云")

# 不在预设 chip 里的一句问话，用来验"连问两次"
REPEAT_Q = "我投了哪几家公司？"


def hdc(*args):
    return subprocess.run([vw.HDC, *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace")


def app_logs(tail=400):
    return "\n".join(vw.logs("Lighthouse", tail=tail))


def screen(tag):
    return " ".join(vw.texts_of(vw.dump_layout(tag)))


def page_texts(rounds=3):
    """滚一遍助手页把文字全收下来。

    ⚠ **不去重**：⑧ 要数的就是"同一句话在屏幕上出现了几次"。
    ⚠ 收完必须滚回顶部，否则下一次 dump 停在半空，后面按文字找控件的步骤会找不到。
    """
    out = []
    for i in range(rounds):
        out.extend(vw.texts_of(vw.dump_layout(f"ag_s{i}")))
        vf.swipe_up()
    for _ in range(rounds + 1):
        vf.swipe_down()
    return out


def ask(question, cold=True, timeout=45):
    """把一句问话递给助手，等它答完。

    以 **hilog 的『Agent 回答完成 / Agent 没听懂』为准**，不靠 sleep 猜 ——
    本地规划 + 查库 + 渲染，快的时候 2 秒、慢的时候十几秒，写死 sleep 不是等太久就是假红。
    """
    if cold:
        vw.shell(f"aa force-stop {BUNDLE}")
        time.sleep(1.2)
    vw.clear_logs()
    vw.shell(f'aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1 --ps lh_ask "{question}"')
    deadline = time.time() + timeout
    while time.time() < deadline:
        t = app_logs()
        if "Agent 回答完成" in t or "Agent 没听懂" in t:
            vw.wait_ui_ready(30)
            time.sleep(2.5)          # 留给界面把回答卡片画出来
            return app_logs()
        time.sleep(1.5)
    return app_logs()


def leaked_other_companies(text):
    """回答里有没有出现别的公司 —— 用来抓"问 A 答 B"这种硬凑"""
    return [c for c in (DEMO_NEXT,) + OTHER_COMPANIES if c in text]


def main():
    print("=" * 62)
    print("端侧智能体验收：意图 → 规划 → 调工具 → 汇总")
    print("=" * 62)

    if not os.path.isfile(HAP):
        print(f"✗ 找不到产物 {HAP}，先跑 build.sh")
        return 2

    # ── ① 干净重装 + 载入演示数据
    print("\n-- ① 重装并载入演示数据 --")
    vw.shell(f"aa force-stop {BUNDLE}")
    time.sleep(1)
    hdc("uninstall", BUNDLE)
    time.sleep(2)
    hdc("install", HAP)
    time.sleep(2)
    vw.clear_logs()
    vw.shell(f"aa start -a EntryAbility -b {BUNDLE} --pi lh_autologin 1 --pi lh_load_demo 1")
    time.sleep(12)
    boot = app_logs()
    cloud_on = "cloudEnabled=true" in boot
    print(f"  云端兜底：{'可用' if cloud_on else '不可用（纯本地运转）'}")
    if not vw.check("演示数据已载入" in boot, "演示数据已载入",
                    f"演示数据没载进来 —— 后面所有「库里有」的断言都不作数，先修这个"):
        return 1

    # ── ② 助手是主界面之一
    print("\n-- ② 助手是一个主 Tab --")
    vw.wait_ui_ready()
    tapped = vw.tap_tab("助手")
    time.sleep(3)
    t = screen("ag_tab")
    vw.shot("ag_1_tab.jpeg")
    vw.check(tapped and ("可以这样问" in t or "Agent" in t),
             "底部有「助手」Tab，进去是提问界面",
             f"进不去助手页，当前屏：{t[:150]}")

    # 界面如实标注"会不会联网"：说出去的话必须和真实状态一致，
    # 否则就是"假装离线也智能"或者"明明能用却说不能"
    claim_off = "断网也能答" in t
    claim_on = "云端兜底已就绪" in t
    vw.check(claim_on == cloud_on and claim_off == (not cloud_on),
             f"界面对「会不会联网」的标注与真实状态一致（云端{'可用' if cloud_on else '不可用'}）",
             f"标注与真实状态不一致：界面 claim_on={claim_on} claim_off={claim_off}，实际 cloudEnabled={cloud_on}")

    # ── ③ 一句话进去，回答出来
    print("\n-- ③ 一句话进去，回答出来 --")
    log = ask("最近要准备什么？")
    t = " ".join(page_texts(3))
    vw.shot("ag_2_answer.jpeg")
    if not vw.check("Agent 回答完成" in log, "助手跑完了一条完整链路（日志有『Agent 回答完成』）",
                    f"没等到回答完成，日志尾部：{log[-200:]}"):
        return 1
    vw.check("本地规划" in t, "来源标注是「本地规划」—— 断网也能答",
             f"界面上没有来源标注，当前屏：{t[:200]}")
    vw.check("步" in t, "界面上有「N 步」的工具轨迹标记", "界面上没有工具轨迹标记")

    # ── ④ 答案引用的是库里的真实记录，不是模型生成的
    print("\n-- ④ 答案有据可查 --")
    vw.check("推算下一个节点" in t, "轨迹里点名了这次调用的工具（推算下一个节点）",
             "轨迹里看不到调用的工具名")
    vw.check(DEMO_NEXT in t, f"答案引用了库里的真实节点「{DEMO_NEXT}」",
             f"答案里没出现「{DEMO_NEXT}」—— 数据没读到或没渲染出来")
    vw.check("倒计时：" in t and "时间：" in t,
             "轨迹里带了工具读到的原始行（时间 / 倒计时），用户能自己核对",
             "只给了结论没给依据 —— 这一页的核心价值就是「每条结论都能核对」")

    # ── ⑤ 库里没有的，必须直说没有
    print("\n-- ⑤ 库里没有的，不许拿别的记录来凑 --")
    log = ask("腾讯的面试是什么时候？")
    t = " ".join(page_texts(3))
    vw.shot("ag_3_unknown.jpeg")
    vw.check("腾讯" in t, "回答里点出了用户问的公司名（听懂了问的是谁）",
             "回答里没提「腾讯」—— 公司名没被认出来，等于答非所问")
    vw.check(("没有" in t) or ("查不到" in t), "如实说了「没有」",
             "既没查到也没说没有 —— 这是最危险的情况：用户会以为真没有")
    leaked = leaked_other_companies(t)
    vw.check(len(leaked) == 0,
             "没有拿库里别的记录来凑（回答里没有出现任何其它公司）",
             f"问的是腾讯，回答里却出现了 {leaked} —— 答非所问，比编造还糟")

    # ── ⑥ 听不懂就直说听不懂
    print("\n-- ⑥ 听不懂别硬答 --")
    log = ask("帮我写一首关于秋天的诗")
    t = " ".join(page_texts(3))
    vw.shot("ag_4_nomatch.jpeg")
    vw.check("这句我还没学会怎么答" in t,
             "如实说「这句我还没学会怎么答」，并给出能问什么",
             f"没有如实说没听懂，当前屏：{t[:200]}")
    leaked = leaked_other_companies(t)
    vw.check(len(leaked) == 0, "没听懂时也没有编内容出来（回答里没有出现任何公司）",
             f"没听懂却答出了 {leaked} —— 说明它在硬凑")

    # ── ⑦ 一句话问两件事 → 得拆成多步
    print("\n-- ⑦ 一句话问两件事，要拆成多步 --")
    log = ask("我哪方面最弱？另外最近要准备什么？")
    t = " ".join(page_texts(4))
    vw.shot("ag_5_multi.jpeg")
    m = re.findall(r"steps=(\d+)", log)
    steps = int(m[-1]) if m else 0
    vw.check(steps >= 2, f"同一句话被拆成 {steps} 步工具调用",
             f"只规划出 {steps} 步 —— 用户的后半句被丢了，而那往往才是他真正在意的")
    vw.check("能力" in t and DEMO_NEXT in t,
             "两件事在回答里都有（能力现状 + 最近的节点）",
             f"两个话题没都答上，当前屏：{t[:200]}")

    # ── ⑧ 同一句话连问两次，第二次也要接得住
    print("\n-- ⑧ 连问两次同一句，第二次也要接住 --")
    ask(REPEAT_Q, cold=True)
    ask(REPEAT_Q, cold=False)      # 应用已经在跑 → 走 onNewWant 那条路
    time.sleep(2)
    texts = page_texts(5)
    n = sum(1 for s in texts if s.strip() == REPEAT_Q)
    vw.shot("ag_6_repeat.jpeg")
    vw.check(n >= 2, f"同一句话问了两遍，界面上两条提问都在（数到 {n} 条）",
             f"第二次提问没进界面（只数到 {n} 条）—— 热启动那条路断了，"
             f"而真实用户绝大多数点击都是热启动")

    # ── ⑨ 收尾：界面还活着
    print("\n-- ⑨ 收尾 --")
    t = screen("ag_final")
    vw.check("助手" in t, "跑完全部用例后界面仍然正常",
             f"界面异常，当前屏：{t[:150]}")

    ok = sum(1 for r in vw.RESULTS if r)
    bad = len(vw.RESULTS) - ok
    print(f"\n{'=' * 46}\n结果：通过 {ok} / {len(vw.RESULTS)}，失败 {bad}\n{'=' * 46}")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
