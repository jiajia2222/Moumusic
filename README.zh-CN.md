# Moumusic

Moumusic 是一个跨平台开源音乐客户端。iOS 使用 Kumone 的原生 SwiftUI 播放体验，Android 使用 LX Music Mobile 客户端；音乐目录和推荐用于发现内容，实际播放由用户自行导入并启用的 LX User API 音源完成。

本项目不内置或分发第三方音源地址，也不提供网易云登录。请只添加你有权使用的音源，并遵守平台服务条款与版权规定。

## 功能

- LX User API 音源导入、在线链接导入、检测、启用、切换和删除
- 酷我、酷狗、QQ 音乐、网易云、咪咕及 LX 聚合搜索
- 音源解析播放、歌词、封面、音质和歌曲来源显示
- iOS 原生播放页、同步歌词、队列、锁屏与控制中心控制
- iOS WidgetKit 歌词小组件，支持主屏幕与锁屏组件
- 网易云公开目录推荐、发现、歌单、评论和歌单导入
- 中文/英文界面

## 添加音源

iOS：进入“我的 → 设置 → LX 音源”，选择“从文件导入”或“从在线链接导入”，然后在音源列表中选择并检测。

Android：使用 LX Music Mobile 原有的音源管理页面。

## 构建

```sh
cd platforms/android
npm ci
npm run pack:android
```

iOS 需要 macOS 与 Xcode：

```sh
cd platforms/ios/ios
xcodebuild -project KumoneIOS.xcodeproj -scheme KumoneIOS -configuration Release -sdk iphoneos build
```

## 上游项目与许可证

- [Kumone](https://github.com/missuo/kumone)
- [LX Music Mobile](https://github.com/lyswhut/lx-music-mobile)

Moumusic 新增及独立代码遵循 [GPL-3.0](LICENSE)。上游文件保留其原始 LGPL、Apache 等许可证义务，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
