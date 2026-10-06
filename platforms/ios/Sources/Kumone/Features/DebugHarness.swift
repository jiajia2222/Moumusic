#if DEBUG && os(iOS)
import Foundation

/// Simulator-only test hook (compiled out of Release builds). Launch arguments:
///   -moumusic.debugSourceURL <url>     import this LX source script and select it
///   -moumusic.debugPlay tx,kg,kw,mg,wy play one recommended song per platform, in that order
///   -moumusic.debugQuality master      quality to request (AudioQuality raw value)
/// Results go to Documents/debug-result.txt; the app's own diagnostic log has the per-song detail.
@MainActor
enum DebugHarness {
    /// Longest gap between two ticks of a 50 ms main-run-loop timer since the last reset: a stalled main
    /// thread (what the user sees as the app freezing) shows up here.
    private static var lastTick = Date()
    private static var maxGap: TimeInterval = 0
    private static var watchdog: Timer?

    private static func startWatchdog() {
        guard watchdog == nil else { return }
        lastTick = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let now = Date()
            maxGap = max(maxGap, now.timeIntervalSince(lastTick))
            lastTick = now
        }
    }

    static func runIfRequested() async {
        let defaults = UserDefaults.standard
        var lines: [String] = []
        func note(_ text: String) {
            lines.append(text)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? lines.joined(separator: "\n").write(to: docs.appendingPathComponent("debug-result.txt"),
                                                    atomically: true, encoding: .utf8)
        }

        // -moumusic.debugSourceURL2 is imported first (a backup source); -moumusic.debugSourceURL last, so it is the
        // selected primary one.
        for key in ["moumusic.debugSourceURL2", "moumusic.debugSourceURL"] {
            guard let urlText = defaults.string(forKey: key) else { continue }
            do {
                let before = Set(LXSourceStore.shared.sources.map(\.id))
                try await LXSourceStore.shared.importOnlineScript(urlText)
                let added = LXSourceStore.shared.sources.first { !before.contains($0.id) }
                if let id = added?.id { LXSourceStore.shared.select(id) }
                note("source imported: \(added?.name ?? "?")")
            } catch {
                note("source import FAILED: \(error.localizedDescription)")
                return
            }
        }
        note("enabled order: " + LXSourceStore.shared.playbackSources.map(\.name).joined(separator: " > "))
        // -moumusic.debugExplore tx,kg,...: drive the Explore view model (load, then pull-to-refresh) per platform and
        // note whether the songs / playlists changed.
        if let exploreList = defaults.string(forKey: "moumusic.debugExplore") {
            let model = ExploreViewModel.shared
            for code in exploreList.split(separator: ",").map(String.init) {
                guard let platform = LXCatalogPlatform(rawValue: code) else { continue }
                model.platform = platform
                await model.refresh()
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                let before = model.tracks.prefix(5).map(\.name)
                let beforeLists = model.officialPlaylists.prefix(3).map(\.name)
                var changes: [String] = []
                for round in 1...3 {
                    await model.refresh()
                    try? await Task.sleep(nanoseconds: 9_000_000_000)
                    let after = model.tracks.prefix(5).map(\.name)
                    changes.append("r\(round):" + (after == before ? "SAME" : "changed") + "(\(model.tracks.count) songs)")
                }
                note("explore \(code): before=\(before.joined(separator: "|")) lists=\(beforeLists.joined(separator: "|")) \(changes.joined(separator: " ")) err=\(model.errorMessage ?? "-")")
            }
            note("explore done")
        }
        // -moumusic.debugPlaylist tx:7100341922,tx:7098812364: open each playlist like the playlist page does.
        if let list = defaults.string(forKey: "moumusic.debugPlaylist") {
            for item in list.split(separator: ",").map(String.init) {
                let parts = item.split(separator: ":").map(String.init)
                guard parts.count == 2, let platform = LXCatalogPlatform(rawValue: parts[0]) else { continue }
                do {
                    let detail = try await LXCatalogService.playlistDetail(source: platform, id: parts[1])
                    note("playlist \(item): OK \(detail.tracks.count) songs, name=\(detail.name), cover=\(detail.coverURL != nil), first=\(detail.tracks.first?.name ?? "-")")
                } catch {
                    note("playlist \(item): FAILED \(error.localizedDescription)")
                }
            }
            note("done")
            return
        }
        // -moumusic.debugDaily YES: the day-stable 每日推荐 of every platform, fetched twice (must match) and for
        // another date (must differ).
        if defaults.bool(forKey: "moumusic.debugDaily") {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
            for platform in [LXCatalogPlatform.wy, .tx, .kg, .kw, .mg] {
                let first = await LXCatalogService.dailyRecommendedTracks(platform: platform)
                let second = await LXCatalogService.dailyRecommendedTracks(platform: platform)
                let other = await LXCatalogService.dailyRecommendedTracks(platform: platform, date: tomorrow)
                let firstIDs = first.map(\.playbackKey), otherIDs = other.map(\.playbackKey)
                let overlap = Set(firstIDs).intersection(otherIDs).count
                note("daily \(platform.rawValue): \(first.count) songs, same-day repeat identical=\(firstIDs == second.map(\.playbackKey)), tomorrow \(other.count) songs with \(overlap) in common, first=\(first.first.map { "\($0.name) - \($0.artistNames)" } ?? "-")")
            }
            // QQ account radar: anonymous here (no login in the simulator), which still proves request and parsing.
            let radar = await QQMusicAPI.shared.dailyRadarSongs(cookie: "", target: 30)
            let parsed = radar.compactMap { LXCatalogService.parseTrack($0, source: .tx) }
            note("qq radar: \(radar.count) rows, \(parsed.count) parsed, first=\(parsed.first.map { "\($0.name) - \($0.artistNames) mid=\($0.sourceMetadata["songmid"] ?? "-")" } ?? "-")")
            note("done")
            return
        }
        // -moumusic.debugTTML YES: the community lyric database: index load, hit and miss, and the parsed words.
        if defaults.bool(forKey: "moumusic.debugTTML") {
            for (label, ncm, qq) in [("晴天", "186016", []), ("海阔天空", "347230", []), ("光年之外", "449818741", []),
                                     ("夜曲(未收录)", "108914", []), ("QQ 祝福", nil, ["000zi9gH0OEMMu"])] as [(String, String?, [String])] {
                let started = Date()
                let result = await AMLLTTMLDatabase.shared.lyrics(neteaseID: ncm, qqIDs: qq)
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                if let result {
                    let words = result.lines.compactMap(\.words).flatMap { $0 }
                    let zero = words.filter { $0.start == 0 }.count
                    note("ttml \(label): HIT \(result.lines.count) lines, \(words.count) words, zero-start words=\(zero), verbatim=\(result.hasVerbatimTimings), first=\(result.lines.first(where: { $0.words != nil })?.text ?? "-") (\(seconds)s)")
                } else {
                    note("ttml \(label): miss (\(seconds)s)")
                }
            }
            note("done")
            return
        }
        // -moumusic.debugVersion YES: community lyrics by title + artist, and the check against the audio length.
        if defaults.bool(forKey: "moumusic.debugVersion") {
            let cases: [(String, [String], TimeInterval)] = [("晴天", ["周杰伦"], 269), ("光年之外", ["G.E.M.邓紫棋"], 235),
                                                            ("Lemon", ["米津玄師"], 255), ("夜曲", ["周杰伦"], 226)]
            // The index loads in the background: lookups just after launch find nothing, so ask again for a while.
            await AMLLTTMLDatabase.shared.prefetch()
            for (title, artists, duration) in cases {
                var found: ParsedLyrics?
                for _ in 0..<40 {
                    found = await AMLLTTMLDatabase.shared.lyrics(neteaseID: nil, qqIDs: [], title: title, artists: artists, duration: duration)
                    if found != nil { break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                if let found {
                    note("db \(title): hit by title+artist, \(found.lines.count) lines, ends at \(Int(found.endTime)) s | fits audio \(Int(duration)) s: \(PlayerService.lyricsFitAudio(found, audio: duration)) | fits a 180 s cut: \(PlayerService.lyricsFitAudio(found, audio: 180))")
                } else {
                    note("db \(title): no hit")
                }
            }
            note("done")
            return
        }
        // -moumusic.debugKugou YES: with the stored Kugou session, run the device registration a few times and then
        // read the account's cloud playlists. Prints counts only (no names, no tokens).
        if defaults.bool(forKey: "moumusic.debugKugou") {
            let store = KugouSessionStore.shared
            note("kugou: loggedIn=\(store.isLoggedIn) cookie=\(store.cookie == nil ? "none" : "present")")
            // Control runs with made-up credentials: does the same request code get a 500 too?
            for (label, fake) in [("fake uid+token", "userid=1603526060; token=" + String(repeating: "x", count: 64)),
                                  ("uid 0, no token", "userid=0; token=")] {
                var outcomes: [String] = []
                for _ in 1...3 {
                    outcomes.append(await KugouAPI.shared.registerDevice(cookie: fake) == nil ? "FAILED" : "dfid ok")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                note("kugou control [\(label)]: \(outcomes.joined(separator: ", "))")
            }
            if let cookie = store.cookie {
                for attempt in 1...4 {
                    let registered = await KugouAPI.shared.registerDevice(cookie: cookie)
                    note("kugou register #\(attempt): \(registered == nil ? "FAILED" : "dfid ok")")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                let withDevice = await store.cookieWithDevice()
                note("kugou cookieWithDevice: \(withDevice?.contains("kugou_api_guid=") == true ? "has own device" : "no device")")
                for (appid, ver, inQuery) in [("1005", "20489", true), ("1005", "20489", false), ("1001", "20489", true),
                                              ("3116", "11040", true), ("1005", "11083", true), ("1005", "20489", true)] {
                    let result = await KugouAPI.shared.probeUserPlaylists(cookie: withDevice ?? cookie, appid: appid, clientver: ver, tokenInQuery: inQuery)
                    note("kugou probe appid=\(appid) ver=\(ver) tokenInQuery=\(inQuery): \(result)")
                }
                do {
                    let lists = try await KugouAPI.shared.userPlaylists(cookie: withDevice ?? cookie)
                    note("kugou userPlaylists: OK \(lists.count) lists, songs per list=\(lists.prefix(8).map(\.count))")
                } catch {
                    note("kugou userPlaylists: FAILED \(error)")
                }
            }
            note("done")
            return
        }
        // -moumusic.debugKeychain YES: can this build store a session in the keychain (an unsigned simulator build
        // cannot, which made web login look like "cookie expired")?
        if defaults.bool(forKey: "moumusic.debugKeychain") {
            do {
                try ProviderSessionSupport.writeCookie("a=b; token=test", service: "com.moumusic.debugtest")
                note("keychain: write OK, read back = \(ProviderSessionSupport.readCookie(service: "com.moumusic.debugtest") ?? "nil")")
                ProviderSessionSupport.deleteCookie(service: "com.moumusic.debugtest")
            } catch {
                note("keychain: write FAILED \(error)")
            }
            note("done")
            return
        }
        // -moumusic.debugNowPlaying vinyl: set the player mode, start a song (catalogue only, no source needed
        // for the lyrics) and open the full player.
        if let modeRaw = defaults.string(forKey: "moumusic.debugNowPlaying") {
            if let mode = NowPlayingMode(rawValue: modeRaw) { SettingsManager.shared.nowPlayingMode = mode }
            let tracks = (try? await LXCatalogService.search("周杰伦 晴天", platform: .tx, limit: 5)) ?? []
            if let track = tracks.first(where: { $0.duration > 90 }) ?? tracks.first {
                PlayerService.shared.play(tracks: [track.normalizedForLXPlayback()], source: .none)
                note("nowplaying: \(track.name)")
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                PlayerService.shared.showNowPlaying = true
            } else {
                note("nowplaying: no track")
            }
            note("done")
            return
        }
        guard let platformList = defaults.string(forKey: "moumusic.debugPlay") else { return }
        if let raw = defaults.string(forKey: "moumusic.debugQuality"), let quality = AudioQuality(rawValue: raw) {
            SettingsManager.shared.audioQuality = quality
        }
        let player = PlayerService.shared
        startWatchdog()
        for code in platformList.split(separator: ",").map(String.init) {
            guard let platform = LXCatalogPlatform(rawValue: code) else { note("\(code): unknown platform"); continue }
            var candidates: [Track]
            if let query = defaults.string(forKey: "moumusic.debugQuery") {
                candidates = (try? await LXCatalogService.search(query, platform: platform, limit: 10)) ?? []
            } else {
                candidates = await LXCatalogService.recommendedContent(platform: platform, limit: 10).tracks
            }
            guard let track = candidates.first(where: { $0.duration > 90 }) ?? candidates.first else {
                note("\(code): no recommended track"); continue
            }
            let started = Date()
            maxGap = 0
            lastTick = Date()
            player.play(tracks: [track.normalizedForLXPlayback()], source: .none)
            // Wait for the stream to resolve and the quality measurement to land (max 40 s).
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if player.servedQualityTrackKey == player.currentTrack?.playbackKey, player.servedQualityMeasured { break }
            }
            note("\(code): 《\(track.name)》 requested=\(SettingsManager.shared.audioQuality.rawValue) "
                 + "served=\(player.servedQuality ?? "-") measured=\(player.servedQualityMeasured) "
                 + "label=\(player.servedSourceLabel ?? "-") playing=\(player.isPlaying) "
                 + String(format: "%.1fs", Date().timeIntervalSince(started))
                 + String(format: " mainThreadMaxStall=%.2fs", maxGap))
            player.togglePlayPause()
        }
        note("done")
    }
}
#endif
