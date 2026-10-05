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
