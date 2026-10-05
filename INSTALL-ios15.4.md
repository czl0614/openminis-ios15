# OpenMinis iOS 15.4 移植版 —— 安装指南

## 产物

| 项 | 值 |
|---|---|
| 文件 | `Minis-ios15.4-unsigned.ipa` |
| 大小 | 71 MB |
| 最低系统版本 | **iOS 15.4** |
| 签名状态 | **未签名**（需自行签名或由 TrollStore 处理） |
| 下载页 | https://github.com/czl0614/openminis-ios15/releases/tag/ios15.4-b21 |

### 已核验的属性

```
Payload/Minis.app/Info.plist      MinimumOSVersion = 15.4
Payload/Minis.app/Minis           LC_BUILD_VERSION minos = 15.4.0
Payload/Minis.app/PlugIns/AgentWidgetExtension.appex    MinimumOSVersion = 15.4
Payload/Minis.app/PlugIns/MinisShare.appex              MinimumOSVersion = 15.4
Payload/Minis.app/alpine-rootfs.zip                     3.8 MB（已嵌入）
```

`LC_BUILD_VERSION minos` 是运行期 dyld 检查的依据，它和 `MinimumOSVersion`
一致为 15.4，才说明这个 IPA 在 iOS 15 上不会因缺失符号而崩溃。

---

## 安装（TrollStore）

TrollStore 的支持范围是 **iOS 14.0 – 15.4.1**，你的 15.4.1 在范围内。
它会对 IPA 做永久签名，无需 Apple ID，也不会 7 天过期。

### 步骤

1. **确认设备芯片**（设置 → 通用 → 关于本机，或查机型）：
   不同芯片对应不同的 TrollStore 安装器。
2. **安装 TrollStore**：
   按你的 iOS 版本与芯片选择安装器（TrollInstallerX / TrollHelper 等），
   以 TrollStore 官方发布页的说明为准。
3. **把 IPA 传到设备**：
   - 通过「文件」App、AirDrop、或 iCloud Drive 均可
4. **用 TrollStore 打开 IPA**：
   TrollStore 里点右上角 `+`，选择该 IPA 文件
5. **等待安装完成**，回到桌面即可看到 Minis

### 安装后验证

- 桌面图标出现，点击能正常启动（不是启动即闪退）
- 进入 App 后能正常创建会话、发送消息

---

## 如果 TrollStore 不可用

备选自签方案（需要一台电脑）：

- **Sideloadly** / **AltStore**：用你的 Apple ID 重签名后安装。
  免费账号限制：**7 天有效期、最多 3 个 App**，到期需重新签名。
- 自签时注意：本 App 内嵌了 2 个扩展（分享扩展、小组件），
  自签工具需要一并处理，否则扩展功能不可用。

---

## 已知功能差异（相对 iOS 16+ 官方版本）

这些是移植过程中**有意为之**的取舍，不是缺陷：

| 功能 | iOS 15.4.1 上的状态 | 原因 |
|---|---|---|
| 「文件」App 集成（浏览 Minis 工作区） | **不可用** | `NSFileProviderReplicatedExtension` 是 iOS 16 引入的 API 族，已整体摘除该扩展 |
| 远程会话行（iCloud 同步自其它设备）点击 | **不可点击** | 依赖 `NavigationLink(value:)` 值路由，iOS 15 无此机制（长按菜单保留） |
| 消息气泡长按菜单 | **可用**，但长按预览卡片为系统默认样式 | `contextMenu` 的 `preview:` 参数是 iOS 16 才有；菜单本身保留 |
| 照片 / 视频选择器 | **不可用** | `PhotosPicker` 是 iOS 16 的 SwiftUI 组件 |
| 天气工具（WeatherKit） | 调用时返回「需要 iOS 16」错误 | WeatherKit 是 iOS 16+ |
| Siri 快捷指令（AppIntents） | **不可用** | AppIntents 是 iOS 16+ |
| 少数文字加粗 / 字重 | 不加粗 | `View.bold()` / `View.fontWeight()` 在 iOS 15 无等价物（仅 3–6 处） |

**核心功能完整保留**：聊天、Linux 沙箱（iSH）、内置文件浏览器、
内置浏览器、备份恢复、技能与记忆等。

---

## 首次使用提示

- 需要自备模型 API Key（Anthropic / OpenAI / Gemini 等），或使用账号登录
- 首次启动 Linux 沙箱需要解压 Alpine rootfs，会花几秒到几十秒
- 若启动即闪退，请把崩溃日志（设置 → 隐私与安全性 → 分析与改进 → 分析数据，
  找 `Minis-*.ips`）发回来，我可以据此定位
