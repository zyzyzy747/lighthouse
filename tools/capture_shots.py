"""为参赛材料（PPT / 演示视频）抓一套干净的实机截图。

为什么单独写一个脚本，而不是复用验收脚本的截图：
  · 验收脚本的截图是**给断言用的** —— 当时屏幕上恰好是什么就存什么，
    经常带着滚动残留、弹窗、或者浅色主题。
  · 参赛材料要的是**统一取景、统一主题、同一批演示数据**的一套图。
  两者目的不同，混用会让 PPT 里出现风格不一致的截图。

⚠ 上机顺序有讲究：
  ① 先切深色主题 —— 换主题会重建界面，后面所有截图必须是同一套配色；
  ② 竖屏抓四页 → ③ 横屏抓双栏 → ④ 折叠悬停 → ⑤ 回竖屏再抓桌面卡片。
  顺序颠倒（比如先抓桌面再转屏）会得到一批前后主题/朝向混杂的图。

产物落在 _shots/pres_*.jpeg，再按用途裁到 assets/ 下。
"""
import os
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import verify_widget as vw
import verify_multidevice as vm

B = vw.BUNDLE
ASSETS = r"D:\work\workbuddy\lighthouse-guanggu\submit\灯塔作品介绍\assets"


def step(msg):
    print(f"\n=== {msg}")


def boot():
    step("冷启动 + 自检自动登录 + 演示数据")
    vw.shell(f"aa force-stop {B}")
    time.sleep(2)
    vw.clear_logs()
    vw.shell(f"aa start -a EntryAbility -b {B} --pi lh_autologin 1 --pi lh_load_demo 1 --pi lh_dnd 0")
    time.sleep(10)
    ok = vm.app_ready()
    print("    界面就绪:", ok)
    return ok


def go_dark():
    """切到深色主题 —— PPT 与视频都是深海色，截图必须同色才像同一件东西。"""
    step("切深色主题")
    vw.tap_tab("我的", wait=2.5)
    time.sleep(2)
    if not vw.tap_text_with_scroll("设置", exact=True, rounds=3, tries=4):
        print("    ⚠ 进不去设置页")
        return False
    time.sleep(3)
    if not vw.tap_text_with_scroll("深色", exact=True, rounds=3, tries=4):
        print("    ⚠ 找不到「深色」选项")
        return False
    time.sleep(4)
    vw.shot("pres_settings_dark.jpeg")
    if not vw.tap_text_with_scroll("‹", exact=True, rounds=2, tries=3):
        print("    ⚠ 退不回主壳")
        return False
    time.sleep(3)
    return True


def shoot_portrait():
    step("竖屏四页 + 我的")
    for tab, name in (("快记", "quick"), ("地图", "map"), ("复盘", "review"),
                      ("助手", "agent"), ("我的", "profile")):
        if not vw.tap_tab(tab, wait=2.5):
            print(f"    ⚠ 点不到「{tab}」")
            continue
        time.sleep(3)
        vw.shot(f"pres_phone_{name}.jpeg")
        print(f"    已抓 竖屏/{tab}")


def gen_radar():
    """复盘页**现场生成**能力雷达 —— 演示数据故意留空 radarJson（见 DemoData 注释：
    「演示时要现场点『生成能力雷达』」）。生成后落库，横屏右栏会直接把它展示出来，
    所以这一步既拿到竖屏雷达图，也顺便让横屏那张有内容。"""
    step("复盘 · 现场生成能力雷达")
    if not vw.tap_tab("复盘", wait=3):
        print("    ⚠ 点不到「复盘」")
        return False
    time.sleep(3)

    lay = vw.dump_layout("cap_review")
    hit, label = None, None
    for cand in ("生成能力雷达", "查看能力雷达"):
        h = vw.find_text_node(lay, cand, exact=True)
        if h:
            hit, label = h, cand
            break
    if not hit:
        print("    ⚠ 找不到雷达入口（tools/_shots/cap_review.jpeg 可查）")
        return False

    print(f"    入口：{label} @ ({hit[0]}, {hit[1]})")
    if label == "生成能力雷达":
        vw.tap(hit[0], hit[1], wait=2)
        # 云端熔断 12s / 本地引擎瞬时 —— 等足再判定，别抢在渲染前截图
        time.sleep(16)
    else:
        print("    已有雷达，跳过生成")

    # 雷达内联展开在卡片下半部分，往下滚一点让它进画面中央
    vw.scroll_content(px=int(vw.window_size()[1] * 0.26))
    time.sleep(2.5)
    vw.shot("pres_phone_radar.jpeg")
    print("    已抓 竖屏/雷达")
    return True


def shoot_landscape():
    step("横屏双栏")
    if not vm.rotate_until(lambda: vm.is_landscape() and vm.tabs_on_left(), "横屏侧栏"):
        print("    ⚠ 转不到横屏")
        return
    for tab, name in (("地图", "map"), ("快记", "quick"), ("复盘", "review")):
        if not vw.tap_tab(tab, wait=2.5):
            continue
        time.sleep(3.5)
        vw.shot(f"pres_pad_{name}.jpeg")
        print(f"    已抓 横屏/{tab}")


def shoot_folded():
    step("折叠屏悬停")
    if not vm.rotate_until(lambda: not vm.is_landscape(), "竖屏", max_tries=3):
        print("    ⚠ 回不到竖屏")
    # 悬停预览自检开关：非折叠设备也能真的启用悬停布局（verify_multidevice 同款做法）
    vw.shell(f"aa force-stop {B}")
    time.sleep(2)
    vw.shell(f"aa start -a EntryAbility -b {B} --pi lh_autologin 1 --pi lh_load_demo 1 --ps lh_hover_preview true")
    time.sleep(9)
    vw.shot("pres_fold_hover.jpeg")
    print("    已抓 折叠悬停")


def shoot_desktop():
    step("回竖屏 + 桌面卡片")
    vw.shell(f"aa start -a EntryAbility -b {B} --pi lh_autologin 1")
    time.sleep(5)
    vm.rotate_until(lambda: not vm.is_landscape(), "竖屏", max_tries=4)
    vw.shell(f"aa force-stop {B}")
    time.sleep(2)
    lay, form = vw.goto_card_page()
    vw.shot("pres_desktop_card.jpeg")
    print("    卡片 bounds:", form)


def main():
    if not boot():
        return 1
    if not go_dark():
        print("⚠ 没切成深色，后面的图会和 PPT 配色不一致")
    shoot_portrait()
    gen_radar()          # 生成后落库 → 横屏右栏那张就有雷达了
    shoot_landscape()
    shoot_folded()
    shoot_desktop()
    step("完成")
    print("原始图在 tools/_shots/pres_*.jpeg")
    return 0


if __name__ == "__main__":
    sys.exit(main())
