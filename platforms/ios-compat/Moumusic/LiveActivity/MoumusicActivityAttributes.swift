import ActivityKit
import Foundation

/// 锁屏 / 灵动岛播放器的数据模型；App 与 Live Activity 扩展共用。
struct MoumusicActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var isPlaying: Bool
        /// 播放中：用于 ProgressView(timerInterval:) 自动走时。
        var startDate: Date
        var endDate: Date
        /// 暂停时的静态进度。
        var elapsed: Double
        var duration: Double
    }

    var appName: String
}
