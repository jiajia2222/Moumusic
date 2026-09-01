<div align="center">

<img src="platforms/ios/docs/icon.png" width="140" alt="Moumusic" />

# Moumusic


**A source-driven music client for iOS and Android**

SwiftUI on iOS · LX User API sources · LX Music Mobile on Android

推荐您使用的音源 https://github.com/Macrohard0001/lx-ikun-music-sources


I'd recommend this audio source for you
https://github.com/Macrohard0001/lx-ikun-music-sources

[![Platform](https://img.shields.io/badge/platform-iOS%2016%2B%20%7C%20Android-blue?logo=apple)](#build)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](platforms/ios/Package.swift)
[![LGPL-3.0](https://img.shields.io/badge/license-LGPL--3.0-orange)](LICENSE)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-orange)](COPYING)

</div>

[简体中文](README_CN.md) · **English**

Moumusic is an independent cross-platform music client. It uses Kumone's native SwiftUI experience as the iOS foundation and LX Music Mobile's source protocol and Android client. Public catalog data is used for discovery; audio playback is resolved through LX User API sources imported and enabled by the user.

> Moumusic does not bundle third-party source URLs or provide NetEase login. Add only sources you are authorized to use and follow the terms and copyright rules of each service.

## Features

- LX User API source import from JSON, JavaScript or an online URL
- Source availability checks, enable/switch/delete management
- Kuwo, Kugou, QQ Music, NetEase, Migu and aggregate search
- Source-resolved playback with lyrics, artwork and quality selection
- Native iOS player, queue, synced lyrics, lock-screen controls and Control Center playback controls
- WidgetKit current-lyrics widget for Home Screen and Lock Screen
- Public NetEase catalog: recommendations, discovery, playlists, comments and playlist import
- Native LX Music Mobile Android source management, search, lyrics, downloads and playback
- Simplified Chinese and English interfaces

## Add a source

On iOS, open **Library → Settings → LX Sources**, choose **Import from File** or **Import from Online URL**, then select and test the source. On Android, use the original LX Music Mobile source-management page.

The app intentionally does not ship a default third-party provider URL. Imported sources are user configuration and remain the user's responsibility.

## Installation

Download the latest builds from [Releases](https://github.com/jiajia2222/Moumusic/releases). iOS releases are unsigned IPAs and must be installed with your own certificate, AltStore, SideStore, TrollStore or another sideloading tool.

## Build

### Android

```sh
cd platforms/android
npm ci
npm run pack:android
```

### iOS

Requires macOS and Xcode. XcodeGen is used to generate the app and WidgetKit extension targets:

```sh
cd platforms/ios/ios
xcodegen generate
xcodebuild -project KumoneIOS.xcodeproj -scheme KumoneIOS -configuration Release -sdk iphoneos build
```

## Architecture

```text
platforms/ios/
├── Sources/Kumone/
│   ├── Core/API/          NetEase catalog and LX User API bridge
│   ├── Core/Models/       Track models and lyric parsers
│   ├── Core/Player/       Queue, AVPlayer, lyrics and system playback state
│   ├── Core/Storage/      Settings, account and image cache
│   ├── DesignSystem/      SwiftUI colors, cards, glass surfaces and layout
│   └── Features/          Home, search, library, settings and player pages
├── ios/                   iOS app shell and XcodeGen manifest
├── ios/MoumusicWidget/    WidgetKit current-lyrics extension
├── Scripts/               iOS packaging and release helpers
└── docs/                  Icon and product screenshots
platforms/android/         LX Music Mobile React Native client
```

## Upstream projects

- [Kumone](https://github.com/missuo/kumone) — native SwiftUI music client foundation and iOS UI direction
- [LX Music Mobile](https://github.com/lyswhut/lx-music-mobile) — source protocol and Android client

Moumusic-specific changes are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Upstream code and assets retain their original license obligations.

## License

Moumusic includes the complete [LGPL-3.0-only](LICENSE) and [GPL-3.0-only](COPYING) texts. Apply the license stated by each source file or component. Kumone code remains LGPL-3.0-only and LX Music Mobile code remains Apache-2.0; these obligations are not replaced by Moumusic's project documentation.

## Star History

[![Star History Chart](https://api.star-history.com/image?repos=jiajia2222/Moumusic&type=Date)](https://www.star-history.com/#jiajia2222/Moumusic&Date)
