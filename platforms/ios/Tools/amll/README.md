# AMLL lyric page

`Sources/Kumone/AMLLLyricsPage.html` is a single self-contained page: the original Apple Music-like Lyrics core
(`@applemusic-like-lyrics/core` 0.6.0, AGPL-3.0-only) bundled with the small bridge in `entry.js`. The app loads it in a
`WKWebView` (`Features/Player/AMLLWebLyricsView.swift`).

Rebuild after changing `entry.js` or upgrading the core (use a short path on Windows):

```bash
npm install --ignore-scripts
node build.mjs          # writes AMLLLyricsPage.html next to build.mjs
# copy it to platforms/ios/Sources/Kumone/AMLLLyricsPage.html
```

See `/THIRD_PARTY_NOTICES.md` for the licence terms.
