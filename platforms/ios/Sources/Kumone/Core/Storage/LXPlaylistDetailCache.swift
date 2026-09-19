import Foundation

/// Session cache for LX playlist details.
///
/// A source-owned playlist can take several network requests to resolve. Keep
/// the last successful detail keyed by both platform and source-owned ID so a
/// Kuwo/QQ/Kugou ID can never collide with a NetEase ID.
@MainActor
final class LXPlaylistDetailCache {
    static let shared = LXPlaylistDetailCache()

    struct Entry {
        let detail: LXPlaylistDetail
        let savedAt: Date
    }

    let ttl: TimeInterval = 30 * 60

    private var entries: [String: Entry] = [:]

    private init() {}

    func cached(source: LXCatalogPlatform, id: String) -> Entry? {
        entries[key(source: source, id: id)]
    }

    func save(_ detail: LXPlaylistDetail) {
        entries[key(source: detail.source, id: detail.id)] = Entry(
            detail: detail,
            savedAt: Date()
        )
    }

    func isFresh(_ entry: Entry, now: Date = Date()) -> Bool {
        now.timeIntervalSince(entry.savedAt) < ttl
    }

    private func key(source: LXCatalogPlatform, id: String) -> String {
        "\(source.rawValue)|\(id)"
    }
}
