# Moumusic

Moumusic 是一个独立的跨平台音乐客户端：iOS 使用 Kumone 的原生 SwiftUI 界面，Android 使用 LX Music Mobile 的原生客户端源码。项目不内置第三方音源，音源由用户自己添加。

## 功能

- LX User API 音源导入、启用、切换和删除
- LX 聚合搜索，以及酷我、酷狗、QQ 音乐、网易云、咪咕平台切换
- 用户音源负责歌曲播放、歌词和音质解析
- iOS Kumone 播放页、歌词、播放队列、锁屏控制和液态玻璃风格界面
- Android LX Mobile 原生的音源管理、搜索、歌词、下载和播放
- iOS 首页推荐默认使用 LX 聚合，可在设置中主动切换平台
- 中文与英文界面资源

## 添加音源

iOS：打开“我的 → 设置 → LX 音源 → 导入 LX User API”，选择 LX 导出的 JSON 或原始 JavaScript 文件，然后在“当前音源”中启用。

Android：使用 LX Mobile 原有的音源管理页面添加和启用音源。

仓库不会预置或分发第三方音源地址。请只添加你有权使用的音源，并自行遵守相关平台的服务条款和版权规定。

## 构建

Android：

```powershell
cd platforms/android
npm ci
npm run pack:android
```

iOS 需要 macOS 和 Xcode：

```sh
cd platforms/ios/ios
xcodebuild -project KumoneIOS.xcodeproj -scheme KumoneIOS -configuration Release -sdk iphoneos build
```

未签名 IPA 需要使用你自己的开发者证书、AltStore、TrollStore 或其他侧载工具安装。

## 上游项目与许可

- [Kumone](https://github.com/missuo/kumone)
- [LX Music Mobile](https://github.com/lyswhut/lx-music-mobile)

源码复制、修改和许可说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
