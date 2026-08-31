# Moumusic

Moumusic 是一个面向 iOS 与 Android 的开源音乐客户端。它把 Kumone 的原生 SwiftUI 播放体验与 LX Music Mobile 的用户音源协议结合起来：目录、推荐、搜索和歌单用于发现音乐，实际播放由用户自行导入并启用的 LX User API 音源完成。

> 本项目不内置、不分发第三方音源地址，也不提供网易云登录。请仅添加你有权使用的音源，并遵守相关平台服务条款与版权规定。

[简体中文](README.zh-CN.md) · [English](README.en.md) · [更新日志](CHANGELOG.md) · [发布页](https://github.com/jiajia2222/Moumusic/releases)

## 功能

- LX User API 音源的导入、检测、启用、切换与删除
- 酷我、酷狗、QQ 音乐、网易云、咪咕和 LX 聚合搜索
- 用户音源解析播放、歌词、封面、音质与来源展示
- iOS 原生播放页、歌词同步、队列、锁屏/控制中心播放控制
- 网易云公开目录的推荐、发现、歌单、评论和歌单导入
- iOS 与 Android 分别保留 Kumone、LX Music Mobile 的成熟原生体验
- 中文与英文界面

## 添加音源

iOS：打开“我的 → 设置 → LX 音源 → 从文件导入”或“从在线链接导入”，导入 LX User API 导出的 JSON/JavaScript，然后在音源列表中选择并检测。

Android：使用 LX Music Mobile 原有的音源管理页面添加和启用音源。

## 安装

从 [Releases](https://github.com/jiajia2222/Moumusic/releases) 下载对应平台的构建产物。iOS 发布的是未签名 IPA，需要使用自己的证书、AltStore、SideStore、TrollStore 或其他侧载工具安装。

## 构建

### Android

```sh
cd platforms/android
npm ci
npm run pack:android
```

### iOS

需要 macOS 与 Xcode：

```sh
cd platforms/ios/ios
xcodebuild -project KumoneIOS.xcodeproj -scheme KumoneIOS -configuration Release -sdk iphoneos build
```

## 项目结构

```text
platforms/ios/Sources/Kumone/       iOS SwiftUI 客户端与 LX 适配层
platforms/ios/Sources/Kumone/Core/  API、音源、播放器、歌词和存储
platforms/android/                  LX Music Mobile React Native 客户端
```

## 上游项目与致谢

- [Kumone](https://github.com/missuo/kumone)：iOS SwiftUI 界面与播放器基础
- [LX Music Mobile](https://github.com/lyswhut/lx-music-mobile)：用户音源协议与 Android 客户端

源码来源、修改范围和各组件许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可证

Moumusic 新增及独立编写的代码以 [GNU GPL v3.0](LICENSE) 发布。Kumone、LX Music Mobile 以及其他上游文件继续遵守其原始许可证；GPL 许可证不替代这些文件原有的 LGPL、Apache 或其他许可义务。
