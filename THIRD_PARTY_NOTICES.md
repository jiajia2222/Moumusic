# Third-party notices

## Kumone

- Upstream: https://github.com/missuo/kumone
- License: LGPL-3.0-only
- Location: `platforms/ios`
- Moumusic 直接使用其 SwiftUI 页面、播放器、歌词、设置和液态玻璃适配，并在 KumoneCore 内加入 LX 适配层。

## LX Music Mobile

- Upstream: https://github.com/lyswhut/lx-music-mobile
- License: Apache-2.0
- Location: `platforms/android`
- Android 保留其原版 React Native 客户端和 User API/QuickJS 实现。iOS 的 `LXUserAPIPreload.js` 直接来自其 Android User API preload 文件，用于实现相同的用户音源协议。

Moumusic 不预置第三方音源脚本或第三方服务地址。用户自行导入和启用的音源脚本由用户负责，并应遵守对应平台服务条款和上游项目许可。
