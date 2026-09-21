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
    var vipType: Int { profile?.vipType ?? 0 }

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

    /// Called at launch and after login succeeds.
    func bootstrap() async {
        defer { isBootstrapped = true }
        guard hasAuthCookie else { return }
        refreshCookieIfNeeded()
        do {
            profile = try await NeteaseAPI.userAccount()
        } catch {
            return
        }
        await refreshLibrary()
    }

    func refreshLibrary() async {
        guard let uid = profile?.userId else { return }
        async let playlists = try? NeteaseAPI.userPlaylists(uid: uid)
        async let liked = try? NeteaseAPI.likedTrackIDs(uid: uid)
        userPlaylists = await playlists ?? userPlaylists
        if let ids = await liked { likedTrackIDs = Set(ids) }
        await syncImportedPlaylistCopies()
        lastPlaylistSyncAt = .now
    }

    /// Refresh account-owned cloud playlists when the app comes back to the
    /// foreground. This never imports every remote playlist automatically:
    /// only copies explicitly selected by the user are updated.
    func refreshForOpen(force: Bool = false) async {
        guard hasAuthCookie else { return }
        let now = Date()
        if !force,
           let last = lastPlaylistSyncAt,
           now.timeIntervalSince(last) < 20 {
            return
        }
        if profile == nil {
            await bootstrap()
            return
        }
        refreshCookieIfNeeded()
        await refreshLibrary()
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

    func logout() async {
        await NeteaseAPI.logout()
        profile = nil
        likedTrackIDs = []
        userPlaylists = []
        likedAlbums = []
        likedArtists = []
        isBootstrapped = true
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

    private init() {
        let defaults = UserDefaults.standard
        syncedSeconds = defaults.integer(forKey: "account.sync.syncedSeconds")
        syncedTrackCount = defaults.integer(forKey: "account.sync.syncedTrackCount")
        lastSyncedAt = defaults.object(forKey: "account.sync.lastSyncedAt") as? Date
    }

    func record(seconds: Int) {
        guard seconds > 0 else { return }
        syncedSeconds += seconds
        syncedTrackCount += 1
        lastSyncedAt = .now
        let defaults = UserDefaults.standard
        defaults.set(syncedSeconds, forKey: "account.sync.syncedSeconds")
        defaults.set(syncedTrackCount, forKey: "account.sync.syncedTrackCount")
        defaults.set(lastSyncedAt, forKey: "account.sync.lastSyncedAt")
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
