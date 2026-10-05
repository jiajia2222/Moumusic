# Third-party notices

Moumusic's new code is licensed as declared per file under LGPL-3.0-only or
GPL-3.0-only. The licenses below continue to apply to upstream code and
assets; the project licenses do not replace those file-level obligations.

## Kumone

- Upstream: https://github.com/missuo/kumone
- License: LGPL-3.0-only
- Location: `platforms/ios`
- Moumusic retains Kumone's native SwiftUI player, lyrics, settings and iOS Liquid Glass adaptation, with project-specific LX integration added separately.

## LX Music Mobile

- Upstream: https://github.com/lyswhut/lx-music-mobile
- License: Apache-2.0
- Location: `platforms/android`
- Android retains the original React Native client and User API/QuickJS implementation. The iOS LX User API bridge is documented as project-specific integration.

Moumusic does not bundle or distribute third-party source scripts or provider
URLs. Users are responsible for imported sources and must follow applicable
service terms, copyright rules and upstream licenses.


## Cilicili

- Upstream reference: https://github.com/Rone89/cilicili
- License: GPL-3.0-only
- Use in Moumusic: public Bilibili feature and API-flow reference for video search,
  recommendation clients, dynamic feed, live browsing, subtitles, danmaku,
  comments and playback controls. Moumusic's current Swift implementation is
  independently written; no Cilicili source files are bundled.

## Beans-Music

- Upstream: https://github.com/XIaodou0416/Beans-Music
- License: MIT
- Use in Moumusic: feature and UX reference only. The wallpaper persistence,
  ambient background and playback-speed behavior were implemented in
  Moumusic's own code; Beans-Music provider login, bundled providers and
  authentication code are not included.

## Apple Music-like Lyrics (AMLL) core

- Project: https://github.com/amll-dev/applemusic-like-lyrics (`@applemusic-like-lyrics/core` 0.6.0)
- Licence: **GNU Affero General Public License v3.0 only** (full text: `LICENSES/AGPL-3.0-AMLL.txt`)
- Where it is used: `platforms/ios/Sources/Kumone/AMLLLyricsPage.html` embeds the AMLL player (minified); the corresponding
  source is the upstream project at the version above plus `platforms/ios/Tools/amll/entry.js` and `build.mjs` in this
  repository. The "AMLL 原版" lyric style (`AMLLWebLyricsView.swift`) loads that page.

This repository's own code stays under the licence in `LICENSE` (LGPL-3.0). The AMLL component, and the parts of the
app that are combined with it, are also made available under AGPL-3.0: the complete source of the app is public in this
repository, which is how the AGPL's source requirement is met for every distributed build.

## AMLL TTML DB (community lyrics)

- Project: https://github.com/amll-dev/amll-ttml-db
- Licence: CC0 1.0 (contributors' lyric timing data). The app downloads individual lyric files at runtime.
