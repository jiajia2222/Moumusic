import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

// Small stand-ins so the Bilibili module (shared in spirit with the iOS 26 build) compiles inside the
// iOS 15–18 app, which has its own player, logger and design system.

/// Log lines go to the app's own log centre.
final class DiagnosticLogStore {
    static let shared = DiagnosticLogStore()
    enum Level { case info, warning, error }

    func append(level: Level, category: String, message: String, detail: String? = nil) {
        let text = "[\(category)] \(message)" + (detail.map { " — \($0)" } ?? "")
        let mapped: BeansLogLevel = level == .error ? .error : (level == .warning ? .warn : .info)
        BeansLogger.shared.log(text, level: mapped)
    }
}

/// Pausing the music app's player when a video starts.
@MainActor
final class PlayerService {
    static let shared = PlayerService()
    var isPlaying: Bool { PlayerManager.shared.isPlaying }
    func pause() {
        if PlayerManager.shared.isPlaying { PlayerManager.shared.togglePlayPause() }
    }
}

/// Lock-screen info while a video plays (remote commands stay with the music player).
@MainActor
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    struct ExternalHandler {
        let play: () -> Void
        let pause: () -> Void
        let toggle: () -> Void
        let seek: (Double) -> Void
        let skip: (Double) -> Void
    }

    private var active = false

    func updateExternal(title: String, artist: String, coverURL: String?, elapsed: Double,
                        duration: Double, rate: Double, handler: ExternalHandler) {
        active = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: "哔哩哔哩",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate
        ]
    }

    func endExternal() {
        guard active else { return }
        active = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

enum Theme {
    static let accent = Color(red: 0.0, green: 0.63, blue: 0.84)
}

enum Formatters {
    static func playCount(_ value: Int) -> String {
        if value >= 100_000_000 { return String(format: "%.1f亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        return "\(value)"
    }
}

enum BilibiliRecommendationSource: String, CaseIterable, Identifiable, Sendable {
    case web
    case app
    var id: String { rawValue }
}

/// Orientation lock the app delegate reads: portrait everywhere except the video full screen.
enum BiliOrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait
}

extension String {
    /// Bilibili image URL with the CDN's width hint; `nil` when the string is not a URL.
    func resizedImageURL(_ width: Int) -> URL? {
        var value = self.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("//") { value = "https:" + value }
        if value.hasPrefix("http://") { value = "https://" + value.dropFirst(7) }
        if value.contains("hdslb.com"), !value.contains("@") { value += "@\(width)w.webp" }
        return URL(string: value)
    }
}

extension NSLock {
    func biliWithLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// AsyncImage with a quiet placeholder (the iOS 15 system loader caches through URLCache).
struct CachedAsyncImage: View {
    let url: URL?
    var animated: Bool = true

    init(url: URL?, animated: Bool = true) {
        self.url = url
        self.animated = animated
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.18)
            }
        }
    }
}

/// App delegate that applies the video orientation lock (the app is portrait-only otherwise).
final class MoumusicAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        BiliOrientationLock.mask
    }
}
