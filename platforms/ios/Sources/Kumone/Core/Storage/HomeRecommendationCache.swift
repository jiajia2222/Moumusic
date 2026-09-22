import Foundation

/// Keeps the last successful homepage snapshot per recommendation source.
///
/// The cache is intentionally in-memory, like Beans Music's DiscoverCache:
/// returning to a tab is instant, while a stale snapshot can be refreshed in
/// the background without replacing the page with a loading skeleton.
@MainActor
final class HomeRecommendationCache {
    static let shared = HomeRecommendationCache()

    struct Key: Hashable {
        let loggedIn: Bool
        let mode: String
        let platform: String
        /// A Qishui Cookie change must not reuse the public-feed snapshot.
        /// Other platforms keep the default value of zero.
        let qishuiSessionRevision: Int
    }

    struct Snapshot {
        let savedAt: Date
        let recommendPlaylists: [PlaylistSummary]
        let radarPlaylists: [HomeViewModel.RadarPlaylist]
        let toplists: [ToplistItem]
        let newAlbums: [AlbumSummary]
        let topArtists: [ArtistSummary]
        let dailyFirstCover: String?
        let recommendTracks: [Track]
        let lxRecommendPlaylists: [LXPlaylistSummary]

        var hasContent: Bool {
            !recommendPlaylists.isEmpty || !toplists.isEmpty || !newAlbums.isEmpty
                || !topArtists.isEmpty || !recommendTracks.isEmpty
                || !lxRecommendPlaylists.isEmpty
        }
    }

    /// Homepage feeds are live, but a short TTL avoids refetching while the
    /// user is moving between tabs. Explicit pull-to-refresh bypasses it.
    let ttl: TimeInterval = 5 * 60

    private var entries: [Key: Snapshot] = [:]

    private init() {}

    func snapshot(for key: Key) -> Snapshot? {
        entries[key]
    }

    func save(_ snapshot: Snapshot, for key: Key) {
        entries[key] = snapshot
    }

    func invalidate(_ key: Key) {
        entries[key] = nil
    }

    func isFresh(_ snapshot: Snapshot, now: Date = Date()) -> Bool {
        now.timeIntervalSince(snapshot.savedAt) < ttl
    }
}
