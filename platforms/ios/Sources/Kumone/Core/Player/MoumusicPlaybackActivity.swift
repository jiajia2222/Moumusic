#if os(iOS)
import ActivityKit
import Foundation

/// Shared by the app and the WidgetKit extension so ActivityKit sees the
/// same attributes type on both sides of the Live Activity.
@available(iOS 16.1, *)
public struct MoumusicPlaybackActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var artist: String
        public var artworkURL: String?
        public var elapsed: TimeInterval
        public var duration: TimeInterval
        public var isPlaying: Bool
        public var updatedAt: Date

        public init(
            title: String,
            artist: String,
            artworkURL: String?,
            elapsed: TimeInterval,
            duration: TimeInterval,
            isPlaying: Bool,
            updatedAt: Date = .now
        ) {
            self.title = title
            self.artist = artist
            self.artworkURL = artworkURL
            self.elapsed = max(0, elapsed)
            self.duration = max(0, duration)
            self.isPlaying = isPlaying
            self.updatedAt = updatedAt
        }
    }

    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

/// Keeps one now-playing Live Activity in sync with the audio player.
/// Dynamic Island expansion/compaction is controlled by iOS; the app only
/// supplies the playback state and does not need to fake an animation.
@available(iOS 16.1, *)
@MainActor
final class MoumusicPlaybackActivityManager {
    static let shared = MoumusicPlaybackActivityManager()

    private var activity: Activity<MoumusicPlaybackActivityAttributes>?
    private var sessionID = UUID().uuidString
    private var lastState: MoumusicPlaybackActivityAttributes.ContentState?

    private init() {}

    func synchronize(
        title: String,
        artist: String,
        artworkURL: String?,
        elapsed: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        newTrack: Bool = false
    ) {
        if newTrack {
            sessionID = UUID().uuidString
        }

        let state = MoumusicPlaybackActivityAttributes.ContentState(
            title: title,
            artist: artist,
            artworkURL: artworkURL,
            elapsed: elapsed,
            duration: duration,
            isPlaying: isPlaying
        )
        lastState = state

        Task { [weak self] in
            guard let self else { return }
            await self.upsert(state)
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

    private func finish() async {
        guard let activity else { return }
        let finalState = lastState ?? MoumusicPlaybackActivityAttributes.ContentState(
            title: "Moumusic",
            artist: "",
            artworkURL: nil,
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
