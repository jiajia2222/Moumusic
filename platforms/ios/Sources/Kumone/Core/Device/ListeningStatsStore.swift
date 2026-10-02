#if os(iOS)
import Combine
import Foundation

/// 累计听歌时长与播放次数（资料卡片「听歌时长」、心跳上报共用）。
@MainActor
final class ListeningStatsStore: ObservableObject {
    static let shared = ListeningStatsStore()

    private let durationKey = "beans.playback.listeningDuration.v1"
    private let defaults = UserDefaults.standard

    @Published private(set) var totalSeconds: Double
    private let playCountKey = "moumusic.listening.playCount.v1"
    @Published private(set) var totalPlayCount: Int

    private let dailyKey = "moumusic.listening.daily.v1"
    /// 每天的听歌秒数（yyyyMMdd → 秒），保留最近 60 天。
    @Published private(set) var daily: [String: Double] = [:]

    private var segmentStart: TimeInterval?
    private var bag = Set<AnyCancellable>()
    private var flushTimer: Timer?

    private init() {
        totalSeconds = UserDefaults.standard.double(forKey: durationKey)
        totalPlayCount = UserDefaults.standard.integer(forKey: "moumusic.listening.playCount.v1")
        if let data = UserDefaults.standard.data(forKey: "moumusic.listening.daily.v1"),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            daily = decoded
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func addToday(_ seconds: Double) {
        guard seconds > 0 else { return }
        let key = Self.dayKey(Date())
        daily[key, default: 0] += seconds
        if daily.count > 60 {
            for old in daily.keys.sorted().prefix(daily.count - 60) { daily[old] = nil }
        }
        if let data = try? JSONEncoder().encode(daily) {
            defaults.set(data, forKey: dailyKey)
        }
    }

    /// 最近 7 天（含今天）的听歌分钟数与星期标签，旧 → 新。
    func lastSevenDays() -> [(label: String, minutes: Double)] {
        let cal = Calendar.current
        let symbols = ["日", "一", "二", "三", "四", "五", "六"]
        return (0..<7).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let weekday = cal.component(.weekday, from: date) - 1
            return (symbols[weekday], (daily[Self.dayKey(date)] ?? 0) / 60)
        }
    }

    /// 连续听歌天数（今天没听则从昨天往回算）。
    var streakDays: Int {
        let cal = Calendar.current
        var count = 0
        var day = Date()
        if (daily[Self.dayKey(day)] ?? 0) < 60 { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        while (daily[Self.dayKey(day)] ?? 0) >= 60 {
            count += 1
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return count
    }

    func attach(_ player: PlayerService) {
        bag.removeAll()
        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in self?.playingChanged(playing) }
            .store(in: &bag)
        player.$currentTrack
            .compactMap { $0?.playbackKey }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.countPlay() }
            .store(in: &bag)
        playingChanged(player.isPlaying)
    }

    private func countPlay() {
        totalPlayCount += 1
        defaults.set(totalPlayCount, forKey: playCountKey)
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
        let delta = max(0, now - start)
        totalSeconds += delta
        addToday(delta)
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
#endif
