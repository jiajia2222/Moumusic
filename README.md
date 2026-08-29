# Moumusic

Moumusic 是一次独立重构，不包含旧 `moumusic-ios` 工程的代码。

## 当前架构

- `platforms/android` 是 Moumusic 的共享 React Native 客户端，同时作为 Android 与 iOS 的前端基线；界面、播放队列、歌词、缓存、下载、歌单和用户源管理由同一套代码维护。
- `platforms/android/src/utils/musicSdk` 内置酷我、酷狗、QQ、网易云、咪咕的平台适配器，负责搜索、歌单、排行榜和推荐目录。
- `platforms/ios` 保留 Kumone 作为参考源码与许可证边界，但当前 iOS 发布构建不再使用 Kumone UI，而是构建上面的 Moumusic 共享客户端。

## 音源策略

平台与音源是两层：搜索栏切换“平台”，设置页的“播放音源”切换用户导入的 LX User API。用户可在“设置 → 自定义源管理”导入 JavaScript 源，再选择已导入的源为歌曲返回播放地址、歌词、封面和可用音质；仓库不硬编码第三方解锁服务，也不预置音源脚本。

## 构建

### Android

```powershell
cd platforms/android
npm install
npm run pack:android
```

无签名发布构建会输出 `platforms/android/android/app/build/outputs/apk/release/` 下的 APK。需要正式签名时，再按 LX Mobile 的 `keystore.properties` 方式提供签名配置。

### iOS

在 macOS 上进入 `platforms/android` 执行 `pod install`，然后打开 `platforms/android/ios/LxMusicMobile.xcworkspace` 构建共享 iOS 客户端。项目默认关闭自动签名要求，未签名 IPA 只用于侧载测试。

## 上游许可

源码复制与修改说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。请保留各平台目录中的上游许可证与版权声明。
