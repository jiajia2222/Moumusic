import Foundation

// MARK: - 酷我音乐 / 咪咕音乐（公开接口，播放地址由用户导入的 LX 音源解析）
// 接口形式参考 LX Music（Apache-2.0 / GPL）的 kw / mg 音源 SDK。

struct ExtraChart: Identifiable, Hashable {
    let id: String
    let name: String
    let source: SongSource
}

enum ExtraAPIError: LocalizedError {
    case badResponse
    case empty

    var errorDescription: String? {
        switch self {
        case .badResponse: return "平台返回了无法识别的数据"
        case .empty: return "平台暂时没有返回内容"
        }
    }
}

enum ExtraHTTP {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func data(_ urlString: String, method: String = "GET", headers: [String: String] = [:], form: [String: String]? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { throw ExtraAPIError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let form = form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
                .joined(separator: "&").data(using: .utf8)
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ExtraAPIError.badResponse }
        return data
    }

    /// 解析 JSON；酷我部分接口返回单引号“伪 JSON”，失败时做一次转换再试。
    static func json(_ urlString: String, method: String = "GET", headers: [String: String] = [:], form: [String: String]? = nil) async throws -> Any {
        let data = try await data(urlString, method: method, headers: headers, form: form)
        if let obj = try? JSONSerialization.jsonObject(with: data) { return obj }
        if var text = String(data: data, encoding: .utf8) {
            text = text.replacingOccurrences(of: "'", with: "\"")
            if let d = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) { return obj }
        }
        throw ExtraAPIError.badResponse
    }

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? s
    }

    static func decodeName(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    static func string(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    static func double(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    /// 平台字符串 id → 稳定的 Int（数字 id 直接使用，否则取 FNV-1a 哈希）。
    static func numericID(_ raw: String) -> Int {
        if let n = Int(raw) { return n }
        var hash: UInt64 = 0xcbf29ce484222325
        for b in raw.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return Int(hash & 0x7fffffffffffffff)
    }
}

// MARK: - 酷我

enum KuwoMusicAPI {
    static let source: SongSource = .kuwo

    /// 酷我榜单（LX 内置列表，bangid 即 id）。
    static let charts: [ExtraChart] = [
        ("93", "飙升榜"), ("16", "热歌榜"), ("17", "新歌榜"), ("145", "会员榜"), ("158", "抖音榜"),
        ("187", "趋势榜"), ("26", "怀旧榜"), ("104", "华语榜"), ("182", "粤语榜"), ("22", "欧美榜"),
        ("184", "韩语榜"), ("183", "日语榜")
    ].map { ExtraChart(id: $0.0, name: $0.1, source: .kuwo) }

    static func song(from item: [String: Any]) -> Song? {
        let rawID = ExtraHTTP.string(item["MUSICRID"] ?? item["id"] ?? item["rid"]).replacingOccurrences(of: "MUSIC_", with: "")
        guard !rawID.isEmpty else { return nil }
        let name = ExtraHTTP.decodeName(ExtraHTTP.string(item["SONGNAME"] ?? item["name"]))
        guard !name.isEmpty else { return nil }
        let artist = ExtraHTTP.decodeName(ExtraHTTP.string(item["ARTIST"] ?? item["artist"])).replacingOccurrences(of: "&", with: "、")
        let album = ExtraHTTP.decodeName(ExtraHTTP.string(item["ALBUM"] ?? item["album"]))
        var cover: URL?
        if let pic = item["pic"] as? String, pic.hasPrefix("http") {
            cover = URL(string: pic)
        } else if let short = item["web_albumpic_short"] as? String, !short.isEmpty {
            cover = URL(string: "https://img4.kuwo.cn/star/albumcover/" + short.replacingOccurrences(of: "120", with: "500"))
        }
        return Song(
            id: ExtraHTTP.numericID(rawID), name: name, artists: artist, album: album, coverURL: cover,
            duration: ExtraHTTP.double(item["DURATION"] ?? item["duration"]),
            source: .kuwo, fee: 0, extID: rawID
        )
    }

    static func searchSongs(keyword: String, limit: Int = 30, page: Int = 1) async throws -> [Song] {
        let url = "http://search.kuwo.cn/r.s?client=kt&all=\(ExtraHTTP.encode(keyword))&pn=\(page - 1)&rn=\(limit)&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1"
        guard let root = try await ExtraHTTP.json(url) as? [String: Any],
              let list = root["abslist"] as? [[String: Any]] else { throw ExtraAPIError.badResponse }
        return list.compactMap(song(from:))
    }

    static func hotKeywords() async throws -> [String] {
        let url = "http://hotword.kuwo.cn/hotword.s?prod=kwplayer_ar_9.3.0.1&corp=kuwo&newver=2&vipver=9.3.0.1&source=kwplayer_ar_9.3.0.1_40.apk&p2p=1&notrace=0&uid=0&plat=kwplayer_ar&rformat=json&encoding=utf8&tabid=1"
        let obj = try await ExtraHTTP.json(url, headers: ["User-Agent": "Dalvik/2.1.0 (Linux; U; Android 9;)"])
        guard let root = obj as? [String: Any], let list = root["tagvalue"] as? [[String: Any]] else { throw ExtraAPIError.badResponse }
        return list.compactMap { $0["key"] as? String }
    }

    static func chartSongs(_ chart: ExtraChart, limit: Int = 100) async throws -> [Song] {
        let url = "http://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json&pn=0&rn=\(limit)&type=bang&data=content&id=\(chart.id)&show_copyright_off=0&pcmp4=1&isbang=1"
        guard let root = try await ExtraHTTP.json(url) as? [String: Any],
              let list = root["musiclist"] as? [[String: Any]] else { throw ExtraAPIError.badResponse }
        return list.compactMap(song(from:))
    }

    static func recommendedPlaylists(page: Int = 1) async throws -> [Playlist] {
        let url = "http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList?loginUid=0&loginSid=0&appUid=76039576&&pn=\(page)&rn=36&order=hot"
        guard let root = try await ExtraHTTP.json(url) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let list = data["data"] as? [[String: Any]] else { throw ExtraAPIError.badResponse }
        return list.compactMap { item in
            let id = ExtraHTTP.string(item["id"])
            guard !id.isEmpty else { return nil }
            return Playlist(id: ExtraHTTP.numericID(id), name: ExtraHTTP.decodeName(ExtraHTTP.string(item["name"])),
                            coverURL: URL(string: ExtraHTTP.string(item["img"])),
                            trackCount: Int(ExtraHTTP.double(item["total"])), source: .kuwo)
        }
    }

    static func playlistSongs(id: Int) async throws -> [Song] {
        let url = "http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=\(id)&pn=0&rn=300&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1"
        guard let root = try await ExtraHTTP.json(url) as? [String: Any],
              (root["result"] as? String) == "ok",
              let list = root["musiclist"] as? [[String: Any]] else { throw ExtraAPIError.badResponse }
        return list.compactMap(song(from:))
    }

    /// 歌词：m.kuwo.cn 的 JSON 接口，转换成标准 LRC。
    static func lyric(rid: String) async -> String? {
        let url = "http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=\(rid)"
        guard let root = try? await ExtraHTTP.json(url) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let lines = data["lrclist"] as? [[String: Any]], !lines.isEmpty else { return nil }
        let lrc = lines.compactMap { line -> String? in
            let t = ExtraHTTP.double(line["time"])
            let text = ExtraHTTP.string(line["lineLyric"]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let m = Int(t) / 60
            let s = t - Double(m * 60)
            return String(format: "[%02d:%05.2f]%@", m, s, text)
        }
        return lrc.joined(separator: "\n")
    }

    static func coverURL(rid: String) async -> URL? {
        let url = "http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid=\(rid)"
        guard let data = try? await ExtraHTTP.data(url), let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http") ? URL(string: trimmed) : nil
    }
}

// MARK: - 咪咕

enum MiguMusicAPI {
    static let source: SongSource = .migu

    static let charts: [ExtraChart] = [
        ("27553319", "新歌榜"), ("27186466", "热歌榜"), ("27553408", "原创榜"), ("75959118", "音乐风向榜"),
        ("76557036", "彩铃分贝榜"), ("76557745", "会员臻爱榜"), ("23189800", "港台榜"), ("23189399", "内地榜"),
        ("19190036", "欧美榜"), ("83176390", "国风金曲榜")
    ].map { ExtraChart(id: $0.0, name: $0.1, source: .migu) }

    private static let webHeaders: [String: String] = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1",
        "Referer": "https://m.music.migu.cn/"
    ]

    private static func absoluteImage(_ raw: String?) -> URL? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        return URL(string: raw.hasPrefix("http") ? raw : "http://d.musicapp.migu.cn" + raw)
    }

    private static func singerNames(_ any: Any?) -> String {
        (any as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: "、")
    }

    /// 搜索 / 歌单（V5 结构）：songId + copyrightId + singerList + duration(秒)。
    static func songV5(from d: [String: Any]) -> Song? {
        let songID = ExtraHTTP.string(d["songId"])
        let copyright = ExtraHTTP.string(d["copyrightId"])
        guard !songID.isEmpty, !copyright.isEmpty else { return nil }
        let img = ExtraHTTP.string(d["img3"]).isEmpty ? (ExtraHTTP.string(d["img2"]).isEmpty ? ExtraHTTP.string(d["img1"]) : ExtraHTTP.string(d["img2"])) : ExtraHTTP.string(d["img3"])
        return Song(
            id: ExtraHTTP.numericID(copyright), name: ExtraHTTP.string(d["name"]).isEmpty ? ExtraHTTP.string(d["songName"]) : ExtraHTTP.string(d["name"]),
            artists: singerNames(d["singerList"]), album: ExtraHTTP.string(d["album"]), coverURL: absoluteImage(img),
            duration: ExtraHTTP.double(d["duration"]), source: .migu, fee: 0, extID: copyright
        )
    }

    /// 榜单（resourceinfo 结构）：artists + albumImgs + length("mm:ss")。
    static func songInfo(from d: [String: Any]) -> Song? {
        let copyright = ExtraHTTP.string(d["copyrightId"])
        guard !ExtraHTTP.string(d["songId"]).isEmpty, !copyright.isEmpty else { return nil }
        var duration = 0.0
        let length = ExtraHTTP.string(d["length"])
        let parts = length.split(separator: ":").compactMap { Double($0) }
        if parts.count >= 2 { duration = parts[parts.count - 2] * 60 + parts[parts.count - 1] }
        let img = ((d["albumImgs"] as? [[String: Any]])?.first?["img"] as? String)
        return Song(
            id: ExtraHTTP.numericID(copyright), name: ExtraHTTP.string(d["songName"]),
            artists: singerNames(d["artists"]), album: ExtraHTTP.string(d["album"]), coverURL: absoluteImage(img),
            duration: duration, source: .migu, fee: 0, extID: copyright
        )
    }

    private static func signature(_ time: String, _ text: String) -> (sign: String, deviceID: String) {
        let deviceID = "963B7AA0D21511ED807EE5846EC87D20"
        let key = "6cdc72a439cef99a3418d2a78aa28c73"
        let raw = "\(text)\(key)yyapp2d16148780a1dcc7408e06336b98cfd50\(deviceID)\(time)"
        return (Data(raw.utf8).md5Hex(), deviceID)
    }

    static func searchSongs(keyword: String, limit: Int = 20, page: Int = 1) async throws -> [Song] {
        let time = String(Int(Date().timeIntervalSince1970 * 1000))
        let sig = signature(time, keyword)
        let sw = "%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A1%2C%22mvSong%22%3A0%2C%22bestShow%22%3A1%2C%22songlist%22%3A0%2C%22lyricSong%22%3A0%7D"
        let url = "https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1&searchSwitch=\(sw)&pageSize=\(limit)&text=\(ExtraHTTP.encode(keyword))&pageNo=\(page)&sort=0&sid=USS"
        let headers = [
            "uiVersion": "A_music_3.6.1", "deviceId": sig.deviceID, "timestamp": time, "sign": sig.sign, "channel": "0146921",
            "User-Agent": "Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30"
        ]
        guard let root = try await ExtraHTTP.json(url, headers: headers) as? [String: Any],
              (root["code"] as? String) == "000000",
              let result = root["songResultData"] as? [String: Any],
              let groups = result["resultList"] as? [Any] else { throw ExtraAPIError.badResponse }
        var seen = Set<String>()
        var songs: [Song] = []
        for group in groups {
            for entry in (group as? [[String: Any]] ?? []) {
                if let song = songV5(from: entry), seen.insert(song.extID ?? "").inserted { songs.append(song) }
            }
        }
        return songs
    }

    static func hotKeywords() async throws -> [String] {
        guard let root = try await ExtraHTTP.json("http://jadeite.migu.cn:7090/music_search/v3/search/hotword") as? [String: Any],
              (root["code"] as? String) == "000000",
              let data = root["data"] as? [String: Any],
              let groups = data["hotwords"] as? [[String: Any]],
              let list = groups.first?["hotwordList"] as? [[String: Any]] else { throw ExtraAPIError.badResponse }
        return list.filter { ($0["resourceType"] as? String) == "song" }.compactMap { $0["word"] as? String }
    }

    static func chartSongs(_ chart: ExtraChart) async throws -> [Song] {
        let url = "https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/querycontentbyId.do?columnId=\(chart.id)&needAll=0"
        let headers = [
            "Referer": "https://app.c.nf.migu.cn/",
            "User-Agent": "Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Mobile Safari/537.36",
            "channel": "0146921"
        ]
        guard let root = try await ExtraHTTP.json(url, headers: headers) as? [String: Any],
              (root["code"] as? String) == "000000",
              let column = root["columnInfo"] as? [String: Any],
              let contents = column["contents"] as? [[String: Any]] else { throw ExtraAPIError.badResponse }
        var seen = Set<String>()
        return contents.compactMap { ($0["objectInfo"] as? [String: Any]).flatMap(songInfo(from:)) }
            .filter { seen.insert($0.extID ?? "").inserted }
    }

    static func recommendedPlaylists(page: Int = 1) async throws -> [Playlist] {
        let url = "https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square-recommend/v1.0?templateVersion=2&pageNo=\(page)"
        guard let root = try await ExtraHTTP.json(url, headers: webHeaders) as? [String: Any],
              (root["code"] as? String) == "000000",
              let data = root["data"] as? [String: Any],
              let contents = data["contents"] as? [Any] else { throw ExtraAPIError.badResponse }
        var out: [Playlist] = []
        var seen = Set<String>()
        func walk(_ nodes: [Any]) {
            for node in nodes {
                guard let item = node as? [String: Any] else { continue }
                if let children = item["contents"] as? [Any] { walk(children); continue }
                let resType = ExtraHTTP.string(item["resType"])
                let resID = ExtraHTTP.string(item["resId"])
                guard resType == "2021", !resID.isEmpty, seen.insert(resID).inserted else { continue }
                out.append(Playlist(id: ExtraHTTP.numericID(resID), name: ExtraHTTP.string(item["txt"]),
                                    coverURL: URL(string: ExtraHTTP.string(item["img"])), trackCount: 0, source: .migu))
            }
        }
        walk(contents)
        return out
    }

    static func playlistSongs(id: Int) async throws -> [Song] {
        let url = "https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0?pageNo=1&pageSize=100&playlistId=\(id)"
        guard let root = try await ExtraHTTP.json(url, headers: webHeaders) as? [String: Any],
              (root["code"] as? String) == "000000",
              let data = root["data"] as? [String: Any],
              let list = data["songList"] as? [[String: Any]] else { throw ExtraAPIError.badResponse }
        return list.compactMap(songV5(from:))
    }

    /// 歌词：通过 resourceinfo 取 lrcUrl 后下载 LRC 文本。
    static func lyric(copyrightID: String) async -> String? {
        let url = "https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=2"
        guard let root = try? await ExtraHTTP.json(url, method: "POST", form: ["resourceId": copyrightID]) as? [String: Any],
              let list = root["resource"] as? [[String: Any]],
              let lrcURL = list.first?["lrcUrl"] as? String, !lrcURL.isEmpty else { return nil }
        let headers = ["Referer": "https://app.c.nf.migu.cn/", "channel": "0146921"]
        guard let data = try? await ExtraHTTP.data(lrcURL, headers: headers) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 统一入口

enum ExtraPlatforms {
    static func supports(_ source: SongSource) -> Bool { source == .kuwo || source == .migu }

    static func charts(for source: SongSource) -> [ExtraChart] {
        switch source {
        case .kuwo: return KuwoMusicAPI.charts
        case .migu: return MiguMusicAPI.charts
        default: return []
        }
    }

    static func search(_ source: SongSource, keyword: String, limit: Int = 30) async throws -> [Song] {
        switch source {
        case .kuwo: return try await KuwoMusicAPI.searchSongs(keyword: keyword, limit: limit)
        case .migu: return try await MiguMusicAPI.searchSongs(keyword: keyword, limit: min(limit, 30))
        default: return []
        }
    }

    static func hotKeywords(for source: SongSource) async -> [String] {
        switch source {
        case .kuwo: return (try? await KuwoMusicAPI.hotKeywords()) ?? []
        case .migu: return (try? await MiguMusicAPI.hotKeywords()) ?? []
        default: return []
        }
    }

    static func chartSongs(_ chart: ExtraChart) async throws -> [Song] {
        switch chart.source {
        case .kuwo: return try await KuwoMusicAPI.chartSongs(chart)
        case .migu: return try await MiguMusicAPI.chartSongs(chart)
        default: return []
        }
    }

    static func recommendedPlaylists(for source: SongSource) async throws -> [Playlist] {
        switch source {
        case .kuwo: return try await KuwoMusicAPI.recommendedPlaylists()
        case .migu: return try await MiguMusicAPI.recommendedPlaylists()
        default: return []
        }
    }

    static func playlistSongs(_ playlist: Playlist) async throws -> [Song] {
        switch playlist.source {
        case .kuwo: return try await KuwoMusicAPI.playlistSongs(id: playlist.id)
        case .migu: return try await MiguMusicAPI.playlistSongs(id: playlist.id)
        default: return []
        }
    }

    /// 返回 LRC 文本；不支持或失败时为 nil。
    static func lyric(for song: Song) async -> String? {
        switch song.source {
        case .kuwo: return await KuwoMusicAPI.lyric(rid: song.extID ?? String(song.id))
        case .migu: return await MiguMusicAPI.lyric(copyrightID: song.extID ?? String(song.id))
        default: return nil
        }
    }
}
