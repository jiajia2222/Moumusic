import Foundation
import CommonCrypto

/// The catalogue side of LX Music.  Search is intentionally independent from
/// a user script: LX User API scripts resolve playback/lyrics, while these
/// adapters provide the same multi-platform search experience as LX Mobile.
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
        case .aggregate: return "??"
        case .kw: return "??"
        case .kg: return "??"
        case .tx: return "QQ ??"
        case .wy: return "???"
        case .mg: return "??"
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
        case .invalidResponse: return "??????????????"
        case .unsupported: return "??????????"
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
        let sign = zzcSign(body)
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

    private static func fetchObject(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Moumusic/0.4", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LXCatalogError.invalidResponse
        }
        return try JSONSerialization.jsonObject(with: data)
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
        return value.components(separatedBy: CharacterSet(charactersIn: "/,&?;"))
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

    private static func zzcSign(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let part1 = [23, 14, 6, 36, 16, 40, 7, 19].map { String(hash[hash.index(hash.startIndex, offsetBy: $0)]) }.joined()
        let part2 = [16, 1, 32, 12, 19, 27, 8, 5].map { String(hash[hash.index(hash.startIndex, offsetBy: $0)]) }.joined()
        let scramble = [89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179]
        var bytes: [UInt8] = []
        for (index, value) in scramble.enumerated() {
            let start = hash.index(hash.startIndex, offsetBy: index * 2)
            let end = hash.index(start, offsetBy: 2)
            bytes.append(UInt8(value) ^ UInt8(String(hash[start..<end]), radix: 16)!)
        }
        let base64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "=", with: "")
        return "zzc\(part1)\(base64)\(part2)".lowercased()
    }
}
