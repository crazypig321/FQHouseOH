<h1 align="center">🏠 FQHouseOH</h1>
<div align="center">
  <img src="entry/src/main/resources/base/media/foreground.png" width="25%">
</div>
<p align="center">
  <b>小说 / 短剧 / 漫剧 / 漫画 / 听书聚合客户端 fqapp 的 HarmonyOS（鸿蒙）移植版</b>
</p>

<p align="center">
  <a href="https://www.gnu.org/licenses/gpl-3.0.html"><img src="https://img.shields.io/badge/License-GPL--3.0-blue.svg" alt="License: GPL-3.0"></a>
  <a href="https://www.harmonyos.com/"><img src="https://img.shields.io/badge/Platform-HarmonyOS-green.svg" alt="Platform: HarmonyOS"></a>
  <a href="https://developer.huawei.com/consumer/cn/arkts/"><img src="https://img.shields.io/badge/Language-ArkTS-orange.svg" alt="Language: ArkTS"></a>
</p>

---

**FQHouseOH** 是番茄免费小说 / 短剧第三方客户端 [fqapp](https://github.com/ch6vip/fqapp)（作者：ch6vip）的 **HarmonyOS（鸿蒙）移植版**，使用 ArkTS / ArkUI 原生开发，不依赖 Flutter 运行时。

> 🙏 本项目移植于 ch6vip 的 fqapp，感谢原项目提供的优秀设计与 Rust 后端核心。
> 🔗 原项目仓库：<https://github.com/ch6vip/fqapp>

---

## 📥 安装与使用

### 🚀 快速开始

1. **下载安装**
    - 从 [Releases](https://github.com/crazypig321/FQHouseOH/releases) 下载最新版 `.hap` 包，使用[小白调试助手](https://github.com/likuai2010/auto-installer)安装到 HarmonyOS 设备
    - 或者使用命令行构建： `hvigorw assembleHap`，然后安装生成的 `.hap` 包
    - 安装后首次启动会自动部署 Rust 后端运行时资源，并在本地启动 HTTP 服务

2. **开始使用**
    - 首页聚合书籍 / 短剧推荐流，支持搜索、榜单、详情浏览
    - 书架支持收藏与批量管理，浏览 / 收听 / 观看记录自动保存
    - 设置页可切换深色模式、管理缓存、查看本地后端 Web UI

---

## ✨ 功能特性

| 功能 | 说明 |
|--------------------|--------------------------------------------------------------------|
| 📚 **聚合阅读** | 小说 / 漫画阅读器，章节目录、书评章评、阅读进度记忆与统计 |
| 🎬 **短剧 / 漫剧** | 视频流播放、剧集缓存离线观看、观看记录 |
| 🎧 **听书** | 多音色 TTS 听书、倍速播放、后台播放、播控中心 / 实况窗显示 |
| 🎬 **mpv 播放内核** | 基于 mpv-arkts（libmpv）的视频与听书播放，支持倍速、后台播放 |
| 🔍 **搜索与榜单** | 聚合搜索、榜单分类、作者主页 |
| ⭐ **书架收藏** | 收藏管理、批量操作、浏览 / 收听 / 观看 / 阅读统计记录 |
| ⬇️ **缓存管理** | 章节缓存、剧集缓存、一键清空历史 |
| 🌙 **深色模式** | 跟随系统 / 浅色 / 深色三档切换，即时生效 |
| 🖥️ **本地后端** | Rust 核心进程内运行，签名与解密在手机本地完成，支持 Web UI 查看 |
| ⚙️ **设置中心** | 外观、播放、数据、服务、关于（更新日志 / 代理下载更新包 / 开源许可 / 支持作者）等 |

---

## 🛠️ 技术栈

| 依赖 | 说明 |
| --- | --- |
| **ArkTS / ArkUI**（`@ComponentV2`） | 应用主体，状态驱动 V2 模型，UI 大框架对齐 musicfreeOH |
| **HDS 组件库**（`@kit.UIDesignKit`） | 标题栏 / 底部页签 / 半模态等系统级 UI 组件 |
| **Rust 核心**（vendored `fqapi_core`） | 进程内本地 HTTP 服务（`127.0.0.1:8080`），业务签名与解密在本地完成 |
| **Node-API 绑定**（`crates/fqapi_napi`） | 手写 `libfqapi_napi.so` 适配层，ArkTS 经其驱动 Rust 核心 |
| **mpv-arkts**（`@mpv-ohos/mpv-arkts`） | HarmonyOS libmpv 绑定，视频 / 听书播放内核 |
| **Asset Store Kit**（`@kit.AssetStoreKit`） | 设备池密钥安全存储，不可用时降级明文池 |

---

## 📱 软件截图

（待补充）

---

## 🚀 环境与构建

1. 安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（含 HarmonyOS SDK，API 26+），并配置 `DEVECO_HOME` 环境变量
2. 安装 Rust 与 `aarch64-unknown-linux-ohos` target（Ohos NDK 工具链）
3. 使用 DevEco Studio 打开本项目根目录，等待 ohpm 依赖同步完成
4. 连接 HarmonyOS 设备或启动模拟器，配置签名后即可运行调试

**命令行构建：**

```powershell
# 1. 交叉编译 Rust 核心为 libfqapi_napi.so（产物自动拷贝到 entry/libs/arm64-v8a/）
pwsh scripts/build_rust_ohos.ps1

# 2. 构建 HAP
hvigorw assembleHap
```

---

## ⚠️ 免责声明

本软件仅供**交流与学习**使用，是一款开源、免费的本地播放 / 阅读工具，请勿相信付费渠道资源。

- 软件本身**不内置、不提供**任何书籍、短剧、漫剧、漫画、听书内容
- 所有内容均来自**第三方网络接口**聚合，其内容的合法性、准确性与版权状况由相应提供方负责，与本软件无关

请遵守您所在地区的法律法规，合理、适度地使用本软件。因下载或使用本软件而产生的任何直接或间接责任，均由使用者自行承担。

---

## 📄 开源许可

本项目基于 [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html) 协议开源，同时遵循原项目 fqapp 的开源协议要求。

---

## 💖 致谢

- [fqapp](https://github.com/ch6vip/fqapp) 及其作者 **ch6vip** —— 本项目移植自该项目
- [mpv-arkts](https://gitcode.com/openharmony-tpc/mpv-arkts) —— HarmonyOS libmpv 绑定
- [musicfreeOH](https://github.com/crazypig321/MusicFreeOH) —— UI 大框架与组件设计参考

---

## 👍 支持作者

- 如果你也喜欢 FQHouseOH 项目，欢迎打赏作者（微信 / 支付宝）
<div align="center">
  <img src="entry/src/main/resources/base/media/erweima.png" width="35%">
</div>
> ⭐ 如果这个项目对你有帮助，欢迎给本项目 FQHouseOH 和原项目 [fqapp](https://github.com/ch6vip/fqapp) 点个 Star 支持一下～
>
