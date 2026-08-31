import Foundation
import WidgetKit

/// Small App Group snapshot shared by the app and the lyrics widget.
enum WidgetSnapshotStore {
    static let suiteName = "group.com.jiajia2222.moumusic"
    private static let trackTitleKey = "widget.track.title"
    private static let artistKey = "widget.track.artist"
    private static let lyricKey = "widget.lyric"

    static func update(track: Track?, lyric: String?) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(track?.name ?? "", forKey: trackTitleKey)
        defaults.set(track?.artistNames ?? "", forKey: artistKey)
        defaults.set(lyric ?? "暂无歌词", forKey: lyricKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "MoumusicLyricsWidget")
    }
}
