import Foundation
import Combine

enum FavoriteCollectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case playlist
    case album

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .playlist: return "歌单"
        case .album: return "专辑"
        }
    }
}

/// Local collection bookmarks are intentionally independent from provider
/// subscriptions. This keeps an imported LX playlist or a QQ/KuGou album
/// usable even when the user is not logged in to that provider.
struct FavoriteCollection: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let kind: FavoriteCollectionKind
    let source: String
    let providerID: String
    var name: String
    var coverURL: String?
    var subtitle: String?
    var updatedAt: Date

    init(kind: FavoriteCollectionKind, source: String, providerID: String,
         name: String, coverURL: String? = nil, subtitle: String? = nil,
         updatedAt: Date = .now) {
        self.kind = kind
        self.source = source
        self.providerID = providerID
        self.id = FavoritesStore.key(kind: kind, source: source, providerID: providerID)
        self.name = name
        self.coverURL = coverURL
        self.subtitle = subtitle
        self.updatedAt = updatedAt
    }
}

@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var items: [FavoriteCollection]
    /// Track likes are deliberately local.  Provider account likes are still
    /// exposed by AccountStore, but pressing the heart in the player must work
    /// for every LX source without requiring a provider login.
    @Published private(set) var tracks: [Track]

    private let storageKey = "moumusic.favoriteCollections.v1"
    private let trackStorageKey = "moumusic.favoriteTracks.v1"

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? decoder.decode([FavoriteCollection].self, from: data) {
            items = saved.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            items = []
        }

        if let data = UserDefaults.standard.data(forKey: trackStorageKey),
           let saved = try? decoder.decode([Track].self, from: data) {
            tracks = saved
        } else {
            tracks = []
        }
    }

    nonisolated static func key(kind: FavoriteCollectionKind, source: String, providerID: String) -> String {
        "\(kind.rawValue)|\(source)|\(providerID)"
    }

    func contains(kind: FavoriteCollectionKind, source: String, providerID: String) -> Bool {
        items.contains { $0.id == Self.key(kind: kind, source: source, providerID: providerID) }
    }

    func contains(_ track: Track) -> Bool {
        tracks.contains { $0.playbackKey == track.playbackKey }
    }

    /// Toggles a source-aware local favorite and returns its new state.
    @discardableResult
    func toggle(_ track: Track) -> Bool {
        if let index = tracks.firstIndex(where: { $0.playbackKey == track.playbackKey }) {
            tracks.remove(at: index)
            persistTracks()
            return false
        }

        tracks.insert(track, at: 0)
        persistTracks()
        return true
    }

    /// Used by the backup importer.  De-duplicate by playbackKey so an older
    /// backup cannot create repeated rows after a newer local favorite exists.
    func replaceTracks(_ newTracks: [Track]) {
        var seen = Set<String>()
        tracks = newTracks.filter { seen.insert($0.playbackKey).inserted }
        persistTracks()
    }

    func replaceCollections(_ newItems: [FavoriteCollection]) {
        items = newItems.sorted { $0.updatedAt > $1.updatedAt }
        persistCollections()
    }

    /// Toggles a bookmark and returns the new state.
    @discardableResult
    func toggle(kind: FavoriteCollectionKind, source: String, providerID: String,
                name: String, coverURL: String? = nil, subtitle: String? = nil) -> Bool {
        let id = Self.key(kind: kind, source: source, providerID: providerID)
        if items.contains(where: { $0.id == id }) {
            items.removeAll { $0.id == id }
            persistCollections()
            return false
        }

        let item = FavoriteCollection(kind: kind, source: source, providerID: providerID,
                                      name: name, coverURL: coverURL, subtitle: subtitle)
        items.insert(item, at: 0)
        persistCollections()
        return true
    }

    func remove(_ item: FavoriteCollection) {
        items.removeAll { $0.id == item.id }
        persistCollections()
    }

    private func persistCollections() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        AppDataBackupManager.shared.scheduleAutomaticBackup()
    }

    private func persistTracks() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(tracks) else { return }
        UserDefaults.standard.set(data, forKey: trackStorageKey)
        AppDataBackupManager.shared.scheduleAutomaticBackup()
    }
}
