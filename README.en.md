# Moumusic

Moumusic is an independent cross-platform music client. iOS uses Kumone’s native SwiftUI interface, while Android uses the native LX Music Mobile client. The app does not bundle third-party providers; users add their own sources.

## Features

- Import, enable, switch and remove LX User API sources
- Aggregate search with platform selection for Kuwo, Kugou, QQ Music, NetEase and Migu
- Playback, lyrics and quality resolution through the user-selected source
- Kumone iOS player, lyrics, queue, lock-screen controls and Liquid Glass-style UI
- Native LX Mobile Android source management, search, lyrics, downloads and playback
- LX aggregate recommendations by default on iOS, with an explicit platform selector in Settings
- Chinese and English UI resources

## Add a source

On iOS, open “Library → Settings → LX Sources → Import LX User API”, choose an LX-exported JSON or raw JavaScript file, then enable it under “Current Source”.

On Android, use the original LX Mobile source-management screen.

This repository does not ship or distribute third-party provider URLs. Only add sources you are authorized to use, and follow the relevant service terms and copyright rules.

## Build

Android:

```powershell
cd platforms/android
npm ci
npm run pack:android
```

iOS requires macOS and Xcode:

```sh
cd platforms/ios/ios
xcodebuild -project KumoneIOS.xcodeproj -scheme KumoneIOS -configuration Release -sdk iphoneos build
```

The unsigned IPA must be installed with your own signing certificate, AltStore, TrollStore or another sideloading tool.

## Upstream projects and licensing

- [Kumone](https://github.com/missuo/kumone)
- [LX Music Mobile](https://github.com/lyswhut/lx-music-mobile)

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for source and license notices.
