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

## Beans-Music

- Upstream: https://github.com/XIaodou0416/Beans-Music
- License: MIT
- Use in Moumusic: feature and UX reference only. The wallpaper persistence,
  ambient background and playback-speed behavior were implemented in
  Moumusic's own code; Beans-Music provider login, bundled providers and
  authentication code are not included.
