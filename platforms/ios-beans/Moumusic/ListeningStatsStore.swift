import Combine
import Foundation

/// 累计听歌时长与播放次数（资料卡片「听歌时长」、心跳上报共用）。
@MainActor
final class ListeningStatsStore: ObservableObject {
    static let shared = ListeningStatsStore()

    private let durationKey = "beans.playback.listeningDuration.v1"
    private let defaults = UserDefaults.standard

    @Published private(set) var totalSeconds: Double
    @Published private(set) var totalPlayCount: Int = 0

    private var segmentStart: TimeInterval?
    private var bag = Set<AnyCancellable>()
    private var flushTimer: Timer?

    private init() {
        totalSeconds = UserDefaults.standard.double(forKey: durationKey)
    }

    func attach(_ player: PlayerManager) {
        bag.removeAll()
        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in self?.playingChanged(playing) }
            .store(in: &bag)
        player.$playCounts
            .sink { [weak self] counts in self?.totalPlayCount = counts.values.reduce(0, +) }
            .store(in: &bag)
        playingChanged(player.isPlaying)
    }

    private func playingChanged(_ playing: Bool) {
        if playing {
            guard segmentStart == nil else { return }
            segmentStart = ProcessInfo.processInfo.systemUptime
            flushTimer?.invalidate()
            flushTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.flush(continueSegment: true) }
            }
        } else {
            flush(continueSegment: false)
            flushTimer?.invalidate()
            flushTimer = nil
        }
    }

    private func flush(continueSegment: Bool) {
        guard let start = segmentStart else { return }
        let now = ProcessInfo.processInfo.systemUptime
        totalSeconds += max(0, now - start)
        defaults.set(totalSeconds, forKey: durationKey)
        segmentStart = continueSegment ? now : nil
    }

    /// 例如「12小时34分」「45分钟」「30秒」
    var formattedDuration: String {
        let s = Int(totalSeconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h)小时\(m)分" }
        if m > 0 { return "\(m)分钟" }
        return "\(s)秒"
    }
}
