# Moumusic

<div align="right">[简体中文](README_CN.md) · **English**</div>

[![LGPL-3.0](https://img.shields.io/badge/license-LGPL--3.0-orange)](LICENSE) [![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-orange)](COPYING)

Moumusic is an open-source music client for iOS and Android. It combines Kumone’s native SwiftUI player experience on iOS with LX Music Mobile’s user-source protocol and Android client. Discovery uses public catalog data; playback is resolved only through sources imported and enabled by the user.

Moumusic does not bundle or distribute third-party source URLs and does not provide NetEase login. Add only sources you are authorized to use and follow the applicable service terms and copyright rules.

## Features

- Import, test, enable, switch and remove LX User API sources
- Kuwo, Kugou, QQ Music, NetEase, Migu and LX aggregate search
- Source-resolved playback, lyrics, artwork, quality and source labels
- Native iOS player, synced lyrics, queue, lock-screen and Control Center controls
- iOS WidgetKit lyrics widget for Home Screen and Lock Screen sizes
- Public NetEase recommendations, discovery, playlists, comments and playlist import
- Chinese and English interfaces

## Add a source

On iOS, open “Library → Settings → LX Sources”, choose “Import from File” or “Import from Online URL”, then select and test the source. On Android, use the original LX Music Mobile source-management screen.

## Build

```sh
cd platforms/android
npm ci
npm run pack:android
```

iOS requires macOS and Xcode:

```sh
cd platforms/ios/ios
xcodebuild -project KumoneIOS.xcodeproj -scheme KumoneIOS -configuration Release -sdk iphoneos build
```

## Upstream projects and license

- [Kumone](https://github.com/missuo/kumone)
- [LX Music Mobile](https://github.com/lyswhut/lx-music-mobile)

New Moumusic code is licensed per-file under [LGPL-3.0-only](LICENSE) or [GPL-3.0-only](COPYING). Both complete license texts are included. Upstream files retain their original LGPL, Apache and other obligations; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
