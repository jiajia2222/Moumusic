<div align="center">

<img src="platforms/ios/docs/icon.png" width="140" alt="Moumusic" />

# Moumusic


**面向 iOS 与 Android 的多音源音乐客户端**

iOS 原生 SwiftUI · LX User API 音源 · Android LX Music Mobile

[![Platform](https://img.shields.io/badge/platform-iOS%2016%2B%20%7C%20Android-blue?logo=apple)](#构建)
[![LGPL-3.0](https://img.shields.io/badge/license-LGPL--3.0-orange)](LICENSE)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-orange)](COPYING)

</div>

[English](README.md) · **简体中文**

Moumusic 是一个独立的跨平台音乐客户端：iOS 以 Kumone 的原生 SwiftUI 播放体验为基础，Android 使用 LX Music Mobile 客户端和音源协议。目录、推荐、搜索和歌单用于发现音乐，实际播放由用户自行导入并启用的 LX User API 音源完成。

> 本项目不内置或分发第三方音源地址，也不提供网易云登录。请只添加你有权使用的音源，并遵守相关服务条款和版权规定。

## 功能

- 从 JSON、JavaScript 或在线链接导入 LX User API 音源
- 音源可用性检测、启用、切换和删除
- 酷我、酷狗、QQ 音乐、网易云、咪咕及 LX 聚合搜索
- 通过用户音源解析播放、歌词、封面和音质选择
- iOS 原生播放页、播放队列、同步歌词、锁屏控制和控制中心播放控制
- WidgetKit 当前歌词小组件，支持主屏幕和锁屏
- 网易云公开目录：推荐、发现、歌单、评论和歌单导入
- Android LX Music Mobile 原生音源管理、搜索、歌词、下载和播放
- 简体中文与英文界面

## 添加音源

iOS：进入 **我的 → 设置 → LX 音源**，选择 **从文件导入** 或 **从在线链接导入**，然后选择并检测音源。Android 使用 LX Music Mobile 原有的音源管理页面。

仓库不会预置第三方音源地址。用户导入的音源属于用户配置，请自行确认来源合法并遵守相关平台规定。

## 安装

从 [Releases](https://github.com/jiajia2222/Moumusic/releases) 下载最新构建。iOS 发布的是未签名 IPA，需要使用自己的证书、AltStore、SideStore、TrollStore 或其他侧载工具安装。

## 构建

### Android

```sh
cd platforms/android
npm ci
npm run pack:android
```

### iOS

需要 macOS 和 Xcode。工程使用 XcodeGen 生成 App 与 WidgetKit 扩展：

```sh
cd platforms/ios/ios
xcodegen generate
xcodebuild -project KumoneIOS.xcodeproj -scheme KumoneIOS -configuration Release -sdk iphoneos build
```

## 项目结构

```text
platforms/ios/
├── Sources/Kumone/
│   ├── Core/API/          网易云目录 API 与 LX User API 桥接
│   ├── Core/Models/       歌曲模型与歌词解析器
│   ├── Core/Player/       队列、AVPlayer、歌词和系统播放状态
│   ├── Core/Storage/      设置、账户和图片缓存
│   ├── DesignSystem/      SwiftUI 颜色、卡片、玻璃效果和布局
│   └── Features/          首页、搜索、音乐库、设置和播放页
├── ios/                   iOS App 壳与 XcodeGen 配置
├── ios/MoumusicWidget/    WidgetKit 当前歌词扩展
├── Scripts/               iOS 打包和发布脚本
└── docs/                  图标和产品截图
platforms/android/         LX Music Mobile React Native 客户端
```

## 上游项目

- [Kumone](https://github.com/missuo/kumone)：原生 SwiftUI 音乐客户端基础和 iOS 界面方向
- [LX Music Mobile](https://github.com/lyswhut/lx-music-mobile)：音源协议和 Android 客户端

Moumusic 的修改范围见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，上游代码和资源继续遵守各自原始许可证。

## 许可证

仓库附带完整的 [LGPL-3.0-only](LICENSE) 和 [GPL-3.0-only](COPYING) 文本。各源文件和组件按其声明使用对应许可证：Kumone 代码继续遵守 LGPL-3.0-only，LX Music Mobile 代码继续遵守 Apache-2.0。

<h2 align="center">💖 支持 Moumusic</h2>

<p align="center">
  如果 Moumusic 对你有帮助，欢迎在爱发电支持项目持续维护。<br />
  <a href="https://www.ifdian.net/a/moumou2026">
    <img src="https://img.shields.io/badge/%E7%88%B1%E5%8F%91%E7%94%B5-%E6%94%AF%E6%8C%81%E9%A1%B9%E7%9B%AE-ff5c5c?style=for-the-badge&logo=heart&logoColor=white" alt="在爱发电支持项目" height="36" />
  </a>
</p>

<h2 align="center">⭐ Star 趋势</h2>

<a href="https://www.star-history.com/?type=date&repos=jiajia2222%2FMoumusic">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=jiajia2222/Moumusic&type=date&theme=dark&legend=top-left&sealed_token=7V-vJu1k6AepIoqrFLS3S_DCHmhVCY19DW-BjSBOohycTR2EimUmGUfb4oBZh4-uCd6-9dhU4c3uQEdcKsjrYn0D-zmPWVGpRHLEPiUn3MkSTCH7kxmoKQ" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=jiajia2222/Moumusic&type=date&legend=top-left&sealed_token=7V-vJu1k6AepIoqrFLS3S_DCHmhVCY19DW-BjSBOohycTR2EimUmGUfb4oBZh4-uCd6-9dhU4c3uQEdcKsjrYn0D-zmPWVGpRHLEPiUn3MkSTCH7kxmoKQ" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=jiajia2222/Moumusic&type=date&legend=top-left&sealed_token=7V-vJu1k6AepIoqrFLS3S_DCHmhVCY19DW-BjSBOohycTR2EimUmGUfb4oBZh4-uCd6-9dhU4c3uQEdcKsjrYn0D-zmPWVGpRHLEPiUn3MkSTCH7kxmoKQ" />
 </picture>
</a>
