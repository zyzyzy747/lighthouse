# 灯塔 Lighthouse · 秋招数据作战台

> 光谷杯（赛道一）参赛作品 ｜ HarmonyOS 原生应用（ArkTS / ArkUI）
> 把秋招的「投递 — 记录 — 复盘」串成一条流水线，再用鸿蒙独有的多设备形态把它推到桌面。

**应用名**：灯塔 ｜ **包名**：`com.wuit.lighthouse`
**设备形态**：手机 · 平板 · 2in1 ｜ **最低可安装版本**：HarmonyOS 6.1.1（API 24）

---

## 这是什么

秋招是一段高频、多线、极易失忆的时间：投了哪些公司、哪家约了二面、哪个 offer 要在这周五前回复——散落在聊天记录、备忘录和脑子里。「灯塔」把这些收拢成一个**作战台**：

- **桌面就能看**：服务卡片常驻桌面，显示关键节点与实时倒计时，不用打开应用就知道「接下来该做什么」
- **到点会提醒**：节奏哨兵盯着每个节点的截止时间，临界时推通知
- **说一句就记下**：备注区支持端侧离线语音速记，路上想到什么直接说
- **问一句就答**：「助手」用本地数据回答「腾讯的面试是什么时候」这类问题，答案可追溯到具体记录
- **公司在哪看得见**：求职地图按城市汇总投递分布，真地图 + 标记点

## 功能模块

| 模块 | 说明 |
|---|---|
| **快记 QuickRecord** | 记录投递 / 笔面 / 关键节点；城市联想、跨年日期（12 月 → 次年 1 月）边界处理 |
| **地图 Map** | Map Kit 真地图 + 标记，按城市汇总投递分布；无网时降级为文字清单 |
| **复盘 Review** | 面试复盘与阶段回顾；列表筛选 + 「下一个节点」直达 |
| **助手 Assistant** | 端侧智能体编排：一句话 → 拆成工具调用 → 用本地数据合成答案，**答案下方显示工具轨迹** |
| **我的 Profile** | 本地档案、头像、投递漏斗、最近要跑、设置入口 |
| **设置 Settings** | 外观三档（跟随系统 / 浅色 / 深色）、AI 引擎、节奏哨兵、桌面卡片、演示数据 |
| **本地档案（登录 / 解锁）** | PBKDF2 本地口令；锁定时**桌面卡片脱敏**（只藏公司名，时间 / 类型 / 数量照常显示） |
| **桌面服务卡片** | 主入口：关键节点 + 倒计时，点击直达对应页面 |
| **节奏哨兵 Sentinel** | 到点提醒与临界预警；状态落库，重启不丢 |

## 鸿蒙特性落地

| 能力 | 怎么用的 |
|---|---|
| **一多（多设备形态）** | `sm / md / lg` 三档断点：手机竖屏底部四栏 → 折叠屏展开左侧栏 → 手机横屏 / 平板左侧栏 + 内容双栏。断点判定统一收口在 `common/Layout`，页面只订阅结果 |
| **折叠屏悬停** | 半折叠时上半区显示「作战简报」，下半区正常浏览 |
| **服务卡片（Form Kit）** | 卡片是**独立进程**：UI 不能 import 应用代码，卡片自己初始化 RDB；应用侧写库后统一经 `formProvider.reloadForms` 刷新 |
| **端侧离线语音** | Core Speech Kit 中文离线识别，识别结果换行追加进备注；热词表内置秋招词 + 用户库中的公司名 |
| **端云双模 AI** | L1 端侧能力 + 本地规则（永远可用）／ L2 云端大模型 ／ L3 自动降级，**界面必须标注结果来源** |
| **Map Kit（真地图）** | `MapComponent` + `addMarker`；公司名 → 坐标走**三级降级**：地点搜索 → 内置园区种子库 → 城市中心 |
| **深浅色主题** | 12 个 UI 色全部资源化（`color.json` 浅色 / `dark/color.json` 深色），`Palette` 改持 `Resource`，**页面调用点一字未改** |

### ★ 端侧智能体的设计支点

**云端只负责「听懂问题」（挑工具），答案 100% 由本地数据合成。**

`AgentTools` 提供六只「手」（apps_query / events_query / next_node / review_summary / jd_match / countdown），
`AgentPlanner` 先用本地关键词打分表规划，只有本地零命中时才让云端兜底。
模型的唯一权限是**选工具**，选错也只是无效一笔（有白名单）。代价是话说得朴素——
但「你明天几点面试」这种产品，**宁可朴素地说实话，也不能编**。

## 安全与密钥

- 仓库内**不含任何真实 API Key**：内置演示密钥走 `tools/inject_key.py` 注入到 `entry/src/main/ets/common/AiSecret.ets`，**交付前用 `--strip` 抹除**（仓库里的版本即为抹除后的空串）
- 应用支持 **BYOK**（用户自带密钥），正式使用不依赖内置 key
- 之所以把密钥单独拆成一个文件：它是唯一需要「随时能抹掉」的东西，抹除时不会顺手改坏端点、模型名等常量
- **本地档案不联网**：口令用 PBKDF2\|SHA256（16B 盐 / 32B 派生值 / 12000 轮）存本地 RDB，登录的动机是**隐私**（公司名 / 薪资 / 面试评价）而非账号体系。验收里有「日志中搜不到密码原文」这条断言

## 技术栈

`ArkTS` / `ArkUI` ｜ `RDB`（关系型数据库）+ `KV`（偏好设置）｜ `Form Kit`（服务卡片）｜
`Core Speech Kit`（端侧语音）｜ `Map Kit`（真地图）｜ `NetworkKit`（云端大模型调用）｜
`CryptoArchitectureKit`（口令派生）｜ `hvigor` 命令行构建

## 目录结构

```
.
├── AppScope/                 # 应用级配置与资源（应用名、图标、启动图）
├── entry/                    # 主模块
│   └── src/main/ets/
│       ├── common/           # 主题 / 布局断点 / 导航 / 日志 / 类型
│       ├── model/            # RDB 封装（DbHelper）
│       ├── repository/       # 各表仓储层
│       ├── service/          # 哨兵、语音、AI 客户端、智能体（AgentTools/Planner/Lighthouse）、
│       │                     # 口令（Auth）、头像（AvatarStore）、外观（Appearance）、地名解析
│       ├── view/             # 快记 / 地图 / 复盘 / 助手 / 我的 / 设置 / 登录
│       └── widget/           # 服务卡片页面
├── docs/                     # 产品设计文档、AI 接入说明、建工程须知、参赛设计稿
├── tools/                    # 命令行构建脚本 + 17 个无头验证脚本 + 批量回归 + 演示视频工具
├── build-profile.json5       # SDK 版本与签名配置
└── hvigorfile.ts
```

## 构建与运行

**环境**：DevEco Studio 26.0.0.821 ｜ 工程用内置 HarmonyOS SDK `26.0.0.105`

```json5
// build-profile.json5 关键两行
compatibleSdkVersion: "6.1.1(24)"   // 最低可安装设备版本（不是开发 SDK）
targetSdkVersion: "26.0.0"
```

> ⚠️ 这两行是能不能装上的关键：`compatibleSdkVersion` 只是「允许哪些设备安装」的声明，
> 编译实际用 IDE 内置的 26 SDK。填 26 会导致评委设备装不上；填 6.1.1(24) 覆盖在用设备且开发体验无损。

**命令行编译**（不用开 IDE）：

```bash
bash tools/build.sh          # 或 cmd 下 tools\build.bat
                             # 末尾会打印 == BUILD OK / == BUILD FAILED
```

脚本要点：`DEVECO_SDK_HOME` 必须指向 **DevEco 内置 SDK**（`D:\DevEco Studio\sdk`），
指向 OpenHarmony 目录会报 `00303312`。

**安装**：`signingConfigs` 为空时产物是 `-unsigned`，**装不上任何设备**，需在 IDE 里配置自动签名。

**Map Kit 权益**：`MapComponent` 缺权益会直接白屏，需在 DevEco 的
`项目结构 → Signing Configs → Enable open capabilities` 勾选 Map Kit 并**重签**。
签名 profile 里的真实字段是全小写的 `com.huawei.service.mapkit`（搜 `MapKit` 搜不到）。
API 24 起**无需** `client_id` / `agconnect-services.json`。

## 无头验证（17 个脚本，15 套进批量回归）

没有真机、只有模拟器，所以做了一套无人值守验收：脚本把应用装进模拟器，
用 `uitest dumpLayout` 读控件树、查 RDB 落库结果、验通知与卡片数据刷新——**不看界面也能判功能对错**。

```bash
python tools/_regress_all.py        # 一条命令跑完 15 套并汇总（约 36 分钟）
```

| 脚本 | 覆盖 | 断言 |
|---|---|---|
| `verify_widget.py` | 桌面服务卡片（主入口） | 23 |
| `verify_notify.py` | 节奏哨兵（到点提醒） | 33 |
| `verify_multidevice.py` | 一多形态 + 图标 / 启动页 | 30 |
| `verify_layout.py` | 「我的 / 助手」版式与留白 | 40 |
| `verify_login.py` | 本地档案（登录 / 解锁 / 卡片脱敏） | 28 |
| `verify_agent.py` | 端侧智能体编排 | 18 |
| `verify_theme.py` | 深浅色主题（按截图像素判定） | 11 |
| `verify_jd.py` | JD 岗位匹配分析（端云双模 + 落库） | 11 |
| `verify_filter.py` | 列表筛选 + 「下一个节点」 | 10 |
| `verify_voice_ui.py` | 语音速记界面接线 | 10 |
| `verify_avatar.py` | 头像更换（含冷启动后仍生效） | 9 |
| `verify_voice.py` | 语音识别引擎（喂固定音频） | 8 |
| `verify_map.py` | 真地图落点 + 城市筛选 | 14 |
| `verify_ai.py` / `verify_write.py` / `verify_quickrecord.py` | AI 客户端 / 写库 / 快记页 | 13 / 见脚本 / 6 |
| `verify_voice_live.py` | 真机实时语音（不在批量内） | 见脚本 |

**最近一次全量回归（2026-09-23）：15 套全绿，264 条断言，36m34s。**

语音验证怎么做无人值守：识别引擎**不自己录音**，音频靠 `writeAudio()` 喂进去 ——
所以用 TTS 合成一段固定台词（`tools/make_voice_clip.py` → `rawfile/voice_clip.pcm`）当麦克风数据灌进去，
整条链路可自动回归。

**地图怎么判「画出来没有」**：`MapComponent` 不出现在 `dumpLayout` 里，也不能硬编码区域。
改成找特征——逐 40px 横带扫，取「颜色最丰富」的那段连续区域，并要求它与「求职地图」标题推算的位置重叠。
真地图唯一色约 6 万、std 52.9；应用自己的纯色面板只有 4~7 个唯一色，差三个数量级。

### 自检开关（不是绕过功能）

脚本不改产品逻辑，只用**启动参数**走真实链路：

| 开关 | 作用 |
|---|---|
| `--pi lh_load_demo 1` | 冷启动载入演示数据（按钮搬进设置页后点不到） |
| `--pi lh_dnd 0` | 关免打扰（断言不该被设备时钟的静默窗口影响） |
| `--pi lh_autologin 1` | 走真实 `createAccount` / `login`，**不是跳过登录门** |
| `--ps lh_avatar demo\|reset` | 换 / 重置头像（模拟器相册无法编程入库） |
| `--ps lh_ask "问话"` | 向助手提问 |

> 设计原则：**门要么真的过，要么别测**。绕过登录门意味着覆盖率 0%，永远测不出门接错了。

### 诚实记账

- 批量回归中 `voice` / `login` / `filter` 三套出现过**假红**，同样 hap 同样脚本单跑即全绿
  ⇒ 判为连续跑的负载 / 顺序抖动，不是代码缺陷。**不用调大超时治假红**，要换机制。
- 登录流程里那段「冷启动硬恢复」属**预防性加固**，尚未在真实卡死场景复现验证过。

## 工程经验（踩过的坑，都写进了代码注释）

1. **服务卡片是独立进程**：卡片的 UI 不能 import 应用代码，RDB 也得在卡片进程里自己初始化；
   应用侧写完库必须主动 `reloadForms`，否则桌面永远显示旧数据
2. **锁只拦界面，不拦数据层**：卡片进程走 `EntryFormAbility → WidgetData → EventRepo`，完全不经过 UI。
   门加在数据层会导致锁定态下卡片直接坏掉，而验收脚本全在解锁态跑，**这个 bug 永远不会被发现**
3. **`@Watch` 只在值变化时触发**：同一句话连问两次，界面纹丝不动。要发「序号」而不是「文本」；
   且冷启动带参时信号早于界面创建，`aboutToAppear` 里必须手工补消费一次
4. **`Resource` 不能做字符串拼接**：`tint()` 那类 `#${aa}${hex}` 写法对资源色失效 ⇒ 新增 `Tint` 类 + 6 个 `lh_tint_*` 资源
5. **端侧 ASR 引擎是系统级单例**，会被输入法占用；错误码只给一句 `Create engine failed`，
   真正原因在 `message` 里 ⇒ 加了短重试 + 「被占用」的友好提示，而不是误导用户「去下载语音模型」
6. **`hdc file recv` 拉失败时退出码仍是 0**，且 `dumpLayout` 只给**当前前台窗口**的树
   ⇒ 找控件的逻辑没错，错的是它看的那份数据。先删设备端文件再认 `[Fail]`
7. **两个构建同时写同一个 `build/` 会打出坏 hap**（`9568337 install parse unexpected`）。
   30 秒定位法：读 hap 尾部 `PK\x05\x06`，尾部多余字节 > 0 即 zip 被写坏
8. **编译成败别用管道判断**：`build.sh | tail && verify.py` 里 `&&` 拿到的是 `tail` 的退出码，
   编译失败也会继续跑验收、装的还是旧包 ⇒ 现在脚本显式打印 `== BUILD OK / == BUILD FAILED`
9. **`INSERT` 覆盖时间戳会让时间类查询永远查空**：`toBucket()` 把 `updated_at` 硬写成 `now`
   ⇒ 「投出去 7 天没动静」这类卡永远不出现。修法是 INSERT 尊重调用方时间，只有 UPDATE 才盖 `now`
10. **`ForEach` 的 key 必须带值**：`fs-${label}` 在数据到位后不重建，画面停在首帧的 0，
    而同卡内非 ForEach 的文字正常更新——标签断言全绿但画面自相矛盾
11. **`Scroll` 内容不足一屏时默认垂直居中** ⇒ 上下留白近似相等（实测 350 / 351px），
    修法是 `align(Alignment.Top)`。⚠ 别用 `dumpLayout` 的 bounds 判溢出——超出视口会被截到视口下沿
12. **跨「后台执行 / 前台展示」的状态必须落库**，不能只靠某次调用返回值

---

## 说明

参赛作品源码，供评审与学习参考。

| 文档 | 内容 |
|---|---|
| `docs/design-doc.html` | 产品设计文档（含演示视频分镜） |
| `docs/ai-integration.html` | AI 接入设计（端云双模 + 智能体） |
| `docs/DESIGN.md` / `docs/STORY.md` | 参赛设计说明 / 作品叙事稿 |
| `docs/地图能力审计.md` | Map Kit 权益阻塞的排查与解除记录 |
| `docs/SETUP.md` | 建工程与环境清单 |
