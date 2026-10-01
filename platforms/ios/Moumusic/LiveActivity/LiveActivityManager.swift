#if !MOUMUSIC_COMPAT
import ActivityKit
import Combine
import Foundation

/// 把当前播放状态同步到锁屏与灵动岛；设置里「显示锁屏与灵动岛播放器」可关闭。
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    static let enabledKey = "beans.showLiveActivity"

    private var activity: Activity<MoumusicActivityAttributes>?
    private var bag = Set<AnyCancellable>()
    private weak var player: PlayerManager?

    private init() {}

    func attach(_ player: PlayerManager) {
        self.player = player
        bag.removeAll()
        let playing = player.$isPlaying.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        let index = player.$currentIndex.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        let queue = player.$queue.map(\.count).removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        Publishers.MergeMany([playing, index, queue])
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] in Task { await self?.refresh() } }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { await self?.refresh() } }
            .store(in: &bag)
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func refresh() async {
        guard let player = player else { return }
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled, let song = player.currentSong else {
            await end()
            return
        }
        let duration = max(player.duration, song.duration, 1)
        let elapsed = min(max(player.progress, 0), duration)
        let now = Date()
        let state = MoumusicActivityAttributes.ContentState(
            title: song.name,
            artist: song.artists,
            isPlaying: player.isPlaying,
            startDate: now.addingTimeInterval(-elapsed),
            endDate: now.addingTimeInterval(duration - elapsed),
            elapsed: elapsed,
            duration: duration
        )
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity = activity {
            await activity.update(content)
        } else {
            activity = try? Activity.request(attributes: MoumusicActivityAttributes(appName: "Moumusic"), content: content, pushType: nil)
        }
    }

    func end() async {
        guard let activity = activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
#endif
