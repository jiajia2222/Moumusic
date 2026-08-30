import Foundation
import Combine

struct LocalPlaylist: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var coverURL: String?
    var sourceName: String?
    var tracks: [Track]
    let createdAt: Date

    init(id: UUID = UUID(), name: String, coverURL: String? = nil,
         sourceName: String? = nil, tracks: [Track] = [], createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.sourceName = sourceName
        self.tracks = tracks
        self.createdAt = createdAt
    }
}

enum PlaylistImportError: LocalizedError {
    case emptyInput
    case unsupportedLink
    case invalidFormat
    case noTracks

    var errorDescription: String? {
        switch self {
        case .emptyInput: return "请输入歌单 JSON 文件内容"
        case .unsupportedLink: return "在线歌单链接解析已移除；请从原音乐软件导出并导入 JSON 歌单"
        case .invalidFormat: return "无法识别歌单格式"
        case .noTracks: return "歌单中没有可导入的歌曲"
        }
    }
}

@MainActor
final class LocalPlaylistStore: ObservableObject {
    static let shared = LocalPlaylistStore()

    @Published private(set) var playlists: [LocalPlaylist]

    private let key = "moumusic.localPlaylists.v1"

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? decoder.decode([LocalPlaylist].self, from: data) {
            playlists = saved
        } else {
            playlists = []
        }
    }

    func playlist(id: UUID) -> LocalPlaylist? {
        playlists.first { $0.id == id }
    }

    @discardableResult
    func create(name: String, tracks: [Track] = [], coverURL: String? = nil,
                sourceName: String? = nil) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let playlist = LocalPlaylist(name: trimmed, coverURL: coverURL,
                                     sourceName: sourceName, tracks: tracks)
        playlists.insert(playlist, at: 0)
        persist()
        return playlist.id
    }

    func rename(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = trimmed
        persist()
    }

    func delete(id: UUID) {
        playlists.removeAll { $0.id == id }
        persist()
    }

    func add(_ track: Track, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let key = trackKey(track)
        guard !playlists[index].tracks.contains(where: { trackKey($0) == key }) else {
            ToastCenter.shared.show("歌曲已经在这个歌单中")
            return
        }
        playlists[index].tracks.append(track)
        persist()
        ToastCenter.shared.show("已添加到「\(playlists[index].name)」")
    }

    func remove(_ track: Track, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let key = trackKey(track)
        playlists[index].tracks.removeAll { trackKey($0) == key }
        persist()
    }

    @discardableResult
    func importPlaylist(from input: String) async throws -> UUID {
        let imported = try await PlaylistImportService.importPlaylist(from: input)
        let id = create(name: imported.name, tracks: imported.tracks,
                        coverURL: imported.coverURL, sourceName: imported.sourceName)
        guard let id else { throw PlaylistImportError.invalidFormat }
        return id
    }

    func exportText(_ playlist: LocalPlaylist) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(playlist),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(playlists) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func trackKey(_ track: Track) -> String {
        let source = track.source ?? "wy"
        let mid = track.sourceMetadata["songmid"] ?? track.sourceMetadata["id"] ?? String(track.id)
        return "\(source)|\(mid)|\(track.name.lowercased())|\(track.artistNames.lowercased())"
    }
}

private struct ImportedPlaylist {
    let name: String
    let coverURL: String?
    let sourceName: String?
    let tracks: [Track]
}

private enum PlaylistImportService {
    static func importPlaylist(from input: String) async throws -> ImportedPlaylist {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw PlaylistImportError.emptyInput }

        if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            _ = url
            throw PlaylistImportError.unsupportedLink
        }

        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return try importJSON(object)
        }

        throw PlaylistImportError.invalidFormat
    }

    private static func importJSON(_ object: Any) throws -> ImportedPlaylist {
        let tracks = collectTracks(from: object)
        guard !tracks.isEmpty else { throw PlaylistImportError.noTracks }
        let root = object as? [String: Any]
        let name = string(root?["name"])
            ?? string(root?["title"])
            ?? string(root?["playlistName"])
            ?? "导入歌单"
        let cover = string(root?["coverURL"])
            ?? string(root?["coverUrl"])
            ?? string(root?["picUrl"])
            ?? string(root?["coverImgUrl"])
        return ImportedPlaylist(name: name, coverURL: cover,
                                sourceName: string(root?["source"]), tracks: tracks)
    }

    private static func collectTracks(from object: Any) -> [Track] {
        if let array = object as? [Any] {
            return array.flatMap(collectTracks)
        }
        guard let dictionary = object as? [String: Any] else { return [] }
        if let track = makeTrack(dictionary) { return [track] }

        let keys = ["tracks", "songs", "musicList", "musiclist", "list", "playlist", "data", "result"]
        for key in keys {
            if let nested = dictionary[key] {
                let tracks = collectTracks(from: nested)
                if !tracks.isEmpty { return tracks }
            }
        }
        return []
    }

    private static func makeTrack(_ value: [String: Any]) -> Track? {
        let name = string(value["name"]) ?? string(value["songName"])
            ?? string(value["SongName"]) ?? string(value["title"])
            ?? string(value["songname"])
        guard let name, !name.isEmpty else { return nil }

        let artistValue = value["artists"] ?? value["ar"]
        let artistNames: [String]
        if let array = artistValue as? [[String: Any]] {
            artistNames = array.compactMap { string($0["name"]) }
        } else if let array = artistValue as? [String] {
            artistNames = array
        } else {
            let text = string(value["artist"]) ?? string(value["singer"])
                ?? string(value["singername"]) ?? string(value["Singers"])
                ?? string(value["artistNames"]) ?? "未知歌手"
            artistNames = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let artists = artistNames.enumerated().map { ArtistRef(id: $0.offset, name: $0.element) }
        let albumValue = value["album"] ?? value["al"]
        let albumDictionary = albumValue as? [String: Any]
        let albumName = string(albumDictionary?["name"])
            ?? string(value["albumName"]) ?? string(value["albumname"]) ?? ""
        let cover = string(albumDictionary?["picUrl"])
            ?? string(albumDictionary?["pic"])
            ?? string(value["coverURL"])
            ?? string(value["picUrl"])
            ?? string(value["img"])
        let rawID = string(value["id"]) ?? string(value["songid"])
            ?? string(value["songId"]) ?? string(value["songmid"])
            ?? string(value["mid"]) ?? string(value["hash"])
        guard let rawID, !rawID.isEmpty else { return nil }
        let id = Int(rawID) ?? stableID(rawID)
        guard id > 0 else { return nil }

        var metadata: [String: String] = [:]
        for key in ["songmid", "songMid", "songId", "hash", "FileHash", "copyrightId",
                    "albumId", "strMediaMid", "albumMid", "id"] {
            if let value = string(value[key]), !value.isEmpty { metadata[key] = value }
        }
        let source = string(value["source"])?.lowercased()
        return Track(id: id, name: name, artists: artists,
                     album: AlbumRef(id: Int(string(albumDictionary?["id"]) ?? "") ?? 0,
                                    name: albumName, picUrl: cover),
                     durationMS: durationMS(value), source: source,
                     sourceMetadata: metadata)
    }

    private static func durationMS(_ value: [String: Any]) -> Int {
        let raw = value["durationMS"] ?? value["dt"] ?? value["duration"] ?? value["interval"]
            ?? value["Duration"]
        if let number = raw as? NSNumber { return Int(number.doubleValue) }
        guard let text = string(raw) else { return 0 }
        if text.contains(":") {
            let parts = text.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 { return Int((parts[0] * 60 + parts[1]) * 1000) }
        }
        let number = Double(text) ?? 0
        return Int(number < 1000 ? number * 1000 : number)
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func stableID(_ value: String) -> Int {
        var hash: UInt64 = 2_166_136_261
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 16_777_619 }
        return Int(hash & 0x7fff_ffff)
    }

}
