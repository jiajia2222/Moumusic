import Foundation

/// Account state used for optional metadata synchronisation.
///
/// This store never supplies an audio URL. Online playback on iOS remains
/// exclusively the responsibility of the selected LX User API source. The
/// account is only used for profile data, daily recommendations, play records,
/// and listening-duration synchronisation.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published var profile: UserProfile?
    @Published var likedTrackIDs: Set<Int> = []
    @Published var userPlaylists: [PlaylistSummary] = []
    @Published var likedAlbums: [AlbumSummary] = []
    @Published var likedArtists: [ArtistSummary] = []
    @Published var isBootstrapped = false
    @Published private(set) var isSyncingPlaylists = false
    @Published private(set) var lastPlaylistSyncAt: Date?
    @Published private(set) var lastPlaylistSyncError: String?

    struct PlaylistSyncReport: Equatable {
        let inserted: Int
        let updated: Int
        let unchanged: Int
        let failed: [String]

        var changedCount: Int { inserted + updated }
    }

    var isLoggedIn: Bool { NeteaseClient.shared.isLoggedIn && profile != nil }
    var hasAuthCookie: Bool { NeteaseClient.shared.isLoggedIn }
    /// Profile `vipType`, raised to a VIP value when the membership endpoint says it is active
    /// (the profile field is 0 for some SVIP accounts, which blocked VIP songs).
    var vipType: Int { max(profile?.vipType ?? 0, (vipInfo?.isActive ?? false) ? 11 : 0) }
    var vipStatusKnown: Bool { profile != nil }
    @Published private(set) var vipInfo: NeteaseAPI.VIPInfo?
    var hasActiveVIP: Bool { (profile?.hasActiveVIP ?? false) || (vipInfo?.isActive ?? false) }
    /// "黑胶 SVIP" / "黑胶 VIP" / "会员" when active, nil otherwise.
    var vipLabel: String? {
        if let label = vipInfo?.label { return label }
        return hasActiveVIP ? "会员" : nil
    }

    var likedSongsPlaylist: PlaylistSummary? {
        userPlaylists.first(where: \.isLikedSongsList) ?? userPlaylists.first
    }

    var createdPlaylists: [PlaylistSummary] {
        guard let uid = profile?.userId else { return [] }
        return userPlaylists.filter { $0.creator?.userId == uid && !$0.isLikedSongsList }
    }

    var subscribedPlaylists: [PlaylistSummary] {
        guard let uid = profile?.userId else { return [] }
        return userPlaylists.filter { $0.creator?.userId != uid }
    }

    private init() {}

    /// Membership is fetched after the profile; make sure it is known before premium tiers are
    /// requested or probed, otherwise a VIP account is treated as free and only sees basic tiers.
    func ensureVIPInfo() async {
        guard hasAuthCookie, vipInfo == nil else { return }
        vipInfo = await NeteaseAPI.vipInfo()
    }

    /// Called at launch and after login succeeds.
    func bootstrap() async {
        defer { isBootstrapped = true }
        guard hasAuthCookie else {
            profile = nil
            ListeningSyncStore.shared.markSignedOut()
            return
        }
        refreshCookieIfNeeded()
        do {
            profile = try await NeteaseAPI.userAccount()
        } catch {
            profile = nil
            ListeningSyncStore.shared.markSignedOut()
            return
        }
        guard let profile else {
            ListeningSyncStore.shared.markSignedOut()
            return
        }
        vipInfo = await NeteaseAPI.vipInfo()
        await refreshLibrary()
        await ListeningSyncStore.shared.refreshRemoteRecords(uid: profile.userId)
    }

    func refreshLibrary() async {
        guard let uid = profile?.userId else { return }
        lastPlaylistSyncError = nil
        async let playlists = try? NeteaseAPI.userPlaylists(uid: uid)
        async let liked = try? NeteaseAPI.likedTrackIDs(uid: uid)
        let fetchedPlaylists = await playlists
        let fetchedLiked = await liked

        if let fetchedPlaylists {
            userPlaylists = fetchedPlaylists
        } else {
            lastPlaylistSyncError = "云端歌单暂时无法获取，稍后可重试。"
        }
        if let fetchedLiked {
            likedTrackIDs = Set(fetchedLiked)
        }

        // Do not show a successful sync timestamp when the playlist request
        // failed and the screen is still displaying stale cached data.
        if fetchedPlaylists != nil {
            await syncImportedPlaylistCopies()
            lastPlaylistSyncAt = .now
        }
    }

    /// Refresh account-owned cloud playlists when the app comes back to the
    /// foreground. This never imports every remote playlist automatically:
    /// only copies explicitly selected by the user are updated.
    func refreshForOpen(force: Bool = false) async {
        guard hasAuthCookie else {
            profile = nil
            ListeningSyncStore.shared.markSignedOut()
            return
        }
        let now = Date()
        if !force,
           let last = lastPlaylistSyncAt,
           now.timeIntervalSince(last) < 20 {
            // Playlist metadata is throttled, but the recent-play list is the
            // user's listening history and should still refresh when the
            // account/profile page is reopened.
            if let uid = profile?.userId {
                await ListeningSyncStore.shared.refreshRemoteRecords(uid: uid)
            }
            return
        }
        if profile == nil {
            await bootstrap()
            return
        }
        refreshCookieIfNeeded()
        await refreshLibrary()
        if let uid = profile?.userId {
            await ListeningSyncStore.shared.refreshRemoteRecords(uid: uid)
        }
    }

    /// Imports the selected cloud playlists into the app's local playlist
    /// page. The remote provider and ID are stored so later foreground opens
    /// can update the same local copy instead of creating duplicates.
    func importSelectedPlaylists(_ ids: Set<Int>) async -> PlaylistSyncReport {
        guard isLoggedIn else {
            return PlaylistSyncReport(inserted: 0, updated: 0, unchanged: 0,
                                      failed: ["请先登录网易云音乐"])
        }
        let selected = userPlaylists.filter { ids.contains($0.id) }
        return await syncPlaylists(selected, force: true)
    }

    func refreshSublists() async {
        async let albums = try? NeteaseAPI.likedAlbums()
        async let artists = try? NeteaseAPI.likedArtists()
        likedAlbums = await albums ?? likedAlbums
        likedArtists = await artists ?? likedArtists
    }

    func isLiked(_ trackID: Int) -> Bool {
        likedTrackIDs.contains(trackID)
    }

    func toggleLike(trackID: Int) async {
        guard isLoggedIn else {
            ToastCenter.shared.show("登录后即可收藏歌曲")
            return
        }
        let like = !likedTrackIDs.contains(trackID)
        if like { likedTrackIDs.insert(trackID) } else { likedTrackIDs.remove(trackID) }
        do {
            try await NeteaseAPI.likeTrack(id: trackID, like: like)
        } catch {
            if like { likedTrackIDs.remove(trackID) } else { likedTrackIDs.insert(trackID) }
            ToastCenter.shared.show(error.localizedDescription)
        }
        NowPlayingManager.shared.refreshLikeState()
    }

    /// Automatically mirrors newly added NetEase tracks to the account's
    /// official liked-songs playlist. Success is intentionally silent so
    /// adding a track remains a single action without another sync button.
    @discardableResult
    func syncAddedTracksToOfficialPlaylist(
        _ tracks: [Track],
        localPlaylistID: UUID
    ) async -> Int {
        guard isLoggedIn,
              let localPlaylist = LocalPlaylistStore.shared.playlist(id: localPlaylistID) else {
            return 0
        }
        var playlistID = officialPlaylistID(for: localPlaylist)
        if playlistID == nil {
            await refreshLibrary()
            playlistID = officialPlaylistID(for: localPlaylist)
        }
        guard let playlistID else { return 0 }

        let ids = tracks.compactMap(neteaseTrackID(for:))
        guard !ids.isEmpty else { return 0 }

        do {
            for chunkStart in stride(from: 0, to: ids.count, by: 100) {
                let chunk = Array(ids.dropFirst(chunkStart).prefix(100))
                try await NeteaseAPI.playlistTracks(
                    op: "add",
                    playlistID: playlistID,
                    trackIDs: chunk
                )
            }
            return ids.count
        } catch {
            ToastCenter.shared.show("本地已保存，网易云官方歌单同步失败")
            return 0
        }
    }

    /// Full sync exposed from a playlist's long-press menu.
    func syncLocalPlaylistToOfficialPlaylist(localPlaylistID: UUID) async {
        guard isLoggedIn else {
            ToastCenter.shared.show("登录网易云后才能同步官方歌单")
            return
        }
        guard let localPlaylist = LocalPlaylistStore.shared.playlist(id: localPlaylistID) else {
            return
        }
        var playlistID = officialPlaylistID(for: localPlaylist)
        if playlistID == nil {
            await refreshLibrary()
            playlistID = officialPlaylistID(for: localPlaylist)
        }
        guard let playlistID else {
            ToastCenter.shared.show("网易云官方歌单暂时无法获取")
            return
        }

        let ids = localPlaylist.tracks.compactMap(neteaseTrackID(for:))
        guard !ids.isEmpty else {
            ToastCenter.shared.show("当前歌单没有可同步的网易云歌曲")
            return
        }

        do {
            for chunkStart in stride(from: 0, to: ids.count, by: 100) {
                let chunk = Array(ids.dropFirst(chunkStart).prefix(100))
                try await NeteaseAPI.playlistTracks(
                    op: "add",
                    playlistID: playlistID,
                    trackIDs: chunk
                )
            }
            ToastCenter.shared.show("已同步 \(ids.count) 首歌曲到网易云官方歌单")
        } catch {
            ToastCenter.shared.show("官方歌单同步失败，歌曲仍保存在本地")
        }
    }

    private func officialPlaylistID(for localPlaylist: LocalPlaylist) -> Int? {
        if localPlaylist.remoteSource == "netease",
           let remoteID = localPlaylist.remotePlaylistID,
           let playlistID = Int(remoteID) {
            return playlistID
        }
        return userPlaylists.first(where: \.isLikedSongsList)?.id
    }

    private func neteaseTrackID(for track: Track) -> Int? {
        let normalized = track.normalizedForLXPlayback()
        let source = (normalized.source ?? normalized.sourceMetadata["source"] ?? "wy").lowercased()
        guard source == "wy" || source == "netease" || source == "163" else { return nil }
        return Int(normalized.sourceMetadata["songmid"]
            ?? normalized.sourceMetadata["id"]
            ?? String(normalized.id))
    }

    func logout() async {
        await NeteaseAPI.logout()
        profile = nil
        likedTrackIDs = []
        userPlaylists = []
        likedAlbums = []
        likedArtists = []
        isBootstrapped = true
        ListeningSyncStore.shared.markSignedOut()
    }

    private func syncImportedPlaylistCopies() async {
        let mirrored = LocalPlaylistStore.shared.playlists.filter {
            $0.remoteSource == "netease" && $0.remotePlaylistID != nil
        }
        guard !mirrored.isEmpty else { return }

        let candidates = mirrored.compactMap { local -> PlaylistSummary? in
            guard let rawID = local.remotePlaylistID, let id = Int(rawID) else { return nil }
            return userPlaylists.first { $0.id == id }
        }
        guard !candidates.isEmpty else { return }
        _ = await syncPlaylists(candidates, force: false)
    }

    private func syncPlaylists(
        _ candidates: [PlaylistSummary],
        force: Bool
    ) async -> PlaylistSyncReport {
        guard !candidates.isEmpty else {
            lastPlaylistSyncAt = .now
            return PlaylistSyncReport(inserted: 0, updated: 0, unchanged: 0, failed: [])
        }

        isSyncingPlaylists = true
        lastPlaylistSyncError = nil
        defer {
            isSyncingPlaylists = false
            lastPlaylistSyncAt = .now
        }

        var inserted = 0
        var updated = 0
        var unchanged = 0
        var failed: [String] = []

        for summary in candidates {
            if !force,
               let local = LocalPlaylistStore.shared.playlists.first(where: {
                   $0.remoteSource == "netease"
                       && $0.remotePlaylistID == String(summary.id)
               }),
               summary.updateTime > 0,
               local.remoteRevision == summary.updateTime {
                unchanged += 1
                continue
            }

            do {
                let tracks = try await allTracks(for: summary.id)
                guard !tracks.isEmpty else {
                    failed.append("\(summary.name)：没有可同步的歌曲")
                    continue
                }
                let result = LocalPlaylistStore.shared.upsertRemotePlaylist(
                    source: "netease",
                    remoteID: summary.id,
                    name: summary.name,
                    coverURL: summary.coverURL,
                    sourceName: "网易云",
                    revision: summary.updateTime > 0 ? summary.updateTime : summary.trackCount,
                    tracks: tracks
                )
                if result.inserted { inserted += 1 }
                else if result.changed { updated += 1 }
                else { unchanged += 1 }
            } catch {
                failed.append(summary.name)
            }
        }

        if !failed.isEmpty {
            lastPlaylistSyncError = "部分歌单暂时无法同步"
        }
        return PlaylistSyncReport(
            inserted: inserted,
            updated: updated,
            unchanged: unchanged,
            failed: failed
        )
    }

    private func allTracks(for playlistID: Int) async throws -> [Track] {
        let response = try await NeteaseAPI.playlistDetail(id: playlistID)
        var tracks = response.playlist.tracks
        let allIDs = response.playlist.trackIds.map(\.id)

        if tracks.count < allIDs.count {
            let remaining = Array(allIDs.dropFirst(tracks.count))
            for start in stride(from: 0, to: remaining.count, by: 500) {
                let chunk = Array(remaining.dropFirst(start).prefix(500))
                guard let details = try? await NeteaseAPI.songDetails(ids: chunk) else { continue }
                tracks.append(contentsOf: details.songs)
            }
        }
        return tracks.map { $0.normalizedForLXPlayback() }
    }

    /// Refresh the login cookie at most once per calendar day.
    private func refreshCookieIfNeeded() {
        let key = "auth.lastCookieRefresh"
        let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        guard UserDefaults.standard.double(forKey: key) < today else { return }
        UserDefaults.standard.set(today, forKey: key)
        Task { await NeteaseAPI.refreshLogin() }
    }
}

/// Local, credential-free mirror of the listening sync state shown on the
/// account page.
@MainActor
final class ListeningSyncStore: ObservableObject {
    static let shared = ListeningSyncStore()

    @Published private(set) var syncedSeconds: Int
    @Published private(set) var syncedTrackCount: Int
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastSyncSucceeded: Bool?
    @Published private(set) var recentTracks: [Track] = []
    @Published private(set) var remotePlayCount = 0
    @Published private(set) var remoteRecordsError: String?
    @Published private(set) var isAuthenticated = false

    private init() {
        let defaults = UserDefaults.standard
        syncedSeconds = defaults.integer(forKey: "account.sync.syncedSeconds")
        syncedTrackCount = defaults.integer(forKey: "account.sync.syncedTrackCount")
        lastSyncedAt = defaults.object(forKey: "account.sync.lastSyncedAt") as? Date
        lastSyncSucceeded = defaults.object(forKey: "account.sync.lastSyncSucceeded") as? Bool
    }

    func markSignedOut() {
        isAuthenticated = false
        lastSyncSucceeded = nil
        recentTracks = []
        remotePlayCount = 0
        remoteRecordsError = nil
    }

    func markAuthenticated() {
        isAuthenticated = true
    }

    /// Reads the actual NetEase recent-play list. A read failure must not erase
    /// a successfully submitted local listening interval.
    func refreshRemoteRecords(uid: Int) async {
        guard AccountStore.shared.isLoggedIn else {
            markSignedOut()
            return
        }
        markAuthenticated()
        do {
            let records = try await NeteaseAPI.playRecords(uid: uid, week: true)
            recentTracks = records.map { $0.song.normalizedForLXPlayback() }
            remotePlayCount = records.reduce(0) { $0 + max(0, $1.playCount) }
            remoteRecordsError = nil
        } catch {
            remoteRecordsError = error.localizedDescription
        }
    }

    func record(seconds: Int) {
        guard seconds > 0 else { return }
        guard AccountStore.shared.isLoggedIn else {
            markSignedOut()
            return
        }
        markAuthenticated()
        syncedSeconds += seconds
        syncedTrackCount += 1
        lastSyncedAt = .now
        lastSyncSucceeded = true
        let defaults = UserDefaults.standard
        defaults.set(syncedSeconds, forKey: "account.sync.syncedSeconds")
        defaults.set(syncedTrackCount, forKey: "account.sync.syncedTrackCount")
        defaults.set(lastSyncedAt, forKey: "account.sync.lastSyncedAt")
        defaults.set(true, forKey: "account.sync.lastSyncSucceeded")
    }

    /// Keeps a failed server submission out of the local aggregate. This is
    /// intentionally separate from `record`: the UI must not claim that a
    /// listening interval was synced when NetEase rejected or never received
    /// the weblog request.
    func recordFailure() {
        guard AccountStore.shared.isLoggedIn else {
            markSignedOut()
            return
        }
        markAuthenticated()
        lastSyncSucceeded = false
        UserDefaults.standard.set(false, forKey: "account.sync.lastSyncSucceeded")
    }

    var statusText: String {
        switch lastSyncSucceeded {
        case true: return "已同步"
        case false: return "同步失败"
        case nil: return "待同步"
        }
    }

    var platformStatusText: String {
        guard isAuthenticated else { return "网易云音乐 · 未登录" }
        if remoteRecordsError != nil {
            return "网易云音乐 · 读取失败"
        }
        switch lastSyncSucceeded {
        case true: return "网易云音乐 · 已同步"
        case false: return "网易云音乐 · 同步失败"
        case nil: return "网易云音乐 · 等待同步"
        }
    }

    var formattedDuration: String {
        let hours = syncedSeconds / 3600
        let minutes = (syncedSeconds % 3600) / 60
        if hours > 0 { return "\(hours)小时 \(minutes)分钟" }
        return "\(max(minutes, 1))分钟"
    }
}

// MARK: - Toasts

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published var current: Toast?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String) {
        current = Toast(message: message)
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            current = nil
        }
    }
}
