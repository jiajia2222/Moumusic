# Moumusic

Moumusic is an open-source music client for iOS and Android. It combines Kumone’s native SwiftUI player experience on iOS with LX Music Mobile’s user-source protocol and Android client. Discovery uses public catalog data; playback is resolved only through sources imported and enabled by the user.

Moumusic does not bundle or distribute third-party source URLs and does not provide NetEase login. Add only sources you are authorized to use and follow the applicable service terms and copyright rules.

## Features

- Import, test, enable, switch and remove LX User API sources
- Kuwo, Kugou, QQ Music, NetEase, Migu and LX aggregate search
- Source-resolved playback, lyrics, artwork, quality and source labels
- Native iOS player, synced lyrics, queue, lock-screen and Control Center controls
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

New and independently authored Moumusic code is licensed under [GPL-3.0](LICENSE). Upstream files retain their original LGPL, Apache and other license obligations; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
