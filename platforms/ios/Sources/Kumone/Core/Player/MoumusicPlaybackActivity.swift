#if os(iOS)
import ActivityKit
import CryptoKit
import Foundation

/// Shared by the app and the WidgetKit extension so ActivityKit sees the
/// same attributes type on both sides of the Live Activity.
@available(iOS 16.1, *)
public struct MoumusicPlaybackActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var artist: String
        public var artworkURL: String?
        /// The lyric line currently closest to the playback position. This is
        /// kept in the activity state instead of trying to make the widget
        /// query the app, because the widget extension has its own process.
        public var currentLyric: String?
        public var elapsed: TimeInterval
        public var duration: TimeInterval
        public var isPlaying: Bool
        public var updatedAt: Date

        public init(
            title: String,
            artist: String,
            artworkURL: String?,
            currentLyric: String? = nil,
            elapsed: TimeInterval,
            duration: TimeInterval,
            isPlaying: Bool,
            updatedAt: Date = .now
        ) {
            self.title = title
            self.artist = artist
            self.artworkURL = artworkURL
            self.currentLyric = currentLyric
            self.elapsed = max(0, elapsed)
            self.duration = max(0, duration)
            self.isPlaying = isPlaying
            self.updatedAt = updatedAt
        }

        // Keep activities created by an older Moumusic build readable after
        // the lyric field is added. ActivityKit may restore those activities
        // after an app update.
        private enum CodingKeys: String, CodingKey {
            case title, artist, artworkURL, currentLyric, elapsed, duration
            case isPlaying, updatedAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            artist = try container.decode(String.self, forKey: .artist)
            artworkURL = try container.decodeIfPresent(String.self, forKey: .artworkURL)
            currentLyric = try container.decodeIfPresent(String.self, forKey: .currentLyric)
            elapsed = max(0, try container.decode(TimeInterval.self, forKey: .elapsed))
            duration = max(0, try container.decode(TimeInterval.self, forKey: .duration))
            isPlaying = try container.decode(Bool.self, forKey: .isPlaying)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try container.encode(artist, forKey: .artist)
            try container.encodeIfPresent(artworkURL, forKey: .artworkURL)
            try container.encodeIfPresent(currentLyric, forKey: .currentLyric)
            try container.encode(elapsed, forKey: .elapsed)
            try container.encode(duration, forKey: .duration)
            try container.encode(isPlaying, forKey: .isPlaying)
            try container.encode(updatedAt, forKey: .updatedAt)
        }
    }

    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

/// Stores Live Activity artwork in the App Group shared by the app and the
/// WidgetKit extension. A widget should not depend on a remote image request
/// while the phone is locked or when the source URL needs a special header.
@available(iOS 16.1, *)
public enum MoumusicSharedArtworkStore {
    public static let appGroupIdentifier = "group.com.jiajia2222.moumusic"

    private static let directoryName = "LiveActivityArtwork"

    /// Returns a local shared file URL when the artwork has already been
    /// cached. This is intentionally synchronous so the widget can render it
    /// during a timeline/Live Activity snapshot without starting a request.
    public static func cachedURL(for artworkURL: String?) -> URL? {
        guard let source = normalizedSource(artworkURL) else { return nil }
        if source.isFileURL {
            return FileManager.default.fileExists(atPath: source.path) ? source : nil
        }
        guard let directory = artworkDirectory(create: false) else { return nil }
        let target = directory.appendingPathComponent(fileName(for: source), isDirectory: false)
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    public static func cachedURLString(for artworkURL: String?) -> String? {
        cachedURL(for: artworkURL)?.absoluteString
    }

    /// Normalizes HTTP covers to HTTPS for the temporary network fallback
    /// used before the shared file has finished downloading.
    public static func normalizedURLString(for artworkURL: String?) -> String? {
        normalizedSource(artworkURL)?.absoluteString
    }

    /// Downloads one cover into the shared container. Failures are swallowed:
    /// the player and the Live Activity must continue working with a
    /// placeholder or the original URL.
    public static func cache(artworkURL: String?) async -> String? {
        guard let source = normalizedSource(artworkURL) else { return nil }
        if let cached = cachedURL(for: source.absoluteString) {
            return cached.absoluteString
        }
        guard let directory = artworkDirectory(create: true) else { return nil }
        let target = directory.appendingPathComponent(fileName(for: source), isDirectory: false)

        var request = URLRequest(url: source)
        request.timeoutInterval = 12
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard !data.isEmpty else { return nil }
            try data.write(to: target, options: .atomic)
            // Live Activities can be visible on the lock screen before the
            // first unlock after a reboot, so do not use complete file
            // protection for this non-sensitive cover image.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.none],
                ofItemAtPath: target.path
            )
            return target.absoluteString
        } catch {
            return nil
        }
    }

    private static func normalizedSource(_ artworkURL: String?) -> URL? {
        guard let raw = artworkURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard let url = URL(string: raw) else { return nil }
        if url.isFileURL { return url }
        guard url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" else {
            return nil
        }
        // Most music cover hosts expose the same resource over HTTPS. This
        // also avoids an App Transport Security failure in the widget.
        if url.scheme?.lowercased() == "http" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            return components?.url ?? url
        }
        return url
    }

    private static func artworkDirectory(create: Bool) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        let directory = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory
    }

    private static func fileName(for source: URL) -> String {
        let digest = SHA256.hash(data: Data(source.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).image"
    }
}

/// Keeps one now-playing Live Activity in sync with the audio player.
/// Dynamic Island expansion/compaction is controlled by iOS; the app only
/// supplies the playback state and does not need to fake an animation.
@available(iOS 16.2, *)
@MainActor
final class MoumusicPlaybackActivityManager {
    static let shared = MoumusicPlaybackActivityManager()

    private var activity: Activity<MoumusicPlaybackActivityAttributes>?
    private var sessionID = UUID().uuidString
    private var lastState: MoumusicPlaybackActivityAttributes.ContentState?
    private var artworkSourceURL: String?
    private var artworkTask: Task<String?, Never>?

    private init() {}

    func synchronize(
        title: String,
        artist: String,
        artworkURL: String?,
        currentLyric: String? = nil,
        elapsed: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        newTrack: Bool = false
    ) {
        if newTrack {
            sessionID = UUID().uuidString
            artworkSourceURL = nil
            artworkTask?.cancel()
            artworkTask = nil
        }

        let localArtworkURL = MoumusicSharedArtworkStore.cachedURLString(for: artworkURL)
        let normalizedArtworkURL = MoumusicSharedArtworkStore.normalizedURLString(for: artworkURL)
        let state = MoumusicPlaybackActivityAttributes.ContentState(
            title: title,
            artist: artist,
            artworkURL: localArtworkURL ?? normalizedArtworkURL ?? artworkURL,
            currentLyric: currentLyric,
            elapsed: elapsed,
            duration: duration,
            isPlaying: isPlaying
        )
        lastState = state

        Task { [weak self] in
            guard let self else { return }
            await self.upsert(state)
        }

        // Cache once per track rather than starting a download on every
        // progress update. When it completes, re-use the latest state so a
        // slow image request cannot roll the Live Activity back to an older
        // lyric or playback position.
        guard let artworkURL,
              localArtworkURL == nil,
              artworkSourceURL != artworkURL else { return }
        artworkSourceURL = artworkURL
        let task = Task { await MoumusicSharedArtworkStore.cache(artworkURL: artworkURL) }
        artworkTask = task
        Task { [weak self] in
            guard let cachedURL = await task.value else { return }
            await self?.publishCachedArtwork(cachedURL, sourceURL: artworkURL)
        }
    }

    func end() {
        Task { [weak self] in
            guard let self else { return }
            await self.finish()
        }
    }

    private func upsert(_ state: MoumusicPlaybackActivityAttributes.ContentState) async {
        if activity == nil {
            activity = Activity<MoumusicPlaybackActivityAttributes>.activities.first
        }

        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            await activity.update(content)
            return
        }

        do {
            activity = try Activity.request(
                attributes: MoumusicPlaybackActivityAttributes(sessionID: sessionID),
                content: content,
                pushType: nil
            )
        } catch {
            // Live Activities are optional. A rejected request must never
            // interrupt ordinary audio playback.
            #if DEBUG
            print("Moumusic Live Activity unavailable: \(error)")
            #endif
        }
    }

    private func publishCachedArtwork(_ cachedURL: String, sourceURL: String) async {
        guard artworkSourceURL == sourceURL,
              var latestState = lastState else { return }
        latestState.artworkURL = cachedURL
        lastState = latestState
        await upsert(latestState)
    }

    private func finish() async {
        artworkTask?.cancel()
        artworkTask = nil
        artworkSourceURL = nil
        guard let activity else { return }
        let finalState = lastState ?? MoumusicPlaybackActivityAttributes.ContentState(
            title: "Moumusic",
            artist: "",
            artworkURL: nil,
            currentLyric: nil,
            elapsed: 0,
            duration: 0,
            isPlaying: false
        )
        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .immediate
        )
        self.activity = nil
        self.lastState = nil
    }
}
#endif
