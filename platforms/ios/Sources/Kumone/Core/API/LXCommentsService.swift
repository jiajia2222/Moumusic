import CommonCrypto
import Foundation

/// Read-only comments from the selected catalogue platform.  This follows
/// LX Mobile's provider adapters and deliberately does not require a provider
/// account or expose any login state.
struct LXComment: Identifiable, Hashable {
    let id: String
    let content: String
    let author: String?
    let avatarURL: String?
    let likedCount: Int
    let date: Date?
}

struct LXCommentsResult {
    let hot: [LXComment]
    let latest: [LXComment]
}

enum LXCommentsService {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration)
    }()

    static func comments(for track: Track, limit: Int = 50) async throws -> LXCommentsResult {
        let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
        switch source {
        case "kw", "kuwo":
            return try await kuwoComments(for: track, limit: limit)
        case "kg", "kugou":
            return try await kugouComments(for: track, limit: limit)
        case "tx", "qq", "qqmusic":
            return try await qqComments(for: track, limit: limit)
        case "mg", "migu":
            return try await miguComments(for: track, limit: limit)
        default:
            throw LXCommentsError.unsupported
        }
    }

    private static func kuwoComments(for track: Track, limit: Int) async throws -> LXCommentsResult {
        let songID = track.sourceMetadata["songmid"] ?? String(track.id)
        async let latest = kuwoList(songID: songID, hot: false, limit: limit)
        async let hot = kuwoList(songID: songID, hot: true, limit: limit)
        let latestResult = try? await latest
        let hotResult = try? await hot
        guard latestResult != nil || hotResult != nil else {
            throw LXCommentsError.requestFailed
        }
        return LXCommentsResult(hot: hotResult ?? [], latest: latestResult ?? [])
    }

    private static func kuwoList(songID: String, hot: Bool, limit: Int) async throws -> [LXComment] {
        var components = URLComponents(string: "https://ncomment.kuwo.cn/com.s")!
        components.queryItems = [
            URLQueryItem(name: "f", value: "web"),
            URLQueryItem(name: "type", value: hot ? "get_rec_comment" : "get_comment"),
            URLQueryItem(name: "aapiver", value: "1"),
            URLQueryItem(name: "prod", value: "kwplayer_ar_10.5.2.0"),
            URLQueryItem(name: "digest", value: "15"),
            URLQueryItem(name: "sid", value: songID),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "msgflag", value: "1"),
            URLQueryItem(name: "count", value: String(limit)),
            URLQueryItem(name: "newver", value: "3"),
            URLQueryItem(name: "uid", value: "0"),
        ]
        let root = try await fetchObject(components.url!)
        guard let code = text(root["code"]), code == "200" else {
            throw LXCommentsError.requestFailed
        }
        let key = hot ? "hot_comments" : "comments"
        let items = (root[key] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let content = firstText(item["msg"], item["content"]), !content.isEmpty else { return nil }
            return LXComment(id: text(item["id"]) ?? UUID().uuidString,
                             content: content,
                             author: firstText(item["u_name"], item["username"]),
                             avatarURL: firstText(item["u_pic"], item["avatar"]),
                             likedCount: int(item["like_num"]) ?? 0,
                             date: date(item["time"], unit: .seconds))
        }
    }

    private static func kugouComments(for track: Track, limit: Int) async throws -> LXCommentsResult {
        guard let hash = track.sourceMetadata["hash"], !hash.isEmpty else {
            throw LXCommentsError.missingSongID
        }
        async let latest = kugouList(hash: hash, path: "newest", limit: limit)
        async let hot = kugouList(hash: hash, path: "topliked", limit: limit)
        let latestResult = try? await latest
        let hotResult = try? await hot
        guard latestResult != nil || hotResult != nil else {
            throw LXCommentsError.requestFailed
        }
        return LXCommentsResult(hot: hotResult ?? [], latest: latestResult ?? [])
    }

    private static func kugouList(hash: String, path: String, limit: Int) async throws -> [LXComment] {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let params = [
            "dfid=0", "mid=16249512204336365674023395779019",
            "clienttime=\(timestamp)", "uuid=0", "extdata=\(hash)",
            "appid=1005", "code=fc4be23b4e972707f36b8a828a93ba8a",
            "schash=\(hash)", "clientver=11409", "p=1", "clienttoken=",
            "pagesize=\(limit)", "ver=10", "kugouid=0",
        ].joined(separator: "&")
        var components = URLComponents(string: "https://m.comment.service.kugou.com/r/v1/rank/\(path)")!
        components.queryItems = [
            URLQueryItem(name: "dfid", value: "0"),
            URLQueryItem(name: "mid", value: "16249512204336365674023395779019"),
            URLQueryItem(name: "clienttime", value: timestamp),
            URLQueryItem(name: "uuid", value: "0"),
            URLQueryItem(name: "extdata", value: hash),
            URLQueryItem(name: "appid", value: "1005"),
            URLQueryItem(name: "code", value: "fc4be23b4e972707f36b8a828a93ba8a"),
            URLQueryItem(name: "schash", value: hash),
            URLQueryItem(name: "clientver", value: "11409"),
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "clienttoken", value: ""),
            URLQueryItem(name: "pagesize", value: String(limit)),
            URLQueryItem(name: "ver", value: "10"),
            URLQueryItem(name: "kugouid", value: "0"),
            URLQueryItem(name: "signature", value: md5("OIlwieks28dk2k092lksi2UIkp\(params.split(separator: "&").map(String.init).sorted().joined())OIlwieks28dk2k092lksi2UIkp")),
        ]
        let root = try await fetchObject(components.url!)
        guard int(root["err_code"]) == 0 else { throw LXCommentsError.requestFailed }
        let items = (root["list"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let content = firstText(item["content"], item["text"]), !content.isEmpty else { return nil }
            let like = (item["like"] as? [String: Any]).flatMap { int($0["likenum"]) } ?? 0
            return LXComment(id: text(item["id"]) ?? UUID().uuidString,
                             content: content,
                             author: firstText(item["user_name"], item["username"]),
                             avatarURL: firstText(item["user_pic"], item["avatar"]),
                             likedCount: like,
                             date: date(item["addtime"], unit: .auto))
        }
    }

    private static func qqComments(for track: Track, limit: Int) async throws -> LXCommentsResult {
        let songID = try await qqSongID(for: track)
        async let latest = qqLatest(songID: songID, limit: limit)
        async let hot = qqHot(songID: songID, limit: limit)
        let latestResult = try? await latest
        let hotResult = try? await hot
        guard latestResult != nil || hotResult != nil else {
            throw LXCommentsError.requestFailed
        }
        return LXCommentsResult(hot: hotResult ?? [], latest: latestResult ?? [])
    }

    private static func qqSongID(for track: Track) async throws -> String {
        if let id = track.sourceMetadata["id"], !id.isEmpty { return id }
        guard let mid = track.sourceMetadata["songmid"], !mid.isEmpty else {
            throw LXCommentsError.missingSongID
        }
        let body: [String: Any] = [
            "comm": ["ct": "19", "cv": "1859", "uin": "0"],
            "req": ["module": "music.pf_song_detail_svr", "method": "get_song_detail_yqq",
                     "param": ["song_type": 0, "song_mid": mid]],
        ]
        let root = try await fetchObject(URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!,
                                         method: "POST", json: body)
        guard let req = root["req"] as? [String: Any],
              let data = req["data"] as? [String: Any],
              let info = data["track_info"] as? [String: Any],
              let id = text(info["id"]), !id.isEmpty else {
            throw LXCommentsError.requestFailed
        }
        return id
    }

    private static func qqLatest(songID: String, limit: Int) async throws -> [LXComment] {
        let form = [
            "uin": "0", "format": "json", "cid": "205360772", "reqtype": "2",
            "biztype": "1", "topid": songID, "cmd": "8", "needmusiccrit": "1",
            "pagenum": "0", "pagesize": String(limit),
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        let root = try await fetchObject(URL(string: "https://c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg")!,
                                         method: "POST", body: Data(form.utf8),
                                         headers: ["Content-Type": "application/x-www-form-urlencoded"])
        guard int(root["code"]) == 0,
              let comment = root["comment"] as? [String: Any] else { throw LXCommentsError.requestFailed }
        return parseQQ(comment["commentlist"] as? [[String: Any]] ?? [])
    }

    private static func qqHot(songID: String, limit: Int) async throws -> [LXComment] {
        let body: [String: Any] = [
            "comm": ["cv": 4747474, "ct": 24, "format": "json", "inCharset": "utf-8",
                     "outCharset": "utf-8", "notice": 0, "platform": "yqq.json", "needNewCode": 1, "uin": 0],
            "req": ["module": "music.globalComment.CommentRead", "method": "GetHotCommentList",
                     "param": ["BizType": 1, "BizId": songID, "LastCommentSeqNo": "",
                                "PageSize": limit, "PageNum": 0, "HotType": 1, "WithAirborne": 0, "PicEnable": 1]],
        ]
        let root = try await fetchObject(URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!,
                                         method: "POST", json: body,
                                         headers: ["Referer": "https://y.qq.com/", "Origin": "https://y.qq.com"])
        guard int(root["code"]) == 0,
              let req = root["req"] as? [String: Any], int(req["code"]) == 0,
              let data = req["data"] as? [String: Any],
              let list = data["CommentList"] as? [String: Any] else { throw LXCommentsError.requestFailed }
        return parseQQ(list["Comments"] as? [[String: Any]] ?? [])
    }

    private static func parseQQ(_ items: [[String: Any]]) -> [LXComment] {
        items.compactMap { item in
            guard let content = firstText(item["Content"], item["rootcommentcontent"]), !content.isEmpty else { return nil }
            return LXComment(id: "\(text(item["SeqNo"]) ?? "0")_\(text(item["CmId"]) ?? UUID().uuidString)",
                             content: content.replacingOccurrences(of: "\\n", with: "\n"),
                             author: firstText(item["Nick"], item["rootcommentnick"]),
                             avatarURL: firstText(item["Avatar"], item["avatarurl"]),
                             likedCount: int(item["PraiseNum"]) ?? int(item["praisenum"]) ?? 0,
                             date: date(item["PubTime"] ?? item["time"], unit: .auto))
        }
    }

    private static func miguComments(for track: Track, limit: Int) async throws -> LXCommentsResult {
        let songID = firstText(track.sourceMetadata["copyrightId"], track.sourceMetadata["songmid"], String(track.id))!
        var latestURL = URLComponents(string: "https://app.c.nf.migu.cn/MIGUM3.0/user/comment/stack/v1.0")!
        latestURL.queryItems = [URLQueryItem(name: "pageSize", value: String(limit)), URLQueryItem(name: "queryType", value: "1"),
                                URLQueryItem(name: "resourceId", value: songID), URLQueryItem(name: "resourceType", value: "2"),
                                URLQueryItem(name: "commentId", value: "")]
        var hotURL = URLComponents(string: "https://app.c.nf.migu.cn/MIGUM3.0/user/comment/stack/v1.0")!
        hotURL.queryItems = [URLQueryItem(name: "pageSize", value: String(limit)), URLQueryItem(name: "queryType", value: "2"),
                             URLQueryItem(name: "resourceId", value: songID), URLQueryItem(name: "resourceType", value: "2"),
                             URLQueryItem(name: "hotCommentStart", value: "0")]
        async let latest = miguList(url: latestURL.url!, key: "comments")
        async let hot = miguList(url: hotURL.url!, key: "hotComments")
        let latestResult = try? await latest
        let hotResult = try? await hot
        guard latestResult != nil || hotResult != nil else {
            throw LXCommentsError.requestFailed
        }
        return LXCommentsResult(hot: hotResult ?? [], latest: latestResult ?? [])
    }

    private static func miguList(url: URL, key: String) async throws -> [LXComment] {
        let root = try await fetchObject(url)
        guard text(root["code"]) == "000000", let data = root["data"] as? [String: Any] else {
            throw LXCommentsError.requestFailed
        }
        let items = (data[key] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let content = firstText(item["commentInfo"], item["content"]), !content.isEmpty else { return nil }
            let user = item["user"] as? [String: Any]
            let operations = item["opNumItem"] as? [String: Any]
            return LXComment(id: text(item["commentId"]) ?? UUID().uuidString,
                             content: content,
                             author: firstText(user?["nickName"], user?["nickname"]),
                             avatarURL: firstText(user?["middleIcon"], user?["bigIcon"], user?["smallIcon"]),
                             likedCount: int(operations?["thumbNum"]) ?? 0,
                             date: date(item["commentTime"], unit: .auto))
        }
    }

    private enum DateUnit { case seconds, auto }

    private static func date(_ value: Any?, unit: DateUnit) -> Date? {
        if let value = value as? NSNumber {
            return dateFromNumber(value.doubleValue, unit: unit)
        }
        guard let string = text(value), !string.isEmpty else { return nil }
        if let number = Double(string) { return dateFromNumber(number, unit: unit) }
        let formatter = ISO8601DateFormatter()
        if let result = formatter.date(from: string) { return result }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return local.date(from: string)
    }

    private static func dateFromNumber(_ value: Double, unit: DateUnit) -> Date? {
        guard value > 0 else { return nil }
        if case .seconds = unit { return Date(timeIntervalSince1970: value) }
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
    }

    private static func fetchObject(_ url: URL, method: String = "GET", body: Data? = nil,
                                    json: [String: Any]? = nil,
                                    headers: [String: String] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? body
        request.setValue("Moumusic/0.5", forHTTPHeaderField: "User-Agent")
        if json != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LXCommentsError.requestFailed
        }
        return value
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let value as String: return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }

    private static func firstText(_ values: Any?...) -> String? {
        values.compactMap(text).first { !$0.isEmpty }
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = text(value) { return Int(value) }
        return nil
    }

    private static func md5(_ value: String) -> String {
        let data = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum LXCommentsError: Error {
    case unsupported
    case missingSongID
    case requestFailed
}
