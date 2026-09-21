import Foundation
import Combine

struct LocalPlaylist: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var coverURL: String?
    var sourceName: String?
    var tracks: [Track]
    let createdAt: Date
    /// When present, this local playlist mirrors a user-selected cloud
    /// playlist. The source is intentionally explicit so another provider can
    /// be added without confusing it with a normal local import.
    var remoteSource: String?
    var remotePlaylistID: String?
    var remoteRevision: Int?

    init(id: UUID = UUID(), name: String, coverURL: String? = nil,
         sourceName: String? = nil, tracks: [Track] = [], createdAt: Date = .now,
         remoteSource: String? = nil, remotePlaylistID: String? = nil,
         remoteRevision: Int? = nil) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.sourceName = sourceName
        self.tracks = tracks
        self.createdAt = createdAt
        self.remoteSource = remoteSource
        self.remotePlaylistID = remotePlaylistID
        self.remoteRevision = remoteRevision
    }
}

enum PlaylistImportError: LocalizedError {
    case emptyInput
    case unsupportedLink
    case invalidFormat
    case noTracks

    var errorDescription: String? {
        switch self {
        case .emptyInput: return "请输入歌单链接、文字或 JSON 文件内容"
        case .unsupportedLink: return "无法识别歌单链接；支持网易云、QQ、酷狗、酷我和咪咕公开歌单"
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

    func containsRemotePlaylist(source: String, id: Int) -> Bool {
        playlists.contains {
            $0.remoteSource == source && $0.remotePlaylistID == String(id)
        }
    }

    /// Creates or updates a local mirror of a cloud playlist. Existing local
    /// imports are never matched by name; only an explicit provider + remote
    /// ID can be updated automatically.
    @discardableResult
    func upsertRemotePlaylist(
        source: String,
        remoteID: Int,
        name: String,
        coverURL: String?,
        sourceName: String,
        revision: Int,
        tracks: [Track]
    ) -> (id: UUID, inserted: Bool, changed: Bool) {
        let normalizedTracks = tracks.map { $0.normalizedForLXPlayback() }
        if let index = playlists.firstIndex(where: {
            $0.remoteSource == source && $0.remotePlaylistID == String(remoteID)
        }) {
            let old = playlists[index]
            let changed = old.name != name
                || old.coverURL != coverURL
                || old.remoteRevision != revision
                || old.tracks != normalizedTracks
            guard changed else {
                return (old.id, false, false)
            }
            playlists[index].name = name
            playlists[index].coverURL = coverURL
            playlists[index].sourceName = sourceName
            playlists[index].tracks = normalizedTracks
            playlists[index].remoteRevision = revision
            persist()
            return (old.id, false, true)
        }

        let playlist = LocalPlaylist(
            name: name,
            coverURL: coverURL,
            sourceName: sourceName,
            tracks: normalizedTracks,
            remoteSource: source,
            remotePlaylistID: String(remoteID),
            remoteRevision: revision
        )
        playlists.insert(playlist, at: 0)
        persist()
        return (playlist.id, true, true)
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

    /// Adds a group of tracks while preserving the order supplied by the caller.
    /// Local playlists are source-agnostic, so duplicates are skipped using the
    /// same source-aware key as the single-track API.
    @discardableResult
    func add(_ tracks: [Track], to playlistID: UUID) -> Int {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return 0 }

        var existingKeys = Set(playlists[index].tracks.map(trackKey))
        var added = 0
        for track in tracks {
            let key = trackKey(track)
            guard existingKeys.insert(key).inserted else { continue }
            playlists[index].tracks.append(track)
            added += 1
        }

        if added > 0 { persist() }
        return added
    }

    func remove(_ track: Track, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let key = trackKey(track)
        playlists[index].tracks.removeAll { trackKey($0) == key }
        persist()
    }

    func remove(_ tracks: [Track], from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let keys = Set(tracks.map(trackKey))
        guard !keys.isEmpty else { return }
        playlists[index].tracks.removeAll { keys.contains(trackKey($0)) }
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

        // A share sheet often gives us a sentence rather than a bare URL,
        // for example: “这是我收藏的歌单 https://y.qq.com/...”。Extract
        // every URL first and try recognized playlist links in order.
        let candidates = extractURLs(from: value)
        if !candidates.isEmpty {
            var lastError: Error?
            var foundSupportedLink = false
            for url in candidates {
                var reference = playlistReference(from: url)
                if reference == nil {
                    reference = try? await resolvedPlaylistReference(from: url)
                }
                guard reference != nil else {
                    continue
                }
                foundSupportedLink = true
                do {
                    return try await importRemotePlaylist(from: url)
                } catch {
                    lastError = error
                }
            }
            if foundSupportedLink {
                throw lastError ?? PlaylistImportError.invalidFormat
            }
            throw PlaylistImportError.unsupportedLink
        }

        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return try importJSON(object)
        }

        throw PlaylistImportError.invalidFormat
    }

    private enum RemotePlaylistPlatform {
        case netease
        case catalog(LXCatalogPlatform)

        var displayName: String {
            switch self {
            case .netease: return LXCatalogPlatform.wy.displayName
            case .catalog(let platform): return platform.displayName
            }
        }
    }

    private struct RemotePlaylistReference {
        let platform: RemotePlaylistPlatform
        let id: String
    }

    private static func importRemotePlaylist(from url: URL) async throws -> ImportedPlaylist {
        let resolvedURL = (try? await resolveRedirect(from: url)) ?? url
        guard let reference = playlistReference(from: resolvedURL)
                ?? playlistReference(from: url) else {
            throw PlaylistImportError.unsupportedLink
        }

        switch reference.platform {
        case .netease:
            return try await importNeteasePlaylist(id: reference.id)
        case .catalog(let platform):
            guard platform != .aggregate else { throw PlaylistImportError.unsupportedLink }
            do {
                let detail = try await LXCatalogService.playlistDetail(source: platform,
                                                                         id: reference.id)
                guard !detail.tracks.isEmpty else { throw PlaylistImportError.noTracks }
                return ImportedPlaylist(
                    name: detail.name,
                    coverURL: detail.coverURL,
                    sourceName: platform.displayName,
                    tracks: detail.tracks
                )
            } catch let error as PlaylistImportError {
                throw error
            } catch {
                throw PlaylistImportError.invalidFormat
            }
        }
    }

    private static func importNeteasePlaylist(id: String) async throws -> ImportedPlaylist {
        guard let playlistID = Int(id) else { throw PlaylistImportError.unsupportedLink }

        var components = URLComponents(string: "https://music.163.com/api/v6/playlist/detail")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(playlistID)),
            URLQueryItem(name: "n", value: "1000"),
        ]
        let root = try await fetchJSONObject(components.url!)
        if let code = integer(root["code"]), code != 200 {
            throw PlaylistImportError.invalidFormat
        }
        guard let playlist = (root["playlist"] as? [String: Any])
                ?? ((root["result"] as? [String: Any])?["playlist"] as? [String: Any]) else {
            throw PlaylistImportError.invalidFormat
        }

        var tracks = collectTracks(from: playlist["tracks"] ?? [], defaultSource: "wy")
        let ids = (playlist["trackIds"] as? [[String: Any]])?
            .compactMap { string($0["id"]) }
            .filter { !$0.isEmpty } ?? []
        // The v6 endpoint deliberately returns only a preview in `tracks`
        // even when n=1000. Fetch the full trackIds list so a shared playlist
        // is not silently truncated to ten songs.
        if tracks.count < ids.count, !ids.isEmpty {
            var detailComponents = URLComponents(string: "https://music.163.com/api/song/detail")!
            detailComponents.queryItems = [
                URLQueryItem(name: "ids", value: "[\(ids.joined(separator: ","))]"),
            ]
            if let details = try? await fetchJSONObject(detailComponents.url!) {
                let detailedTracks = collectTracks(from: details["songs"] ?? details["data"] ?? details,
                                                    defaultSource: "wy")
                if !detailedTracks.isEmpty { tracks = detailedTracks }
            }
        }
        guard !tracks.isEmpty else { throw PlaylistImportError.noTracks }

        let name = string(playlist["name"]) ?? "网易云歌单 \(playlistID)"
        let cover = string(playlist["coverImgUrl"])
            ?? string(playlist["picUrl"])
            ?? string(playlist["cover"])
        return ImportedPlaylist(name: name, coverURL: cover,
                                sourceName: "网易云", tracks: tracks)
    }

    private static func resolvedPlaylistReference(from url: URL) async throws -> RemotePlaylistReference {
        let resolvedURL = try await resolveRedirect(from: url)
        guard let reference = playlistReference(from: resolvedURL) else {
            throw PlaylistImportError.unsupportedLink
        }
        return reference
    }

    /// Finds the public playlist identifier in a platform share URL. The
    /// patterns intentionally stay provider-specific so a song or artist URL
    /// cannot accidentally be imported as a playlist.
    private static func playlistReference(from url: URL) -> RemotePlaylistReference? {
        guard let host = url.host?.lowercased() else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
            ($0.name.lowercased(), $0.value ?? "")
        })
        let parts = url.path.split(separator: "/").map(String.init)

        func firstID(after markers: [String]) -> String? {
            for marker in markers {
                guard let index = parts.firstIndex(where: { $0.lowercased() == marker }),
                      index + 1 < parts.count else { continue }
                let value = parts[index + 1].split(separator: ".").first.map(String.init) ?? ""
                if !value.isEmpty { return value }
            }
            return nil
        }

        if host.contains("163cn.tv") || host.contains("music.163.com") {
            let path = url.path.lowercased()
            let fragment = url.fragment?.lowercased() ?? ""
            guard host.contains("163cn.tv") || path.contains("playlist") || fragment.contains("playlist") else {
                return nil
            }
            if let id = neteasePlaylistID(from: url) {
                return RemotePlaylistReference(platform: .netease, id: String(id))
            }
            return nil
        }

        if host == "y.qq.com" || host.hasSuffix(".y.qq.com") || host == "c.y.qq.com" {
            let id = query["disstid"] ?? query["playlistid"] ?? query["playlist_id"]
                ?? firstID(after: ["playlist", "playsquare"])
            guard let id, !id.isEmpty else { return nil }
            return RemotePlaylistReference(platform: .catalog(.tx), id: id)
        }

        if host.contains("kugou.com") {
            let id = query["globalid"] ?? query["listid"] ?? query["playlistid"]
                ?? firstID(after: ["single", "playlist", "special"])
            guard let id, !id.isEmpty else { return nil }
            // Kugou's newer share page appends the adapter and page size,
            // e.g. `/single/12345-5-9999.html`; the detail adapter expects
            // only the numeric special ID.
            let normalizedID: String
            if let first = id.split(separator: "-").first,
               Int(first) != nil {
                normalizedID = String(first)
            } else {
                normalizedID = id
            }
            return RemotePlaylistReference(platform: .catalog(.kg), id: normalizedID)
        }

        if host.contains("kuwo.cn") {
            let id = query["pid"] ?? query["playlistid"] ?? query["playlist_id"]
                ?? firstID(after: ["playlist_detail", "playlist", "songlist"])
            guard let id, !id.isEmpty else { return nil }
            return RemotePlaylistReference(platform: .catalog(.kw), id: id)
        }

        if host.contains("migu.cn") {
            let id = query["playlistid"] ?? query["playlist_id"]
                ?? firstID(after: ["collection", "playlist"])
            guard let id, !id.isEmpty else { return nil }
            return RemotePlaylistReference(platform: .catalog(.mg), id: id)
        }

        return nil
    }

    private static func extractURLs(from text: String) -> [URL] {
        let pattern = #"https?://[^\s<>\"'，。！？；、）)\]}]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            var raw = String(text[matchRange])
            while let last = raw.last, ".,!?;:，。！？；、".contains(last) {
                raw.removeLast()
            }
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return url
        }
    }

    private static func resolveRedirect(from url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        return response.url ?? url
    }

    private static func fetchJSONObject(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaylistImportError.invalidFormat
        }
        return object
    }

    private static func neteasePlaylistID(from url: URL) -> Int? {
        func queryID(_ components: URLComponents?) -> Int? {
            components?.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value
                .flatMap(Int.init)
        }

        if let id = queryID(URLComponents(url: url, resolvingAgainstBaseURL: false)) {
            return id
        }
        if let fragment = url.fragment,
           let id = queryID(URLComponents(string: fragment)) {
            return id
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(where: { $0.lowercased() == "playlist" }),
           index + 1 < parts.count {
            return Int(parts[index + 1])
        }
        return nil
    }

    private static func importJSON(_ object: Any, defaultSource: String? = nil) throws -> ImportedPlaylist {
        let tracks = collectTracks(from: object, defaultSource: defaultSource)
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

    private static func collectTracks(from object: Any, defaultSource: String? = nil) -> [Track] {
        if let array = object as? [Any] {
            return array.flatMap { collectTracks(from: $0, defaultSource: defaultSource) }
        }
        guard let dictionary = object as? [String: Any] else { return [] }
        if let track = makeTrack(dictionary, defaultSource: defaultSource) { return [track] }

        let keys = ["tracks", "songs", "musicList", "musiclist", "list", "playlist", "data", "result"]
        for key in keys {
            if let nested = dictionary[key] {
                let tracks = collectTracks(from: nested, defaultSource: defaultSource)
                if !tracks.isEmpty { return tracks }
            }
        }
        return []
    }

    private static func makeTrack(_ value: [String: Any], defaultSource: String? = nil) -> Track? {
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
        let source = string(value["source"])?.lowercased() ?? defaultSource
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

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func stableID(_ value: String) -> Int {
        var hash: UInt64 = 2_166_136_261
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 16_777_619 }
        return Int(hash & 0x7fff_ffff)
    }

}
