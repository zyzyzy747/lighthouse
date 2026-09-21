# 灯塔 Lighthouse · 建工程须知

> 2026-09-18 实地验证版 ｜ 结论全部来自本机实测与华为官方文档，不是推断

---

## 零、先回答你的两个问题

**「没有 24 的 SDK」→ 对，而且不需要有。**
**「也没提示下载」→ 对，因为根本不用下。**

我用命令行真跑了一次编译，`compatibleSdkVersion: "6.1.1(24)"` + `targetSdkVersion: "26.0.0"`，结果是：

```
> hvigor BUILD SUCCESSFUL in 26 s 903 ms
33 tasks in total: 33 executed, 0 up-to-date
```

产物 `entry-default-unsigned.hap`（119 KB）里解出来是这样的：

| hap 内字段 | 值 | 解读 |
|---|---|---|
| `minAPIVersion` | `60101024` | **6.1.1 + API 24** ← 你要的 24 在这里 |
| `targetAPIVersion` | `260000026` | 26.0.0 + API 26 |
| `compileSdkVersion` | `26.0.0.105` | 实际编译用的是内置 26 SDK |

**所以：你选的 6.1.1(24) 已经生效了，它写进了 hap 的"最低可安装版本"，而这台机器上确实一套 24 的 SDK 都没装 —— 因为它压根不需要。**

---

## 一、为什么不需要下 24 的 SDK（这是最容易误解的一层）

三个版本字段是**解耦**的：

```
compatibleSdkVersion  <=  targetSdkVersion  <=  compileSdkVersion
   最低能装什么设备        目标版本            实际拿什么编译
```

- **`compileSdkVersion`** 才决定"用哪个 SDK 编译"。官方规定它只能等于**当前 DevEco 配套的 SDK**，你改不了 → 本机固定 `26.0.0.105`。
- **`compatibleSdkVersion`** 只是一行**声明**："低于这个版本的设备不许装"。hvigor 拿它去生成 `minAPIVersion` 字段，**过程中不需要那个版本的 SDK 存在**。

一句话：**选 6.1.1(24) ≠ 要装 24 的 SDK。它只是把"谁能装"这扇门开大。**

---

## 二、你截图里那个页面是「OpenHarmony SDK」，不是「HarmonyOS SDK」

这是关键误会点。DevEco 里有两套 SDK：

| | HarmonyOS SDK | OpenHarmony SDK |
|---|---|---|
| 位置 | **内置**，`D:\DevEco Studio\sdk\default` | 单独下载，`D:\huawei\openHarmonysdk` |
| 版本 | `26.0.0.105`（Release） | 只有 `26.0.0` 一版，其余未装 |
| 谁在用 | **你的工程用这个**（`runtimeOS: "HarmonyOS"`） | 只有 `runtimeOS: "OpenHarmony"` 的工程才用 |
| 能选多版本吗 | ❌ 一套，跟着 IDE 走 | ✅ 可下多版（就是你截图里那些 API 23/20/18） |

你截图里那些 `API Version 23 / 6.1.0.32`、`API Version 20 / 6.0.0.47` 全是 **OpenHarmony 的包**，跟你的工程没有半点关系。**别去下，下了也用不上。**

（顺带说明：OpenHarmony 的 API 编号和 HarmonyOS 的不在一条线上。模拟器镜像自己的 `sdk-pkg.json` 写得很清楚 —— `apiVersion: "24"`, `platformVersion: "6.1.1"`。所以 **HarmonyOS 6.1.1 = API 24**，你选的是对的。）

---

## 三、模拟器：有个好消息，和一件还没做的事

| 项 | 实测结果 |
|---|---|
| 镜像路径 | `D:\huawei\Emulator\image\system-image\HarmonyOS-6.1.1-B1` |
| 镜像版本 | HarmonyOS 6.1.1 ｜ `apiVersion 24` ｜ Beta1 ｜ `6.1.0.117` |
| 含哪些 | **`phone_all_x86` + `tablet_x86`** 两套（正好对上你的手机+平板一多演示） |
| 已创建的虚拟设备 | **0 个**（`lists.json` = `[]`，`.emu_config` 里只有路径和协议同意） |

**好消息：4.7 GB 的镜像早就下好了，不用重新下。**
**要做的：在 Device Manager 里 `Create Device`，选 6.1.1 镜像 + 机型（可选 Pura 90 / MatePad Pro 13 等），建完启动。**

镜像版本 `24` 和 hap 的 `minAPIVersion 60101024` 正好对齐 —— **装得上**。

> 之前我判断"旧模拟器没了"只对了一半：DevEco 6.1 时代那台设备确实不在了，但镜像文件还在，省掉一次 4.7 GB 下载。

---

## 四、一个还没解决的硬问题：签名没配

编译日志里有一行警告，别忽略：

```
> hvigor WARN: Will skip sign 'hos_hap'. No signingConfigs profile is configured in current project.
```

所以你现在的产物叫 **`entry-default-unsigned.hap`** —— **未签名，装不上任何设备，包括模拟器。**

按官方文档（`编写与调试应用 > 配置调试签名 > 自动签名`）这步要这么做：

1. 先在 Device Manager 里**创建并启动一个模拟器**（自动签名要求有已连接的设备）
2. `File > Project Structure... > Project > Signing Configs`，点 **Sign In** 登录华为开发者账号
3. 勾选 **Automatically generate signature**
4. 重新 Build → 这次的产物才是能装的 `entry-default-signed.hap`

⚠️ 官方明确写了：**本地系统时间必须与北京时间（UTC+8）一致，否则签名必失败**。先对一下时间。

这一步没做，后面 11 天做出来的东西一次都跑不起来。

---

## 五、我已经给你备好的命令行编译（不用开 IDE 也能验证代码）

工程根目录外，我放了一个脚本：`lighthouse-guanggu/tools/build.sh`

```bash
bash D:/work/workbuddy/lighthouse-guanggu/tools/build.sh
```

它做的事等价于（关键是 `DEVECO_SDK_HOME` 必须指向**内置** SDK，不是 `D:\huawei\openHarmonysdk`）：

```bash
DEVECO_SDK_HOME="D:\DevEco Studio\sdk" \
  "D:/DevEco Studio/tools/node/node.exe" \
  "D:/DevEco Studio/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default assembleHap --no-daemon
```

**它的用处很大**：后面我把 `ai-code/` 那三个 ArkTS 文件给你之后，你不用每次在 IDE 里点半天 —— 直接跑这个脚本，报错原文秒出，改起来快得多。

两个坑记一下：
- `DEVECO_SDK_HOME` 指向 `D:\huawei\openHarmonysdk` 会报 `00303312 Cannot find the corresponding SDK version`（那是 OpenHarmony 布局，没有 `hms/` 和 `sdk-pkg.json`）
- 不设或设错会报 `00303217 Invalid value of 'DEVECO_SDK_HOME'`

---

## 六、建完之后核对一遍

- [x] `build-profile.json5` → `compatibleSdkVersion: "6.1.1(24)"`、`targetSdkVersion: "26.0.0"` ✅ 你已经是这样了
- [x] `module.json5` → `deviceTypes: ["phone","tablet","2in1"]` ✅ 三个都在
- [x] 命令行编译通过 ✅ 已实测
- [ ] Device Manager 里创建 6.1.1 模拟器并启动
- [ ] 配自动签名，产物从 `-unsigned` 变成 `-signed`
- [ ] 装上去跑一个 Hello World
- [ ] 加服务卡片（右键 `entry` → `New` → `Service Widget`）
- [ ] `module.json5` 加 `ohos.permission.INTERNET`（DeepSeek 联网要）

---

## 七、为什么 compatibleSdkVersion 选 24 这件事仍然重要

参赛要交可运行的 `.hap`，而大赛只有 **5 次提交机会、取最后一次**，没有补救余地。

- 填 `26.0.0` → DevEco 自己提示「将在约 **0%** 的设备上运行」→ 评委装不上 = **作品无法运行**
- 填 `6.1.1(24)` → 覆盖 HarmonyOS 6.1.1 及以上在用设备，且开发体验零损失（编译照样用 26）

**能选低就选低。这不是保守，是让作品能被装上。**
