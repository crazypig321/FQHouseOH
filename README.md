# FQHouseOH

番茄免费小说/短剧第三方 HarmonyOS 客户端（原生 ArkUI 实现）。将 [fqapp](../fqapp) 的 Rust 后端核心 `fqapi_core` 通过手写 Node-API 适配层（`crates/fqapi_napi`）集成进 HarmonyOS 应用，UI 全部使用 ArkTS/ArkUI 原生实现，不依赖 Flutter 运行时。

## 架构

```
ArkTS UI (ArkUI)                Rust 核心 (fqapi_core)
  pages/  HomePage/SearchPage     rust/          vendored fqapi_core（含 cfg 补丁）
  component/FqItemCard           crates/fqapi_napi   手写 Node-API 绑定
  core/   FqBackend (HTTP API)          ↓ libfqapi_napi.so
  core/   FqDeployer (rawfile 部署)   本地 127.0.0.1:8080 服务
  core/   FqKeyStore (Asset 密钥)
```

- **Rust 核心**在应用内启动本地 HTTP 服务（端口 8080），ArkTS 侧通过 `FqBackend` 请求 `/api/v1/recommend/homepage`、`/api/v1/search`、`/api/detail` 等端点，资源图片经 `/_session/<capability>/src/...` 代理。
- **运行时资源**（config/filters/web/plugins，共 30 个文件）打包在 `entry/src/main/resources/rawfile/backend/`，首次启动由 `FqDeployer` 幂等部署到 `filesDir/backend/`。
- **设备池密钥**由 Asset Store Kit 生成并保管（32 字节随机），安全存储不可用时降级明文池。

## 构建

前置要求：

- DevEco Studio（含 HarmonyOS SDK，API 26+）、DevEco 命令行工具（`devecocli`）
- Rust + `aarch64-unknown-linux-ohos` target（Ohos NDK 工具链）
- 环境变量 `DEVECO_HOME` 指向 DevEco Studio 安装目录

步骤：

```powershell
# 1. 交叉编译 Rust 核心为 libfqapi_napi.so（产物自动拷贝到 entry/libs/arm64-v8a/）
pwsh scripts/build_rust_ohos.ps1

# 2. 构建 HAP
devecocli build

# 3. 运行（连接设备/模拟器）
devecocli run --skip-build
```

`scripts/build_rust_ohos.ps1` 内部执行 `cargo build --release --target aarch64-unknown-linux-ohos` 并把 `target/aarch64-unknown-linux-ohos/release/libfqapi_napi.so` 复制到 `entry/libs/arm64-v8a/`。

## 目录结构

- `rust/` — vendored `fqapi_core`（业务代码与上游保持一致，仅一处 `core_log` cfg 补丁）
- `crates/fqapi_napi/` — Node-API 适配层，导出 `init/request/cancel/version/setDevicePoolKey/status/baseUrl/sessionCapability/shutdown`
- `entry/src/main/ets/` — ArkTS 侧代码（全部 `@ComponentV2`/`@Local`/`@Param`，UI 大框架对齐 musicfreeOH：`HdsNavigation` + `HdsTabs` 悬浮底栏 `barOverlap`+`barFloatingStyle`，全局状态 `@ObservedV2` AppState 单例）：
  - `pages/` — Index（HdsNavigation+HdsTabs 悬浮底栏）/ HomePage / SearchPage / DetailPage（NavDestination，`.navDestination` 集中页表路由，长列表 LazyForEach 懒加载）
  - `view/` — 页面装配（TabContent + 二级路由页表）
  - `component/` — 通用组件
  - `core/` — FqBackend（API 客户端/请求合并/并发闸）、FqParser（响应解析，对齐 Dart 解析语义）、FqMediaDataSource（LazyForEach 数据源）、FqDeployer、FqKeyStore、FqJson（类型收口）
  - `model/` — 展示模型、路由常量与静态参数类
  - `utils/` — NavPathUtils 路由工具
  - `entryability/AppState.ets` — 全局单例（NavPathStack + 当前 Tab）
- `entry/src/main/cpp/types/libfqapi_napi/` — 原生模块类型声明（`import fq from 'libfqapi_napi.so'`）
- `entry/src/main/resources/rawfile/backend/` — 运行时资源（config + filters + web + plugins）

## 路线图

- [x] M1：Rust 核心集成 + 首页推荐流 + 搜索 + 详情展示
- [ ] M2：阅读器/播放器（web 内嵌插件）、书架收藏、浏览记录
- [ ] 视频频道两段式推荐（cell/series-feed）

## 许可

见 [LICENSE](LICENSE)。
