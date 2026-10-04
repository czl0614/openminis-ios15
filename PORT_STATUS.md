# OpenMinis iOS 15.4 降级移植 —— 当前状态

## 目标
把 GitHub 开源项目 `OpenMinis/OpenMinis`（Swift/SwiftUI，GPLv3）的最低系统要求
从 iOS 16.0 降到 **iOS 15.4**，让 iPhone（iOS 15.4.1）能安装，最终交付 IPA。

## 已核实的关键事实（均来自源码，非推测）

| 项 | 值 |
|---|---|
| 主 App / ShareExtension / FileProvider 原部署目标 | iOS 16.0 |
| AgentWidget 原部署目标 | iOS 16.2 |
| 代码规模 | 622 个 Swift 文件 / 约 29.8 万行 |
| 官方分发方式 | 仅 App Store / TestFlight，**无预编译 IPA** |
| 原生依赖 | iSH 内核、FFmpeg、LAME、rclone、Alpine rootfs，全部源码编译 |
| 构建要求 | macOS + Xcode + Metal Toolchain + Go 1.25+ |
| 许可证 | GPLv3（链接 iSH/PRoot） |

## 为什么不能走「改二进制」捷径
`NavigationStack` 出现在 55 个文件中，是 iOS 16.0 才引入的 SwiftUI 类型。
iOS 15 的 SwiftUI 模块不含该符号，只改 IPA 里的 `MinimumOSVersion` 会在
dyld 加载阶段直接崩溃。**必须源码级降级。**

## 已完成的改造（分支 legacy-ios15，87 文件，+2952/-2034）

### 1. 兼容层 `src/ios/Shared/LegacyIOSCompat.swift`（新增）
按「改名转发」原则包装以下 API，iOS 16+ 全部直接转发到系统实现（行为不变），
iOS 15 退化为最接近的等价实现或 no-op：

- `MinisNavStack` / `MinisNavStackPath` ← `NavigationStack`
- `minisNavigationDestination` ← `navigationDestination`
- `MinisLegacyCompactStack` ← iOS 15 单层手动栈回退
- `MinisLabeledContent` ← `LabeledContent`（4 种初始化形态）
- `minisToolbarBackground` / `.minisTopBarTrailing` / `.minisTopBarLeading`
- `minisPresentationDetents` / `minisPresentationDragIndicator`
- `minisScrollContentBackground` / `minisScrollIndicators`
  / `minisScrollDismissesKeyboard` / `minisPersistentSystemOverlays`
- `minisSymbolEffectPulse(Repeating)` / `minisContentTransition`
- `minisPresentationSizingPage` / `minisBold`

### 2. 批量替换（`tools/legacy_ios15_apply.py`，可重跑）
312+ 处调用点改为 shim，覆盖 70 个文件。

### 3. 手工改造
- `ContentView.stackLayout`：拆成 `stackLayout`（`#available` 分支）
  + `stackLayoutModern`；iOS 15 走 `MinisLegacyCompactStack`，
  复用 iPad 已有的 `splitList` + `detailView`
- `ContentView.splitLayout`：`NavigationSplitView` 用 `#available` 包裹，
  iOS 15 退化为紧凑单列；删除 `NavigationSplitViewVisibility` 状态
- `NavigationPath` → `[String]` / `[SettingsDestination]`（9 处）
- AppIntents 类型加 `@available(iOS 16.0, *)`（17 处）
- `HelperRunner.swift` 中 `SendPromptIntent` 调用加 `#available` 守卫

### 4. 无需改动的部分（上游已正确处理）
- **ActivityKit / Live Activity**：全部实现已隔离在 `@available(iOS 16.2, *)`
  私有方法内，公开 API 用运行期 `isActivityKitAvailable` 把关 → 零改动
- **AlarmKit（iOS 26）**：已用 `#if canImport(AlarmKit)` 守卫 → 零改动
- **AgentLiveActivityWidget**：全部类型已标 `@available(iOSApplicationExtension 16.2, *)`
- **`MinisApp.swift` 的 `MinisShortcutsProvider` 调用**：已有 `#available(iOS 17.0, *)`
- `.onChange(of:)`：用的是 iOS 14 单参形式，iOS 15 原生支持 → 零改动
- `Grid` / `Table` / `scrollPosition`：静态扫描命中的都是自定义类型或 UIKit 参数，非 SwiftUI API

### 5. 工程配置
- pbxproj：4 个目标的部署目标 → 15.4（新文件已注册进 4 个目标）
- `deps/build_rclone_ios.sh`：`-miphoneos-version-min=16.0` → 待改（当前 16.0）
- 未开启「警告即错误」，`NavigationView` 等废弃警告不会中断构建

### 6. 构建流水线
- `.github/workflows/build-ios15-ipa.yml`（GitHub Actions，macOS 构建 → 未签名 IPA）
- `tools/build_ios15_local.sh`（本机 Mac 一键构建）

## 阻塞点
**构建必须在 macOS 上完成**，当前环境为 Windows，且：
- 本机无 Xcode / Swift / Go / gh
- GitHub 连接器无 fork 权限（`403 Resource not accessible by integration`）
- 无 `GITHUB_TOKEN` / PAT 可用

因此需要用户选择构建主机后才能产出 IPA。

## 后续步骤
1. 选定 macOS 构建主机（GitHub Actions 分支 / 用户自己的 Mac / 其他 CI）
2. 跑通流水线，按编译错误迭代（首次构建预计 60–90 分钟，主要是 FFmpeg/iSH）
3. 产出 IPA 并验证 `MinimumOSVersion = 15.4`
4. iOS 15.4.1 安装（TrollStore 或 AltStore/Sideloadly 自签）
5. 真机测试运行期行为，重点验证 iOS 15 回退路径的导航体验
