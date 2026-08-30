import Foundation
import CommonCrypto
import Compression
import CoreFoundation

/// LX Music's catalogue side. Search, songlists and hot words come from the
/// selected catalogue platform; an imported User API script is kept for
/// playback, lyrics and artwork resolution.
enum LXCatalogPlatform: String, CaseIterable, Identifiable {
    case aggregate
    case kw
    case kg
    case tx
    case wy
    case mg

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .aggregate: return "聚合"
        case .kw: return "酷我"
        case .kg: return "酷狗"
        case .tx: return "QQ 音乐"
        case .wy: return "网易云"
        case .mg: return "咪咕"
        }
    }
    var sourceID: String? {
        switch self {
        case .aggregate: return nil
        case .kw: return "kw"
        case .kg: return "kg"
        case .tx: return "tx"
        case .wy: return "wy"
        case .mg: return "mg"
        }
    }
}

enum LXCatalogError: LocalizedError {
    case invalidResponse
    case unsupported

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "平台返回了无法识别的结果"
        case .unsupported: return "当前平台暂不支持此功能"
        }
    }
}

enum LXCatalogService {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    static func search(_ keyword: String, platform: LXCatalogPlatform,
                       page: Int = 1, limit: Int = 30) async throws -> [Track] {
        if platform == .aggregate {
            let results = await withTaskGroup(of: [Track].self, returning: [[Track]].self) { group in
                for item in LXCatalogPlatform.allCases where item != .aggregate {
                    group.addTask {
                        (try? await search(keyword, platform: item, page: page, limit: limit)) ?? []
                    }
                }
                var all: [[Track]] = []
                for await result in group { all.append(result) }
                return all
            }
            var seen = Set<String>()
            return results.flatMap { $0 }.filter {
                let key = "\($0.name.lowercased())|\($0.artistNames.lowercased())"
                return seen.insert(key).inserted
            }
        }

        switch platform {
        case .kw: return try await searchKuwo(keyword, page: page, limit: limit)
        case .kg: return try await searchKugou(keyword, page: page, limit: limit)
        case .tx: return try await searchQQ(keyword, page: page, limit: limit)
        case .wy: return try await searchNetease(keyword, page: page, limit: limit)
        case .mg: return try await searchMigu(keyword, page: page, limit: limit)
        case .aggregate: throw LXCatalogError.unsupported
        }
    }

    private static func searchNetease(_ keyword: String, page: Int, limit: Int) async throws -> [Track] {
        let result = try await NeteaseAPI.search(keyword, type: .songs,
                                                 limit: limit, offset: max(0, page - 1) * limit)
        return (result.songs ?? []).map { $0.withSource("wy") }
    }

    private static func searchKuwo(_ keyword: String, page: Int, limit: Int) async throws -> [Track] {
        var components = URLComponents(string: "http://search.kuwo.cn/r.s")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "kt"),
            URLQueryItem(name: "all", value: keyword),
            URLQueryItem(name: "pn", value: String(max(0, page - 1))),
            URLQueryItem(name: "rn", value: String(limit)),
            URLQueryItem(name: "uid", value: "794762570"),
            URLQueryItem(name: "ver", value: "kwplayer_ar_9.2.2.1"),
            URLQueryItem(name: "vipver", value: "1"),
            URLQueryItem(name: "show_copyright_off", value: "1"),
            URLQueryItem(name: "newver", value: "1"),
            URLQueryItem(name: "ft", value: "music"),
            URLQueryItem(name: "cluster", value: "0"),
            URLQueryItem(name: "strategy", value: "2012"),
            URLQueryItem(name: "encoding", value: "utf8"),
            URLQueryItem(name: "rformat", value: "json"),
            URLQueryItem(name: "vermerge", value: "1"),
            URLQueryItem(name: "mobi", value: "1"),
            URLQueryItem(name: "issubtitle", value: "1"),
        ]
        let root = try await fetchObject(components.url!) as? [String: Any]
        let items = root?["abslist"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let rawID = text(item["MUSICRID"]),
                  let id = Int(rawID.replacingOccurrences(of: "MUSIC_", with: "")) else { return nil }
            let metadata = [
                "songmid": String(id),
                "albumId": text(item["ALBUMID"]) ?? "",
            ]
            return Track(id: id,
                         name: text(item["SONGNAME"]) ?? "",
                         artists: artists(from: text(item["ARTIST"])),
                         album: AlbumRef(id: Int(text(item["ALBUMID"]) ?? "") ?? 0,
                                        name: text(item["ALBUM"]) ?? "", picUrl: nil),
                         durationMS: seconds(item["DURATION"]) * 1000,
                         source: "kw", sourceMetadata: metadata)
        }
    }

    private static func searchKugou(_ keyword: String, page: Int, limit: Int) async throws -> [Track] {
        var components = URLComponents(string: "https://songsearch.kugou.com/song_search_v2")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pagesize", value: String(limit)),
            URLQueryItem(name: "userid", value: "0"),
            URLQueryItem(name: "clientver", value: ""),
            URLQueryItem(name: "platform", value: "WebFilter"),
            URLQueryItem(name: "filter", value: "2"),
            URLQueryItem(name: "iscorrection", value: "1"),
            URLQueryItem(name: "privilege_filter", value: "0"),
            URLQueryItem(name: "area_code", value: "1"),
        ]
        let root = try await fetchObject(components.url!) as? [String: Any]
        let data = root?["data"] as? [String: Any]
        let items = data?["lists"] as? [[String: Any]] ?? []
        var output: [Track] = []
        var seen = Set<String>()
        for item in items + items.flatMap({ $0["Grp"] as? [[String: Any]] ?? [] }) {
            guard let id = int(item["Audioid"]), id > 0 else { continue }
            let hash = text(item["FileHash"]) ?? ""
            guard seen.insert("\(id)-\(hash)").inserted else { continue }
            output.append(Track(id: id,
                                name: text(item["SongName"]) ?? "",
                                artists: artists(from: text(item["Singers"])),
                                album: AlbumRef(id: int(item["AlbumID"]) ?? 0,
                                               name: text(item["AlbumName"]) ?? "", picUrl: nil),
                                durationMS: seconds(item["Duration"]) * 1000,
                                source: "kg",
                                sourceMetadata: ["songmid": String(id), "hash": hash,
                                                 "albumId": text(item["AlbumID"]) ?? ""]))
        }
        return output
    }

    private static func searchMigu(_ keyword: String, page: Int, limit: Int) async throws -> [Track] {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let deviceID = "963B7AA0D21511ED807EE5846EC87D20"
        let signature = md5("\(keyword)6cdc72a439cef99a3418d2a78aa28c73yyapp2d16148780a1dcc7408e06336b98cfd50\(deviceID)\(timestamp)")
        var components = URLComponents(string: "https://jadeite.migu.cn/music_search/v3/search/searchAll")!
        components.queryItems = [
            URLQueryItem(name: "isCorrect", value: "0"),
            URLQueryItem(name: "isCopyright", value: "1"),
            URLQueryItem(name: "searchSwitch", value: "{\"song\":1,\"album\":0,\"singer\":0,\"tagSong\":1,\"mvSong\":0,\"bestShow\":1,\"songlist\":0}"),
            URLQueryItem(name: "pageSize", value: String(limit)),
            URLQueryItem(name: "text", value: keyword),
            URLQueryItem(name: "pageNo", value: String(page)),
            URLQueryItem(name: "sort", value: "0"),
            URLQueryItem(name: "sid", value: "USS"),
        ]
        let object = try await fetchObject(components.url!, headers: [
            "uiVersion": "A_music_3.6.1", "deviceId": deviceID,
            "timestamp": timestamp, "sign": signature, "channel": "0146921",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)",
        ]) as? [String: Any]
        let songResult = object?["songResultData"] as? [String: Any]
        let pages = songResult?["resultList"] as? [[Any]] ?? []
        return pages.flatMap { $0 }.compactMap { value in
            guard let item = value as? [String: Any],
                  let rawID = text(item["songId"]), let id = Int(rawID), id > 0 else { return nil }
            let image = text(item["img3"]) ?? text(item["img2"]) ?? text(item["img1"])
            let imageURL = image.map { $0.hasPrefix("http") ? $0 : "http://d.musicapp.migu.cn\($0)" }
            return Track(id: id, name: text(item["name"]) ?? "",
                         artists: artists(from: text(item["singerList"])),
                         album: AlbumRef(id: int(item["albumId"]) ?? 0,
                                        name: text(item["album"]) ?? "", picUrl: imageURL),
                         durationMS: seconds(item["duration"]) * 1000,
                         source: "mg",
                         sourceMetadata: ["songmid": rawID,
                                          "copyrightId": text(item["copyrightId"]) ?? ""])
        }
    }

    private static func searchQQ(_ keyword: String, page: Int, limit: Int) async throws -> [Track] {
        let request: [String: Any] = [
            "comm": ["ct": "11", "cv": "14090508", "v": "14090508",
                     "tmeAppID": "qqmusic", "phonetype": "EBG-AN10",
                     "deviceScore": "553.47", "devicelevel": "50",
                     "newdevicelevel": "20", "rom": "HuaWei/EMOTION/EmotionUI_14.2.0",
                     "os_ver": "12", "OpenUDID": "0", "OpenUDID2": "0",
                     "QIMEI36": "0", "udid": "0", "chid": "0", "aid": "0",
                     "oaid": "0", "taid": "0", "tid": "0", "wid": "0",
                     "uid": "0", "sid": "0", "modeSwitch": "6", "teenMode": "0",
                     "ui_mode": "2", "nettype": "1020", "v4ip": ""],
            "req": ["module": "music.search.SearchCgiService",
                    "method": "DoSearchForQQMusicMobile",
                    "param": ["search_type": 0, "searchid": String(Int.random(in: 100000000...999999999)),
                              "query": keyword, "page_num": page, "num_per_page": limit,
                              "highlight": 0, "nqc_flag": 0, "multi_zhida": 0,
                              "cat": 2, "grp": 1, "sin": 0, "sem": 0]],
        ]
        let body = try JSONSerialization.data(withJSONObject: request)
        // The LX JavaScript implementation ignores an out-of-range hash index
        // when Array.join() converts undefined to an empty string.  Swift's
        // String.Index traps instead, so signing must be allowed to fail safely.
        guard let sign = zzcSign(body) else { return [] }
        let url = URL(string: "https://u.y.qq.com/cgi-bin/musics.fcg?sign=\(sign)")!
        var requestObject = URLRequest(url: url)
        requestObject.httpMethod = "POST"
        requestObject.httpBody = body
        requestObject.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requestObject.setValue("QQMusic 14090508(android 12)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: requestObject)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let req = root["req"] as? [String: Any],
              let reqData = req["data"] as? [String: Any],
              let items = reqData["body"] as? [String: Any],
              let songs = items["item_song"] as? [[String: Any]] else { return [] }
        return songs.compactMap { item in
            guard let id = int(item["id"]), id > 0 else { return nil }
            let album = item["album"] as? [String: Any]
            let file = item["file"] as? [String: Any]
            let albumMid = text(album?["mid"]) ?? ""
            let mediaMid = text(file?["media_mid"]) ?? ""
            let image = albumMid.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(albumMid).jpg"
            return Track(id: id, name: text(item["title"]) ?? text(item["name"]) ?? "",
                         artists: qqArtists(item["singer"]),
                         album: AlbumRef(id: int(album?["id"]) ?? 0,
                                        name: text(album?["name"]) ?? "", picUrl: image),
                         durationMS: seconds(item["interval"]) * 1000,
                         source: "tx",
                         sourceMetadata: ["songmid": text(item["mid"]) ?? String(id),
                                          "strMediaMid": mediaMid,
                                          "albumMid": albumMid])
        }
    }

    private static func fetchObject(_ url: URL, method: String = "GET", body: Data? = nil,
                                    headers: [String: String] = [:]) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Moumusic/0.4", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LXCatalogError.invalidResponse
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func fetchData(_ url: URL, method: String = "GET", body: Data? = nil,
                                  headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Moumusic/0.5", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LXCatalogError.invalidResponse
        }
        return data
    }

    private static func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Moumusic/0.5", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            throw LXCatalogError.invalidResponse
        }
        return text
    }

    private static func inflateZlib(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var capacity = max(data.count * 8, 64 * 1024)
        while capacity <= 8 * 1024 * 1024 {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            let count = data.withUnsafeBytes { source in
                compression_decode_buffer(buffer, capacity, source.bindMemory(to: UInt8.self).baseAddress,
                                           data.count, nil, COMPRESSION_ZLIB)
            }
            if count > 0 { return Data(bytes: buffer, count: count) }
            capacity *= 2
        }
        return nil
    }

    private static func decodeGB18030(_ data: Data) -> String? {
        #if canImport(CoreFoundation)
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
        #else
        return String(data: data, encoding: .utf8)
        #endif
    }

    private static func parseKugouLRC(_ raw: String) -> String {
        let pattern = #/^\[(\d+),(\d+)\](.*)$/#
        return raw.components(separatedBy: .newlines).compactMap { line in
            guard let match = line.firstMatch(of: pattern),
                  let milliseconds = Int(match.output.1) else { return nil }
            let text = String(match.output.3)
                .replacingOccurrences(of: #/<\d+,\d+(?:,\d+)?>/#, with: "",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let minutes = milliseconds / 60_000
            let seconds = Double(milliseconds % 60_000) / 1000
            return String(format: "[%02d:%05.2f] %@", minutes, seconds, text)
        }.joined(separator: "\n")
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        case let value as [String: Any]:
            if let name = value["name"] { return text(name) }
            return value.values.compactMap { text($0) }.joined(separator: " / ")
        case let value as [[String: Any]]:
            return value.compactMap { text($0) }.joined(separator: " / ")
        default: return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func seconds(_ value: Any?) -> Int {
        if let value = int(value) { return value }
        guard let value = text(value) else { return 0 }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        return Int(Double(value) ?? 0)
    }

    private static func artists(from value: String?) -> [ArtistRef] {
        guard let value, !value.isEmpty else { return [] }
        return value.components(separatedBy: CharacterSet(charactersIn: "/,&、;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { ArtistRef(id: -($0.offset + 1), name: $0.element) }
    }

    private static func qqArtists(_ value: Any?) -> [ArtistRef] {
        if let list = value as? [[String: Any]] {
            return list.enumerated().map { ArtistRef(id: int($0.element["id"]) ?? -($0.offset + 1),
                                                     name: text($0.element["name"]) ?? "") }
        }
        return artists(from: text(value))
    }

    private static func md5(_ string: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        let data = Data(string.utf8)
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func zzcSign(_ data: Data) -> String? {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &digest)
        }

        // Keep the hash as ASCII bytes.  Indexing a Swift String by scalar or
        // character offsets is unnecessary here and was the source of the
        // iOS 27 crash (the LX-compatible part-1 table contains index 40,
        // while a SHA-1 hex digest has valid offsets 0...39).
        let hexDigits = Array("0123456789abcdef".utf8)
        let hash = digest.flatMap { byte in
            [hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0f)]]
        }
        guard hash.count == 40 else { return nil }

        let part1Indexes = [23, 14, 6, 36, 16, 40, 7, 19]
        let part2Indexes = [16, 1, 32, 12, 19, 27, 8, 5]
        // `hash[40]` is undefined in the original JavaScript and disappears
        // when joined, so filtering it matches LX's output exactly.
        let part1 = part1Indexes
            .filter { hash.indices.contains($0) }
            .map { String(decoding: [hash[$0]], as: UTF8.self) }
            .joined()
        let part2 = part2Indexes
            .filter { hash.indices.contains($0) }
            .map { String(decoding: [hash[$0]], as: UTF8.self) }
            .joined()
        let scramble = [89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179]
        var bytes: [UInt8] = []
        for (index, value) in scramble.enumerated() {
            let high = hexNibble(hash[index * 2])
            let low = hexNibble(hash[index * 2 + 1])
            guard let high, let low else { return nil }
            bytes.append(UInt8(value) ^ ((high << 4) | low))
        }
        let base64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "=", with: "")
        return "zzc\(part1)\(base64)\(part2)".lowercased()
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    /// Loads the same kind of source-owned feed that LX Mobile exposes on its
    /// song-list page.  The old iOS implementation searched the first hot
    /// word, which is not a recommendation feed and can return placeholder
    /// words from a user API.  Keeping the song list and its tracks together
    /// also guarantees that a home recommendation never loses its platform.
    static func recommendedContent(platform: LXCatalogPlatform, limit: Int = 30)
        async -> (playlists: [LXPlaylistSummary], tracks: [Track]) {
        guard platform != .aggregate else { return ([], []) }

        let playlists = (try? await recommendedSonglists(platform: platform, limit: limit)) ?? []
        let candidates = Array(playlists.prefix(3))
        let groups = await withTaskGroup(of: [Track].self, returning: [[Track]].self) { group in
            for playlist in candidates {
                group.addTask {
                    (try? await playlistDetail(source: platform, id: playlist.id))?.tracks ?? []
                }
            }
            var output: [[Track]] = []
            for await tracks in group { output.append(tracks) }
            return output
        }

        var seen = Set<String>()
        var tracks = groups.flatMap { $0 }.filter {
            seen.insert("\($0.name.lowercased())|\($0.artistNames.lowercased())").inserted
        }

        // A platform may expose playlists while temporarily refusing their
        // details.  Keep a real platform search as a small fallback, but do
        // not use the hot-word endpoint that produced the old dummy feed.
        if tracks.isEmpty {
            tracks = (try? await search("热门歌曲", platform: platform, limit: limit)) ?? []
        }
        return (playlists, Array(tracks.prefix(limit)))
    }

    static func recommendedTracks(platform: LXCatalogPlatform, limit: Int = 30) async throws -> [Track] {
        guard platform != .aggregate else { throw LXCatalogError.unsupported }
        let content = await recommendedContent(platform: platform, limit: limit)
        return content.tracks
    }

    struct NativeLyrics {
        let lyric: String
        let tlyric: String?
        let rlyric: String?
        let lxlyric: String?
    }

    /// LX Mobile ships lyric adapters with the catalogue SDK rather than the
    /// user source API. Keep the same separation on iOS: imported sources
    /// resolve audio URLs, while the selected catalogue platform resolves
    /// lyrics. This is important because LX's online source capabilities only
    /// advertise `musicUrl`; treating them as lyric providers always returns
    /// an empty panel.
    static func nativeLyrics(for track: Track) async throws -> NativeLyrics {
        switch track.source {
        case "kw": return try await nativeKuwoLyrics(for: track)
        case "kg": return try await nativeKugouLyrics(for: track)
        case "tx": return try await nativeQQLyrics(for: track)
        case "mg": return try await nativeMiguLyrics(for: track)
        default: throw LXCatalogError.unsupported
        }
    }

    private static func nativeKuwoLyrics(for track: Track) async throws -> NativeLyrics {
        let id = track.sourceMetadata["songmid"] ?? String(track.id)
        let params = "user=12345,web,web,web&requester=localhost&req=1&rid=MUSIC_\(id)&lrcx=1"
        let key = Array("yeelion".utf8)
        let encoded = Data(params.utf8).enumerated().map { $0.element ^ key[$0.offset % key.count] }
        let query = Data(encoded).base64EncodedString()
        let url = URL(string: "http://newlyric.kuwo.cn/newlyric.lrc?\(query)")!
        let data = try await fetchData(url)
        guard let delimiter = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw LXCatalogError.invalidResponse
        }
        guard let inflated = inflateZlib(Data(data[delimiter.upperBound...])),
              let encodedLyric = String(data: inflated, encoding: .utf8),
              let lyricData = Data(base64Encoded: encodedLyric,
                                   options: .ignoreUnknownCharacters) else {
            throw LXCatalogError.invalidResponse
        }
        let decoded = lyricData.enumerated().map { $0.element ^ key[$0.offset % key.count] }
        guard let lyric = decodeGB18030(Data(decoded)), !lyric.isEmpty else {
            throw LXCatalogError.invalidResponse
        }
        return NativeLyrics(lyric: lyric, tlyric: nil, rlyric: nil, lxlyric: nil)
    }

    private static func nativeKugouLyrics(for track: Track) async throws -> NativeLyrics {
        guard let hash = track.sourceMetadata["hash"], !hash.isEmpty else {
            throw LXCatalogError.invalidResponse
        }
        var searchURL = URLComponents(string: "http://lyrics.kugou.com/search")!
        searchURL.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "keyword", value: track.name),
            URLQueryItem(name: "hash", value: hash),
            URLQueryItem(name: "timelength", value: String(Int(track.duration))),
            URLQueryItem(name: "lrctxt", value: "1"),
        ]
        let search = try await fetchObject(searchURL.url!) as? [String: Any]
        guard let candidate = (search?["candidates"] as? [[String: Any]])?.first,
              let id = text(candidate["id"]),
              let accessKey = text(candidate["accesskey"]) else {
            throw LXCatalogError.invalidResponse
        }
        let isKRC = int(candidate["krctype"]) == 1 && int(candidate["contenttype"]) != 1
        var downloadURL = URLComponents(string: "http://lyrics.kugou.com/download")!
        downloadURL.queryItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "accesskey", value: accessKey),
            URLQueryItem(name: "fmt", value: isKRC ? "krc" : "lrc"),
            URLQueryItem(name: "charset", value: "utf8"),
        ]
        let result = try await fetchObject(downloadURL.url!) as? [String: Any]
        guard let content = text(result?["content"]),
              let contentData = Data(base64Encoded: content,
                                     options: .ignoreUnknownCharacters) else {
            throw LXCatalogError.invalidResponse
        }
        if !isKRC {
            guard let lyric = String(data: contentData, encoding: .utf8), !lyric.isEmpty else {
                throw LXCatalogError.invalidResponse
            }
            return NativeLyrics(lyric: lyric, tlyric: nil, rlyric: nil, lxlyric: nil)
        }

        guard contentData.count > 4 else { throw LXCatalogError.invalidResponse }
        let key: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
                            0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69]
        var encrypted = Array(contentData.dropFirst(4))
        for index in encrypted.indices { encrypted[index] ^= key[index % key.count] }
        guard let inflated = inflateZlib(Data(encrypted)),
              let raw = String(data: inflated, encoding: .utf8) else {
            throw LXCatalogError.invalidResponse
        }
        let lyric = parseKugouLRC(raw)
        guard !lyric.isEmpty else { throw LXCatalogError.invalidResponse }
        return NativeLyrics(lyric: lyric, tlyric: nil, rlyric: nil, lxlyric: nil)
    }

    private static func nativeQQLyrics(for track: Track) async throws -> NativeLyrics {
        let mid = track.sourceMetadata["songmid"] ?? String(track.id)
        var components = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        components.queryItems = [
            URLQueryItem(name: "songmid", value: mid),
            URLQueryItem(name: "g_tk", value: "5381"),
            URLQueryItem(name: "loginUin", value: "0"),
            URLQueryItem(name: "hostUin", value: "0"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "platform", value: "yqq"),
        ]
        let root = try await fetchObject(components.url!, headers: ["Referer": "https://y.qq.com/portal/player.html"]) as? [String: Any]
        guard int(root?["code"]) == 0, let raw = text(root?["lyric"]),
              let data = Data(base64Encoded: raw, options: .ignoreUnknownCharacters),
              let lyric = String(data: data, encoding: .utf8), !lyric.isEmpty else {
            throw LXCatalogError.invalidResponse
        }
        let translation: String?
        if let rawTranslation = text(root?["trans"]),
           let translationData = Data(base64Encoded: rawTranslation,
                                      options: .ignoreUnknownCharacters) {
            translation = String(data: translationData, encoding: .utf8)
        } else {
            translation = nil
        }
        return NativeLyrics(lyric: lyric, tlyric: translation, rlyric: nil, lxlyric: nil)
    }

    private static func nativeMiguLyrics(for track: Track) async throws -> NativeLyrics {
        let resourceID = track.sourceMetadata["copyrightId"]
            ?? track.sourceMetadata["songmid"]
            ?? String(track.id)
        let url = URL(string: "https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=2")!
        let encodedID = resourceID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resourceID
        let root = try await fetchObject(url, method: "POST",
                                         body: Data("resourceId=\(encodedID)".utf8),
                                         headers: ["Content-Type": "application/x-www-form-urlencoded",
                                                   "Referer": "https://app.c.nf.migu.cn/"]) as? [String: Any]
        let data = root?["data"] as? [String: Any]
        let resource = (data?["resource"] as? [[String: Any]])?.first
        if let lrcURL = text(resource?["lrcUrl"]), !lrcURL.isEmpty {
            let lyric = try await fetchText(URL(string: lrcURL)!)
            if !lyric.isEmpty { return NativeLyrics(lyric: lyric, tlyric: nil, rlyric: nil, lxlyric: nil) }
        }
        throw LXCatalogError.invalidResponse
    }

    // MARK: - Songlists

    /// Returns source-native recommended song lists.  This mirrors the
    /// `songList.getList()` calls in LX Mobile instead of turning a hot-search
    /// keyword into fake recommendations.
    static func recommendedSonglists(platform: LXCatalogPlatform, limit: Int = 30)
        async throws -> [LXPlaylistSummary] {
        guard platform != .aggregate else { throw LXCatalogError.unsupported }

        switch platform {
        case .kw:
            let lists = try await recommendedKuwoSonglists(limit: limit)
            return lists.isEmpty
                ? try await searchSonglists("热门", platform: .kw, limit: limit)
                : lists
        case .kg:
            let lists = try await recommendedKugouSonglists(limit: limit)
            return lists.isEmpty
                ? try await searchSonglists("热门", platform: .kg, limit: limit)
                : lists
        case .tx:
            let lists = try await recommendedQQSonglists(limit: limit)
            return lists.isEmpty
                ? try await searchSonglists("热门", platform: .tx, limit: limit)
                : lists
        case .wy:
            let items = try await NeteaseAPI.personalizedPlaylists(limit: limit)
            return items.map {
                LXPlaylistSummary(id: String($0.id), name: $0.name, coverURL: $0.coverURL,
                                  playCount: $0.playCount, trackCount: $0.trackCount,
                                  description: $0.copywriter, author: $0.creator?.nickname,
                                  source: .wy)
            }
        case .mg:
            let lists = try await recommendedMiguSonglists(limit: limit)
            return lists.isEmpty
                ? try await searchSonglists("热门", platform: .mg, limit: limit)
                : lists
        case .aggregate:
            throw LXCatalogError.unsupported
        }
    }

    private static func recommendedKuwoSonglists(limit: Int) async throws -> [LXPlaylistSummary] {
        var components = URLComponents(string: "http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList")!
        components.queryItems = [
            URLQueryItem(name: "loginUid", value: "0"),
            URLQueryItem(name: "loginSid", value: "0"),
            URLQueryItem(name: "appUid", value: "76039576"),
            URLQueryItem(name: "pn", value: "1"),
            URLQueryItem(name: "rn", value: String(limit)),
            URLQueryItem(name: "order", value: "5"),
        ]
        let root = try await fetchObject(components.url!) as? [String: Any]
        let data = root?["data"] as? [String: Any]
        let items = data?["data"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let rawID = text(item["id"]) ?? text(item["playlistid"]) else { return nil }
            let id: String
            if let digest = text(item["digest"]), !digest.isEmpty {
                // LX keeps the digest because Kuwo playlist ids can resolve
                // through different detail adapters (digest 5/8/13).
                id = "digest-\(digest)__\(rawID)"
            } else {
                id = rawID
            }
            return LXPlaylistSummary(id: id, name: text(item["name"]) ?? "",
                                     coverURL: text(item["img"]),
                                     playCount: int(item["listencnt"]) ?? int(item["playcnt"]) ?? 0,
                                     trackCount: int(item["total"]) ?? int(item["songnum"]) ?? 0,
                                     description: text(item["desc"]), author: text(item["uname"]),
                                     source: .kw)
        }
    }

    private static func recommendedKugouSonglists(limit: Int) async throws -> [LXPlaylistSummary] {
        // This is LX Mobile's source-native recommendation call. The normal
        // getSpecial endpoint is a tag listing and frequently returns an
        // empty page for the default tag, which used to make Home look blank.
        let body: [String: Any] = [
            "appid": 1001,
            "clienttime": 1566798337219,
            "clientver": 8275,
            "key": "f1f93580115bb106680d2375f8032d96",
            "mid": "21511157a05844bd085308bc76ef3343",
            "platform": "pc",
            "userid": "262643156",
            "return_min": 6,
            "return_max": max(6, min(limit, 15)),
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let url = URL(string: "http://everydayrec.service.kugou.com/guess_special_recommend")!
        let root = try await fetchObject(url, method: "POST", body: data,
                                         headers: ["Content-Type": "application/json",
                                                   "User-Agent": "KuGou2012-8275-web_browser_event_handler"]) as? [String: Any]
        let result = root?["data"] as? [String: Any]
        let items = result?["special_list"] as? [[String: Any]] ?? []
        return items.prefix(limit).compactMap { item in
            guard let id = int(item["specialid"]) else { return nil }
            return LXPlaylistSummary(id: "id_\(id)", name: text(item["specialname"]) ?? "",
                                     coverURL: text(item["img"]) ?? text(item["imgurl"]),
                                     playCount: int(item["total_play_count"]) ?? int(item["play_count"]) ?? int(item["collectcount"]) ?? 0,
                                     trackCount: int(item["songcount"]) ?? int(item["song_count"]) ?? 0,
                                     description: text(item["intro"]), author: text(item["nickname"]),
                                     source: .kg)
        }
    }

    private static func recommendedQQSonglists(limit: Int) async throws -> [LXPlaylistSummary] {
        // Match LX Mobile's GET form. QQ accepts the same JSON envelope via
        // the `data` query item; posting the envelope returns HTTP 200 but an
        // empty playlist object on some regions.
        let request: [String: Any] = [
            "comm": ["cv": 1602, "ct": 20],
            "playlist": [
                "method": "get_playlist_by_tag",
                "param": ["id": 10000000, "sin": 0, "size": limit, "order": 5, "cur_page": 1],
                "module": "playlist.PlayListPlazaServer",
            ],
        ]
        let encoded = try JSONSerialization.data(withJSONObject: request)
        var components = URLComponents(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
        components.queryItems = [
            URLQueryItem(name: "loginUin", value: "0"),
            URLQueryItem(name: "hostUin", value: "0"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf-8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "wk_v15.json"),
            URLQueryItem(name: "needNewCode", value: "0"),
            URLQueryItem(name: "data", value: String(data: encoded, encoding: .utf8)),
        ]
        let root = try await fetchObject(components.url!) as? [String: Any]
        let playlist = root?["playlist"] as? [String: Any]
        let data = playlist?["data"] as? [String: Any]
        let items = data?["v_playlist"] as? [[String: Any]] ?? []
        return items.prefix(limit).compactMap { item in
            guard let id = int(item["tid"]) else { return nil }
            let creator = (item["creator_info"] as? [String: Any]).flatMap { text($0["nick"]) }
            return LXPlaylistSummary(id: String(id), name: text(item["title"]) ?? "",
                                     coverURL: text(item["cover_url_medium"]) ?? text(item["cover_url"]),
                                     playCount: int(item["access_num"]) ?? 0,
                                     trackCount: (item["song_ids"] as? [Any])?.count ?? 0,
                                     description: text(item["desc"]), author: creator, source: .tx)
        }
    }

    private static func recommendedMiguSonglists(limit: Int) async throws -> [LXPlaylistSummary] {
        let url = URL(string: "https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square-recommend/v1.0?templateVersion=2&pageNo=1")!
        let root = try await fetchObject(url, headers: ["Referer": "https://m.music.migu.cn/"]) as? [String: Any]
        let data = root?["data"] as? [String: Any]
        let contents = data?["contents"] as? [[String: Any]] ?? []
        var output: [LXPlaylistSummary] = []
        var seen = Set<String>()

        func visit(_ item: [String: Any]) {
            if let nested = item["contents"] as? [[String: Any]] {
                nested.forEach(visit)
            } else if text(item["resType"]) == "2021",
                      let id = text(item["resId"]), seen.insert(id).inserted {
                output.append(LXPlaylistSummary(id: id, name: text(item["txt"]) ?? "",
                                                 coverURL: text(item["img"]), playCount: 0,
                                                 trackCount: int(item["contentCount"]) ?? 0,
                                                 description: text(item["txt2"]), author: nil, source: .mg))
            }
        }
        contents.forEach(visit)
        return Array(output.prefix(limit))
    }

    /// LX Search has two catalogue types: music and songlists. Songlists are
    /// intentionally not delegated to NetEase except for the WY adapter.
    static func searchSonglists(_ keyword: String, platform: LXCatalogPlatform,
                                page: Int = 1, limit: Int = 30) async throws -> [LXPlaylistSummary] {
        if platform == .aggregate {
            let results = await withTaskGroup(of: [LXPlaylistSummary].self,
                                              returning: [[LXPlaylistSummary]].self) { group in
                for item in LXCatalogPlatform.allCases where item != .aggregate {
                    group.addTask {
                        (try? await searchSonglists(keyword, platform: item, page: page, limit: limit)) ?? []
                    }
                }
                var all: [[LXPlaylistSummary]] = []
                for await result in group { all.append(result) }
                return all
            }
            var seen = Set<String>()
            return results.flatMap { $0 }.filter {
                let author = $0.author?.lowercased() ?? ""
                return seen.insert("\($0.name.lowercased())|\(author)").inserted
            }
        }

        switch platform {
        case .kw: return try await searchKuwoSonglists(keyword, page: page, limit: limit)
        case .kg: return try await searchKugouSonglists(keyword, page: page, limit: limit)
        case .tx: return try await searchQQSonglists(keyword, page: page, limit: limit)
        case .wy: return try await searchNeteaseSonglists(keyword, page: page, limit: limit)
        case .mg: return try await searchMiguSonglists(keyword, page: page, limit: limit)
        case .aggregate: throw LXCatalogError.unsupported
        }
    }

    private static func searchNeteaseSonglists(_ keyword: String, page: Int, limit: Int) async throws -> [LXPlaylistSummary] {
        let result = try await NeteaseAPI.search(keyword, type: .playlists,
                                                 limit: limit, offset: max(0, page - 1) * limit)
        return (result.playlists ?? []).map {
            LXPlaylistSummary(id: String($0.id), name: $0.name, coverURL: $0.coverURL,
                              playCount: $0.playCount, trackCount: $0.trackCount,
                              description: $0.copywriter, author: $0.creator?.nickname, source: .wy)
        }
    }

    private static func searchKuwoSonglists(_ keyword: String, page: Int, limit: Int) async throws -> [LXPlaylistSummary] {
        var components = URLComponents(string: "http://search.kuwo.cn/r.s")!
        components.queryItems = [
            URLQueryItem(name: "all", value: keyword),
            URLQueryItem(name: "pn", value: String(max(0, page - 1))),
            URLQueryItem(name: "rn", value: String(limit)),
            URLQueryItem(name: "rformat", value: "json"),
            URLQueryItem(name: "encoding", value: "utf8"),
            URLQueryItem(name: "ft", value: "playlist"),
        ]
        let root = try await fetchObject(components.url!) as? [String: Any]
        let items = root?["abslist"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = text(item["playlistid"]) ?? text(item["id"]) else { return nil }
            return LXPlaylistSummary(id: id, name: text(item["name"]) ?? "",
                                     coverURL: text(item["pic"]),
                                     playCount: int(item["playcnt"]) ?? 0,
                                     trackCount: int(item["songnum"]) ?? 0,
                                     description: text(item["intro"]),
                                     author: text(item["nickname"]), source: .kw)
        }
    }

    private static func searchKugouSonglists(_ keyword: String, page: Int, limit: Int) async throws -> [LXPlaylistSummary] {
        var components = URLComponents(string: "https://msearchretry.kugou.com/api/v3/search/special")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pagesize", value: String(limit)),
            URLQueryItem(name: "showtype", value: "10"),
            URLQueryItem(name: "filter", value: "0"),
            URLQueryItem(name: "version", value: "7910"),
            URLQueryItem(name: "sver", value: "2"),
        ]
        let root = try await fetchObject(components.url!) as? [String: Any]
        guard let data = root?["data"] as? [String: Any],
              let items = data["info"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = int(item["specialid"]) else { return nil }
            return LXPlaylistSummary(id: "id_\(id)", name: text(item["specialname"]) ?? "",
                                     coverURL: text(item["imgurl"]),
                                     playCount: int(item["playcount"]) ?? 0,
                                     trackCount: int(item["songcount"]) ?? 0,
                                     description: text(item["intro"]),
                                     author: text(item["nickname"]), source: .kg)
        }
    }

    private static func searchQQSonglists(_ keyword: String, page: Int, limit: Int) async throws -> [LXPlaylistSummary] {
        var components = URLComponents(string: "http://c.y.qq.com/soso/fcgi-bin/client_music_search_songlist")!
        components.queryItems = [
            URLQueryItem(name: "page_no", value: String(max(0, page - 1))),
            URLQueryItem(name: "num_per_page", value: String(limit)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "query", value: keyword),
            URLQueryItem(name: "remoteplace", value: "txt.yqq.playlist"),
        ]
        let root = try await fetchObject(components.url!, headers: ["Referer": "http://y.qq.com/portal/search.html"]) as? [String: Any]
        let data = root?["data"] as? [String: Any]
        let items = data?["list"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = text(item["dissid"]) else { return nil }
            return LXPlaylistSummary(id: id, name: text(item["dissname"]) ?? "",
                                     coverURL: text(item["imgurl"]),
                                     playCount: int(item["listennum"]) ?? 0,
                                     trackCount: int(item["song_count"]) ?? 0,
                                     description: text(item["introduction"]),
                                     author: text(item["creator"]), source: .tx)
        }
    }

    private static func searchMiguSonglists(_ keyword: String, page: Int, limit: Int) async throws -> [LXPlaylistSummary] {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let deviceID = "963B7AA0D21511ED807EE5846EC87D20"
        let signature = md5("\(keyword)6cdc72a439cef99a3418d2a78aa28c73yyapp2d16148780a1dcc7408e06336b98cfd50\(deviceID)\(timestamp)")
        var components = URLComponents(string: "https://jadeite.migu.cn/music_search/v3/search/searchAll")!
        components.queryItems = [
            URLQueryItem(name: "isCorrect", value: "1"),
            URLQueryItem(name: "isCopyright", value: "1"),
            URLQueryItem(name: "searchSwitch", value: "{\"song\":0,\"album\":0,\"singer\":0,\"tagSong\":0,\"mvSong\":0,\"bestShow\":0,\"songlist\":1,\"lyricSong\":0}"),
            URLQueryItem(name: "pageSize", value: String(limit)),
            URLQueryItem(name: "text", value: keyword),
            URLQueryItem(name: "pageNo", value: String(page)),
            URLQueryItem(name: "sort", value: "0"),
            URLQueryItem(name: "sid", value: "USS"),
        ]
        let root = try await fetchObject(components.url!, headers: [
            "uiVersion": "A_music_3.6.1", "deviceId": deviceID,
            "timestamp": timestamp, "sign": signature, "channel": "0146921",
        ]) as? [String: Any]
        let result = root?["songListResultData"] as? [String: Any]
        let items = result?["result"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = text(item["id"]) else { return nil }
            return LXPlaylistSummary(id: id, name: text(item["name"]) ?? "",
                                     coverURL: text(item["musicListPicUrl"]),
                                     playCount: int(item["playNum"]) ?? 0,
                                     trackCount: int(item["musicNum"]) ?? 0,
                                     description: nil, author: text(item["userName"]), source: .mg)
        }
    }

    // MARK: - Hot search

    static func hotKeywords(platform: LXCatalogPlatform) async throws -> [String] {
        if platform == .aggregate {
            let results = await withTaskGroup(of: [String].self, returning: [[String]].self) { group in
                for item in LXCatalogPlatform.allCases where item != .aggregate {
                    group.addTask { (try? await hotKeywords(platform: item)) ?? [] }
                }
                var all: [[String]] = []
                for await result in group { all.append(result) }
                return all
            }
            var seen = Set<String>()
            return results.flatMap { $0 }.filter { seen.insert($0.lowercased()).inserted }
        }

        switch platform {
        case .kw:
            let url = URL(string: "http://hotword.kuwo.cn/hotword.s?prod=kwplayer_ar_9.3.0.1&corp=kuwo&newver=2&vipver=9.3.0.1&source=kwplayer_ar_9.3.0.1_40.apk&p2p=1&notrace=0&uid=0&plat=kwplayer_ar&rformat=json&encoding=utf8&tabid=1")!
            let root = try await fetchObject(url) as? [String: Any]
            return (root?["tagvalue"] as? [[String: Any]])?.compactMap { text($0["key"]) } ?? []
        case .kg:
            let url = URL(string: "https://gateway.kugou.com/api/v3/search/hot_tab?signature=ee44edb9d7155821412d220bcaf509dd&appid=1005&clientver=10026&plat=0")!
            let root = try await fetchObject(url, headers: ["x-router": "msearch.kugou.com", "kg-rc": "1"]) as? [String: Any]
            let groups = ((root?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
            return groups.flatMap { ($0["keywords"] as? [[String: Any]]) ?? [] }.compactMap { text($0["keyword"]) }
        case .tx:
            let request: [String: Any] = [
                "comm": ["ct": "19", "cv": "1803", "tmeAppID": "qqmusic", "uin": "0"],
                "hotkey": ["method": "GetHotkeyForQQMusicPC", "module": "tencent_musicsoso_hotkey.HotkeyService", "param": ["search_id": "", "uin": 0]],
            ]
            let body = try JSONSerialization.data(withJSONObject: request)
            let root = try await fetchObject(URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, method: "POST", body: body,
                                              headers: ["Content-Type": "application/json", "Referer": "https://y.qq.com/portal/player.html"]) as? [String: Any]
            let hotkey = (root?["hotkey"] as? [String: Any])?["data"] as? [String: Any]
            return (hotkey?["vec_hotkey"] as? [[String: Any]])?.compactMap { text($0["query"]) } ?? []
        case .wy:
            let result = try await NeteaseAPI.searchDefaultKeyword()
            return result.map { [$0] } ?? []
        case .mg:
            let root = try await fetchObject(URL(string: "http://jadeite.migu.cn:7090/music_search/v3/search/hotword")!) as? [String: Any]
            let groups = (((root?["data"] as? [String: Any])?["hotwords"] as? [[String: Any]]) ?? [])
            return groups.flatMap { ($0["hotwordList"] as? [[String: Any]]) ?? [] }
                .filter { text($0["resourceType"]) == "song" }.compactMap { text($0["word"]) }
        case .aggregate: throw LXCatalogError.unsupported
        }
    }

    // MARK: - Songlist details

    static func playlistDetail(source: LXCatalogPlatform, id: String) async throws -> LXPlaylistDetail {
        switch source {
        case .wy:
            guard let neteaseID = Int(id) else { throw LXCatalogError.invalidResponse }
            let response = try await NeteaseAPI.playlistDetail(id: neteaseID)
            var tracks = response.playlist.tracks
            if tracks.isEmpty {
                tracks = (try? await NeteaseAPI.songDetails(ids: response.playlist.trackIds.map(\.id))).map { $0.songs } ?? []
            }
            return LXPlaylistDetail(id: id, name: response.playlist.name,
                                    coverURL: response.playlist.coverImgUrl,
                                    description: response.playlist.description,
                                    author: response.playlist.creator?.nickname,
                                    playCount: response.playlist.playCount,
                                    tracks: tracks.map { $0.withSource("wy") }, source: .wy)
        case .kw:
            let listID = id.components(separatedBy: "__").last ?? id
            let url = URL(string: "http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=\(listID)&pn=0&rn=1000&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1")!
            let root = try await fetchObject(url) as? [String: Any]
            let rawTracks = root?["musiclist"] as? [[String: Any]] ?? []
            return LXPlaylistDetail(id: id, name: text(root?["name"]) ?? text(root?["title"]) ?? "酷我歌单",
                                    coverURL: text(root?["pic"]), description: text(root?["intro"]),
                                    author: text(root?["uname"]), playCount: int(root?["playnum"]) ?? 0,
                                    tracks: rawTracks.compactMap { track(from: $0, source: .kw) }, source: .kw)
        case .tx:
            let url = URL(string: "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=\(id)&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0")!
            let root = try await fetchObject(url) as? [String: Any]
            let cd = ((root?["cdlist"] as? [[String: Any]]) ?? []).first
            let rawTracks = cd?["songlist"] as? [[String: Any]] ?? []
            return LXPlaylistDetail(id: id, name: text(cd?["dissname"]) ?? "QQ 音乐歌单",
                                    coverURL: text(cd?["logo"]), description: text(cd?["desc"]),
                                    author: text(cd?["nickname"]), playCount: int(cd?["visitnum"]) ?? 0,
                                    tracks: rawTracks.compactMap { track(from: $0, source: .tx) }, source: .tx)
        case .mg:
            let url = URL(string: "https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0?pageNo=1&pageSize=1000&playlistId=\(id)")!
            let root = try await fetchObject(url, headers: ["Referer": "https://m.music.migu.cn/"]) as? [String: Any]
            let data = root?["data"] as? [String: Any]
            let rawTracks = data?["songList"] as? [[String: Any]] ?? []
            let infoObject = try? await fetchObject(URL(string: "https://c.musicapp.migu.cn/MIGUM3.0/resource/playlist/v2.0?playlistId=\(id)")!, headers: ["Referer": "https://m.music.migu.cn/"])
            let info = (infoObject as? [String: Any])?["data"] as? [String: Any]
            return LXPlaylistDetail(id: id, name: text(info?["title"]) ?? "咪咕歌单",
                                    coverURL: text((info?["imgItem"] as? [String: Any])?["img"]),
                                    description: text(info?["summary"]), author: text(info?["ownerName"]),
                                    playCount: int((info?["opNumItem"] as? [String: Any])?["playNum"]) ?? 0,
                                    tracks: rawTracks.compactMap { track(from: $0, source: .mg) }, source: .mg)
        case .kg:
            let cleanID = id.replacingOccurrences(of: "id_", with: "")
            let url = URL(string: "https://www.kugou.com/yy/special/single/\(cleanID).html")!
            let html = try await fetchText(url)
            guard let json = firstCapture(#"global\.data = (\[.+\]);"#, in: html),
                  let data = json.data(using: .utf8),
                  let rawTracks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw LXCatalogError.invalidResponse
            }
            let name = firstCapture(#"name:\s*\"([^\"]+)\""#, in: html) ?? "酷狗歌单"
            let cover = firstCapture(#"pic:\s*\"([^\"]+)\""#, in: html)
            return LXPlaylistDetail(id: id, name: name, coverURL: cover, description: nil,
                                    author: nil, playCount: 0,
                                    tracks: rawTracks.compactMap { track(from: $0, source: .kg) }, source: .kg)
        case .aggregate: throw LXCatalogError.unsupported
        }
    }

    private static func track(from item: [String: Any], source: LXCatalogPlatform) -> Track? {
        let nestedAlbum = item["album"] as? [String: Any]
        let nestedFile = item["file"] as? [String: Any]
        let rawID: String?
        let name: String
        let artistText: String?
        let albumID: Int
        let albumName: String
        let durationValue: Any?
        var metadata: [String: String] = [:]

        switch source {
        case .kw:
            rawID = text(item["id"]) ?? text(item["songmid"])
            name = text(item["name"]) ?? text(item["SONGNAME"]) ?? ""
            artistText = text(item["artist"]) ?? text(item["ARTIST"])
            albumID = int(item["albumid"]) ?? int(item["ALBUMID"]) ?? 0
            albumName = text(item["album"]) ?? text(item["ALBUM"]) ?? ""
            durationValue = item["duration"] ?? item["DURATION"]
            if let rawID { metadata["songmid"] = rawID; metadata["albumId"] = String(albumID) }
        case .kg:
            let hash = text(item["hash"]) ?? text(item["FileHash"]) ?? ""
            rawID = text(item["audio_id"]) ?? text(item["Audioid"]) ?? text(item["songid"]) ?? hash
            name = text(item["songname"]) ?? text(item["SongName"]) ?? text(item["filename"]) ?? ""
            artistText = text(item["singername"]) ?? text(item["Singers"])
            albumID = int(item["album_id"]) ?? int(item["AlbumID"]) ?? 0
            albumName = text(item["album_name"]) ?? text(item["AlbumName"]) ?? ""
            durationValue = item["duration"] ?? item["Duration"]
            if !hash.isEmpty { metadata["hash"] = hash }
            if let rawID { metadata["songmid"] = rawID }
            metadata["albumId"] = String(albumID)
        case .tx:
            rawID = text(item["mid"]) ?? text(item["songmid"]) ?? text(item["id"])
            name = text(item["title"]) ?? text(item["name"]) ?? ""
            artistText = text(item["singer"]) ?? text(item["singername"])
            albumID = int(nestedAlbum?["id"]) ?? int(nestedAlbum?["mid"]) ?? 0
            albumName = text(nestedAlbum?["name"]) ?? text(item["albumname"]) ?? ""
            durationValue = item["interval"] ?? item["duration"]
            if let rawID { metadata["songmid"] = rawID }
            metadata["strMediaMid"] = text(nestedFile?["media_mid"]) ?? ""
            metadata["albumMid"] = text(nestedAlbum?["mid"]) ?? ""
        case .mg:
            rawID = text(item["songId"]) ?? text(item["copyrightId"]) ?? text(item["contentId"])
            name = text(item["songName"]) ?? text(item["name"]) ?? ""
            artistText = text(item["singerName"]) ?? text(item["singerList"])
            albumID = int(item["albumId"]) ?? 0
            albumName = text(item["albumName"]) ?? text(item["album"]) ?? ""
            durationValue = item["duration"] ?? item["length"]
            if let rawID { metadata["songmid"] = rawID }
            metadata["copyrightId"] = text(item["copyrightId"]) ?? ""
        case .aggregate, .wy:
            return nil
        }

        guard let rawID, !rawID.isEmpty else { return nil }
        let numericID = Int(rawID) ?? abs(rawID.hashValue)
        guard numericID > 0 else { return nil }
        return Track(id: numericID, name: name, artists: artists(from: artistText),
                     album: AlbumRef(id: albumID, name: albumName, picUrl: nil),
                     durationMS: seconds(durationValue) * 1000,
                     source: source.sourceID, sourceMetadata: metadata)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
