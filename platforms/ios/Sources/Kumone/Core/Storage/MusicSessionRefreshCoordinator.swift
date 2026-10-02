import Foundation

#if os(iOS)
@MainActor
public final class MusicSessionRefreshCoordinator {
    public static let shared = MusicSessionRefreshCoordinator()

    private let interval: TimeInterval = 12 * 60 * 60
    private let lastRefreshKey = "moumusic.provider-sessions.last-refresh"
    private var isRefreshing = false

    private init() {}

    /// Refreshes only when the last silent check is older than 12 hours.
    /// iOS may suspend arbitrary background network work, so this is invoked
    /// both when the scene becomes active and from any permitted background
    /// refresh entry point in the app shell.
    public func refreshIfNeeded(force: Bool = false) async {
        guard !isRefreshing else { return }
        let last = UserDefaults.standard.double(forKey: lastRefreshKey)
        guard force || last == 0 || Date().timeIntervalSince1970 - last >= interval else { return }

        isRefreshing = true
        defer { isRefreshing = false }
        await QQMusicSessionStore.shared.refreshProfile()
        await KugouSessionStore.shared.refreshProfile()
        await BilibiliSessionStore.shared.refreshProfile()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRefreshKey)
    }
}
#endif
