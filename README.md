# Moumusic

Moumusic 是一次独立重构，不包含旧 `moumusic-ios` 工程的代码。

## 当前基线

- `platforms/ios`：直接基于 [Kumone](https://github.com/missuo/kumone) 的 SwiftUI iOS 工程，保留网易云登录、推荐、搜索、歌单、播放页、歌词、逐字歌词和液态玻璃导航体验。
- `platforms/android`：直接基于 [lx-music-mobile](https://github.com/lyswhut/lx-music-mobile) 的 React Native 工程，保留后台播放、播放队列、歌词、缓存、下载、歌单和用户源管理。
- 两个平台互不依赖旧项目；后续功能按各自平台的原生基线演进。

## 音源策略

Android 默认不注册酷我、酷狗、QQ、网易云、咪咕等内置音源。用户可在“设置 → 自定义源管理”导入 LX User API（JavaScript）或 LX 支持的源文件，再选择已导入的源播放；播放层同时保留旧版音源字段兼容和 `musicUrl` / `lyric` / `pic` 能力。

iOS 侧保留 Kumone 的网易云数据与播放流程。第三方解锁不作为默认音源注册；iOS 音源适配会在独立的跨平台源协议确定后接入，避免把服务地址硬编码进客户端。

## 构建

### Android

```powershell
cd platforms/android
npm install
npm run pack:android
```

无签名发布构建会输出 `platforms/android/android/app/build/outputs/apk/release/` 下的 APK。需要正式签名时，再按 LX Mobile 的 `keystore.properties` 方式提供签名配置。

### iOS

在 macOS 上打开 `platforms/ios/ios/KumoneIOS.xcworkspace`，或使用 `platforms/ios/ios/KumoneIOS.xcodeproj` 构建。项目默认关闭自动签名要求，未签名 IPA 只用于侧载测试。

## 上游许可

源码复制与修改说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。请保留各平台目录中的上游许可证与版权声明。
