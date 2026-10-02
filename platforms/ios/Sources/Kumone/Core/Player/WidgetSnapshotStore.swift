import Foundation
import WidgetKit

/// Small App Group snapshot shared by the app and the lyrics widget.
@MainActor
enum WidgetSnapshotStore {
    static let suiteName = "group.com.jiajia2222.moumusic"
    private static let trackTitleKey = "widget.track.title"
    private static let artistKey = "widget.track.artist"
    private static let lyricKey = "widget.lyric"
    private static var lastSignature: String?

    static func update(track: Track?, lyric: String?) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let title = track?.name ?? ""
        let artist = track?.artistNames ?? ""
        let displayedLyric = lyric ?? "暂无歌词"
        let signature = [track?.playbackKey ?? "", title, artist, displayedLyric]
            .joined(separator: "\u{1F}")
        // The player clock ticks five times a second, but a widget only needs
        // a reload when its visible content changes. Avoiding duplicate
        // reloads prevents WidgetKit throttling and keeps lyric updates timely.
        guard lastSignature != signature else { return }
        lastSignature = signature
        defaults.set(title, forKey: trackTitleKey)
        defaults.set(artist, forKey: artistKey)
        defaults.set(displayedLyric, forKey: lyricKey)
        defaults.set(Date().timeIntervalSince1970, forKey: "widget.updatedAt")
        WidgetCenter.shared.reloadTimelines(ofKind: "MoumusicLyricsWidget")
    }
}
