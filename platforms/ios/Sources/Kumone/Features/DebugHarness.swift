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
