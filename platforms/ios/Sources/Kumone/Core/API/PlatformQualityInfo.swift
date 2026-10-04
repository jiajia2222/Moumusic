import Foundation

/// Which tiers a QQ / Kugou song really has, read from each platform's own per-song file table (no login):
/// QQ's `UniformRuleCtrl/CgiGetTrackInfo` lists the size of every file (`size_new` holds master and Atmos),
/// Kugou's `get_res_privilege` lists one entry per quality with its file size. A size of 0 means the file
/// does not exist. This is the same information LX Music's own clients use for their quality badges, so the
/// picker and the playback request only ever name tiers the song has.
actor PlatformQualityInfo {
    static let shared = PlatformQualityInfo()

    private var cache: [String: (tiers: Set<String>, at: Date)] = [:]
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        session = URLSession(configuration: configuration)
    }

    /// Canonical tier names (`AudioQuality.lxType`), or nil when the platform has no such table / did not answer.
    func tiers(for track: Track) async -> Set<String>? {
        let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
        switch source {
        case "tx", "qq", "qqmusic", "qq-music":
            guard let id = Int(track.sourceMetadata["id"] ?? "") ?? (track.id > 0 ? track.id : nil) else { return nil }
            return await cached("tx:\(id)") { try await self.qqTiers(songID: id) }
        case "kg", "kugou":
            guard let hash = track.sourceMetadata["hash"] ?? track.sourceMetadata["Hash"], !hash.isEmpty else { return nil }
            return await cached("kg:\(hash)") { try await self.kugouTiers(hash: hash) }
        default:
            return nil
        }
    }

    private func cached(_ key: String, _ fetch: () async throws -> Set<String>) async -> Set<String>? {
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < 3600 { return hit.tiers }
        guard let tiers = try? await fetch(), !tiers.isEmpty else { return nil }
        cache[key] = (tiers, Date())
        return tiers
    }

    private func qqTiers(songID: Int) async throws -> Set<String> {
        let body: [String: Any] = [
            "comm": ["ct": "19", "cv": "1859", "uin": "0"],
            "req": ["module": "music.trackInfo.UniformRuleCtrl", "method": "CgiGetTrackInfo",
                    "param": ["types": [1], "ids": [songID], "ctx": 0] as [String: Any]] as [String: Any],
        ]
        var request = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let req = root["req"] as? [String: Any],
              let payload = req["data"] as? [String: Any],
              let track = (payload["tracks"] as? [[String: Any]])?.first,
              let file = track["file"] as? [String: Any] else { return [] }
        func size(_ value: Any?) -> Int { (value as? Int) ?? (value as? NSNumber)?.intValue ?? Int(value as? String ?? "") ?? 0 }
        var found = Set<String>()
        if size(file["size_128mp3"]) > 0 { found.insert("128k") }
        if size(file["size_320mp3"]) > 0 { found.insert("320k") }
        if size(file["size_flac"]) > 0 { found.insert("flac") }
        if size(file["size_hires"]) > 0 { found.insert("flac24bit") }
        if let extra = file["size_new"] as? [Any] {
            if extra.count > 0, size(extra[0]) > 0 { found.insert("jymaster") }
            if extra.count > 1, size(extra[1]) > 0 { found.insert("atmos") }
            if extra.count > 2, size(extra[2]) > 0 { found.insert("atmos") }
        }
        return found
    }

    private func kugouTiers(hash: String) async throws -> Set<String> {
        let body: [String: Any] = [
            "behavior": "play", "clientver": "20049",
            "resource": [["id": 0, "type": "audio", "hash": hash]],
            "area_code": "1", "quality": "128",
            "qualities": ["128", "320", "flac", "high", "dolby", "viper_atmos", "viper_tape", "viper_clear"],
        ]
        var components = URLComponents(string: "https://gateway.kugou.com/goodsmstore/v1/get_res_privilege")!
        components.queryItems = [
            URLQueryItem(name: "appid", value: "1005"), URLQueryItem(name: "clientver", value: "20049"),
            URLQueryItem(name: "clienttime", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "mid", value: "NeZha"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await session.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["error_code"] as? Int ?? 0) == 0,
              let first = (root["data"] as? [[String: Any]])?.first,
              let goods = first["relate_goods"] as? [[String: Any]] else { return [] }
        var found = Set<String>()
        for item in goods {
            let quality = (item["quality"] as? String) ?? String(describing: item["quality"] ?? "")
            let info = item["info"] as? [String: Any]
            let size = (info?["filesize"] as? Int) ?? (info?["filesize"] as? NSNumber)?.intValue ?? Int(info?["filesize"] as? String ?? "") ?? 0
            guard size > 0 else { continue }
            switch quality {
            case "128": found.insert("128k")
            case "320": found.insert("320k")
            case "flac": found.insert("flac")
            case "high": found.insert("flac24bit")
            case "viper_clear": found.insert("jymaster")
            case "viper_atmos": found.insert("atmos")
            case "dolby": found.insert("dolby")
            default: break
            }
        }
        return found
    }
}
