# Moumusic

Moumusic 是一个独立的跨平台音乐客户端：iOS 使用真正的 Kumone SwiftUI 源码，Android 使用真正的 LX Music Mobile 客户端源码。两端界面不同，是为了保留各自成熟的原生功能，而不是把一个壳套到另一个项目上。

文档语言： [简体中文](README.zh-CN.md) · [English](README.en.md)

## 当前架构

- `platforms/ios/Sources/Kumone`：Kumone 原生 SwiftUI 页面、液态玻璃播放页、队列、歌词和播放器。
- `platforms/ios/Sources/Kumone/Core/API/LXUserAPIService.swift`：iOS 的 LX User API 运行时桥接。
- `platforms/ios/Sources/Kumone/Core/API/LXCatalogService.swift`：酷我、酷狗、QQ 音乐、网易云、咪咕和“全部”聚合搜索。
- iOS “设置 → 首页推荐”默认是 LX 聚合，也可以单独切换酷我、酷狗、QQ 音乐、网易云或咪咕；网易云个性化推荐是显式选项。
- `platforms/android`：LX Music Mobile 原版 React Native 客户端，包括音源管理、平台切换、聚合搜索、歌词、下载和播放功能。

## 音源使用方式

仓库不内置第三方音源地址或脚本。用户在 iOS 的“设置 → LX 音源”中导入 LX User API 导出的 JSON 或 JavaScript，再选择启用的音源；Android 继续使用 LX Mobile 原有的音源管理页。

搜索页面的“全部/酷我/酷狗/QQ 音乐/网易云/咪咕”用于选择搜索平台。“全部”会并发搜索并去重。播放时，搜索结果会优先交给已启用的 LX 音源解析，无法解析时保留 Kumone 原有的网易云兼容回退。

## 构建

### Android

```powershell
cd platforms/android
npm ci
npm run pack:android
```

未签名 APK 会输出到 `platforms/android/android/app/build/outputs/apk/release/`。

### iOS

在 macOS 上直接打开 `platforms/ios/ios/KumoneIOS.xcodeproj`，选择 `KumoneIOS` scheme 构建。GitHub Actions 的 iOS workflow 也直接构建这个工程，并输出未签名 `Moumusic-unsigned.ipa`。

## 上游许可

源码复制、修改和许可说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。请保留上游项目的 LICENSE/COPYING 文件。
