import Foundation

/// 收藏的歌手（本地保存）。
final class FavoriteArtistsStore: ObservableObject {
    static let shared = FavoriteArtistsStore()

    struct Item: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let coverURL: URL?
        let source: SongSource
    }

    @Published private(set) var items: [Item]
    private let key = "beans.favoriteArtists.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: "beans.favoriteArtists.v1"),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    func contains(id: String) -> Bool { items.contains { $0.id == id } }

    func toggle(_ artist: Artist) {
        if let index = items.firstIndex(where: { $0.id == artist.id }) {
            items.remove(at: index)
        } else {
            items.insert(Item(id: artist.id, name: artist.name, coverURL: artist.coverURL, source: artist.source), at: 0)
        }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    var artists: [Artist] {
        items.map { Artist(id: $0.id, name: $0.name, coverURL: $0.coverURL, source: $0.source) }
    }
}
