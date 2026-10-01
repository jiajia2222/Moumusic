# CiliCili in Moumusic

Copyright: Rone89 and the CiliCili contributors.
Upstream: https://github.com/Rone89/cilicili
Revision: c61b0d33966c5d8e87ea20527b8ba48c702c10c1 (2026-09-15)
License: GNU General Public License version 3 only (GPL-3.0-only); the unmodified license text is in LICENSE-CiliCili.txt.

The upstream Swift source tree under `Sources/` is embedded as the `CiliCiliKit` framework and is only built into
the full-feature (iOS 26+) variant. Moumusic modifications: the `@main` attribute was removed from
`Sources/App/JKBiliApp.swift`, the app icon / launch assets were dropped, and `Bridge/CiliCiliBridge.swift`
was added to host the UI inside Moumusic.
