#if DEBUG && os(iOS)
import Foundation

/// Simulator-only test hook (compiled out of Release builds). Launch arguments:
///   -moumusic.debugSourceURL <url>     import this LX source script and select it
///   -moumusic.debugPlay tx,kg,kw,mg,wy play one recommended song per platform, in that order
///   -moumusic.debugQuality master      quality to request (AudioQuality raw value)
/// Results go to Documents/debug-result.txt; the app's own diagnostic log has the per-song detail.
@MainActor
enum DebugHarness {
    static func runIfRequested() async {
        let defaults = UserDefaults.standard
        var lines: [String] = []
        func note(_ text: String) {
            lines.append(text)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? lines.joined(separator: "\n").write(to: docs.appendingPathComponent("debug-result.txt"),
                                                    atomically: true, encoding: .utf8)
        }

        if let urlText = defaults.string(forKey: "moumusic.debugSourceURL") {
            do {
                try await LXSourceStore.shared.importOnlineScript(urlText)
                if let id = LXSourceStore.shared.sources.last?.id { LXSourceStore.shared.select(id) }
                note("source imported: \(LXSourceStore.shared.sources.last?.name ?? "?")")
            } catch {
                note("source import FAILED: \(error.localizedDescription)")
                return
            }
        }
        guard let platformList = defaults.string(forKey: "moumusic.debugPlay") else { return }
        if let raw = defaults.string(forKey: "moumusic.debugQuality"), let quality = AudioQuality(rawValue: raw) {
            SettingsManager.shared.audioQuality = quality
        }
        let player = PlayerService.shared
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
            player.play(tracks: [track.normalizedForLXPlayback()], source: .none)
            // Wait for the stream to resolve and the quality measurement to land (max 40 s).
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if player.servedQualityTrackKey == player.currentTrack?.playbackKey, player.servedQualityMeasured { break }
            }
            note("\(code): 《\(track.name)》 requested=\(SettingsManager.shared.audioQuality.rawValue) "
                 + "served=\(player.servedQuality ?? "-") measured=\(player.servedQualityMeasured) "
                 + "label=\(player.servedSourceLabel ?? "-") playing=\(player.isPlaying) "
                 + String(format: "%.1fs", Date().timeIntervalSince(started)))
            player.togglePlayPause()
        }
        note("done")
    }
}
#endif
