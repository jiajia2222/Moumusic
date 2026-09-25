import Foundation

/// Small Bilibili account and public-content client.
///
/// Account synchronisation validates the QR session and reads the public
/// account profile. Video content is kept separate from the LX music source;
/// this actor never turns Bilibili content into an LX `Track`.
actor BilibiliAPI {
    static let shared = BilibiliAPI()

    struct QRCodePayload: Sendable {
        let url: String
        let key: String
    }

    enum QRStatus: Sendable {
        case waiting
        case scanned
        case success(cookie: String)
        case expired
    }

    struct Profile: Sendable {
        let id: String
        let name: String
        let avatarURL: String?
    }

    struct Video: Identifiable, Hashable, Sendable {
        let bvid: String
        let aid: Int
        let cid: Int?
        let title: String
        let coverURL: String?
        let author: String
        let authorID: Int
        let authorAvatarURL: String?
        let description: String
        let duration: TimeInterval
        let durationText: String
        let playCount: Int
        let commentCount: Int
        let publishedAt: Date?
        let subtitles: [Subtitle]

        var id: String { bvid }
    }

    struct VideoQuality: Identifiable, Hashable, Sendable {
        let code: Int
        let title: String

        var id: Int { code }
    }

    struct Subtitle: Identifiable, Hashable, Sendable {
        let id: String
        let language: String
        let title: String
        let url: URL
    }

    struct SubtitleCue: Identifiable, Hashable, Sendable {
        let id: String
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    struct Playback: Sendable {
        let url: URL
        let quality: Int
        let qualities: [VideoQuality]
    }

    struct User: Identifiable, Hashable, Sendable {
        let mid: Int
        let name: String
        let avatarURL: String?
        let signature: String
        let followerCount: Int

        var id: Int { mid }
    }

    struct Collection: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let coverURL: String?
        let subtitle: String
        let itemCount: Int
    }

    struct SearchPage: Sendable {
        let videos: [Video]
        let users: [User]
        let collections: [Collection]
        let total: Int
    }

    enum CommentSort: String, Hashable, Sendable {
        case hot
        case latest
    }

    struct Comment: Identifiable, Hashable, Sendable {
        let id: String
        let author: String
        let avatarURL: String?
        let message: String
        let likeCount: Int
        let publishedAt: Date?
        let replyCount: Int
    }

    struct CommentPage: Sendable {
        let comments: [Comment]
        let total: Int
        let hasMore: Bool
    }

    enum APIError: LocalizedError {
        case requestFailed
        case invalidResponse
        case unavailable

        var errorDescription: String? {
            switch self {
            case .requestFailed: return "哔哩哔哩登录请求失败，请检查网络后重试"
            case .invalidResponse: return "哔哩哔哩登录返回格式无法识别"
            case .unavailable: return "哔哩哔哩登录已失效，请重新扫码"
            }
        }
    }

    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
    private var visitorBootstrapAttempted = false
    private let sessionCookieNames = [
        "DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct", "sid"
    ]
    private let visitorCookieNames = ["buvid3", "buvid4", "b_nut", "_uuid", "buvid_fp"]

    private init() {
        cookieStorage = HTTPCookieStorage()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = cookieStorage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }

    func qrCode() async throws -> QRCodePayload {
        let endpoint = URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate")!
        var request = URLRequest(url: endpoint.appending(queryItems: [
            URLQueryItem(name: "source", value: "main_web")
        ]))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response),
              let root = Self.object(data),
              let payload = root["data"] as? [String: Any],
              let url = Self.text(payload["url"]),
              let key = Self.text(payload["qrcode_key"]),
              !url.isEmpty, !key.isEmpty else {
            throw APIError.invalidResponse
        }
        return QRCodePayload(url: url, key: key)
    }

    func poll(key: String) async throws -> QRStatus {
        var components = URLComponents(
            string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll"
        )!
        components.queryItems = [
            URLQueryItem(name: "qrcode_key", value: key),
            URLQueryItem(name: "source", value: "main_web")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response), let root = Self.object(data),
              let payload = root["data"] as? [String: Any] else {
            throw APIError.requestFailed
        }

        // Bilibili has returned the status code both inside `data` and at the
        // response root over time.  Reading only data.code makes a successful
        // scan look like an expired/invalid QR code on some app versions.
        let code = Self.integer(payload["code"]) ?? Self.integer(root["code"])
        switch code {
        case 86101: return .waiting
        case 86090: return .scanned
        case 86038: return .expired
        case 0:
            var cookies = cookieHeader()
            // Some successful QR responses carry the login session in the
            // returned URL instead of Set-Cookie.  Extract only the provider's
            // session fields; never persist unrelated query parameters.
            let urlCookies = Self.cookieHeader(fromLoginURL: Self.text(payload["url"]) ?? Self.text(root["url"]))
            cookies = Self.mergedCookieHeaders(cookies, urlCookies)
            guard !cookies.isEmpty else { throw APIError.unavailable }
            return .success(cookie: cookies)
        default:
            throw APIError.unavailable
        }
    }

    func profile(cookie: String) async throws -> Profile {
        await ensureVisitorCookies()
        let endpoint = URL(string: "https://api.bilibili.com/x/web-interface/nav")!
        var request = URLRequest(url: endpoint)
        request.setValue(mergedRequestCookieHeader(cookie), forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response), let root = Self.object(data),
              Self.integer(root["code"]) == 0,
              let payload = root["data"] as? [String: Any],
              Self.bool(payload["isLogin"]) == true,
              let id = Self.text(payload["mid"]),
              let name = Self.text(payload["uname"]), !name.isEmpty else {
            throw APIError.unavailable
        }
        return Profile(id: id, name: name, avatarURL: Self.text(payload["face"]))
    }

    /// Public Bilibili content endpoints used by the native content page.
    /// These requests are deliberately kept separate from the LX music
    /// catalogue and never create a playable `Track`.
    func popularVideos(page: Int = 1, cookie: String? = nil) async throws -> [Video] {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/popular")!
        components.queryItems = [
            URLQueryItem(name: "ps", value: "20"),
            URLQueryItem(name: "pn", value: "\(max(1, page))")
        ]
        let root = try await requestObject(
            components.url!,
            cookie: cookie,
            referer: "https://www.bilibili.com/video/\(video.bvid)"
        )
        let data = root["data"] as? [String: Any]
        let rows = data?["list"] as? [[String: Any]] ?? []
        return rows.compactMap(Self.video)
    }

    func rankedVideos(categoryID: Int, cookie: String? = nil) async throws -> [Video] {
        if categoryID == 0 {
            return try await popularVideos(cookie: cookie)
        }
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/ranking/v2")!
        components.queryItems = [
            URLQueryItem(name: "rid", value: "\(categoryID)"),
            URLQueryItem(name: "type", value: "all")
        ]
        let root = try await requestObject(components.url!, cookie: cookie)
        let data = root["data"] as? [String: Any]
        let rows = data?["list"] as? [[String: Any]] ?? []
        return rows.compactMap(Self.video)
    }

    func searchVideos(keyword: String, page: Int = 1, cookie: String? = nil) async throws -> SearchPage {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/search/type")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "search_type", value: "video"),
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "order", value: "totalrank"),
            URLQueryItem(name: "highlight", value: "0")
        ]
        let root = try await requestObject(components.url!, cookie: cookie, referer: "https://search.bilibili.com/")
        let data = root["data"] as? [String: Any]
        let rows = data?["result"] as? [[String: Any]] ?? []
        return SearchPage(
            videos: rows.compactMap(Self.video),
            users: [],
            collections: [],
            total: Self.integer(data?["numResults"]) ?? rows.count
        )
    }

    func searchUsers(keyword: String, page: Int = 1, cookie: String? = nil) async throws -> [User] {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/search/type")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "search_type", value: "bili_user"),
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "order", value: "fans")
        ]
        let root = try await requestObject(components.url!, cookie: cookie, referer: "https://search.bilibili.com/")
        let data = root["data"] as? [String: Any]
        let rows = data?["result"] as? [[String: Any]] ?? []
        return rows.compactMap(Self.user)
    }

    func searchCollections(keyword: String, page: Int = 1, cookie: String? = nil) async throws -> [Collection] {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/search/type")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "search_type", value: "media_bangumi"),
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "order", value: "totalrank")
        ]
        let root = try await requestObject(components.url!, cookie: cookie, referer: "https://search.bilibili.com/")
        let data = root["data"] as? [String: Any]
        let rows = data?["result"] as? [[String: Any]] ?? []
        return rows.compactMap(Self.collection)
    }

    func videoDetail(bvid: String, cookie: String? = nil) async throws -> Video {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/view")!
        components.queryItems = [URLQueryItem(name: "bvid", value: bvid)]
        let root = try await requestObject(components.url!, cookie: cookie)
        guard let data = root["data"] as? [String: Any], let video = Self.video(data) else {
            throw APIError.invalidResponse
        }
        return video
    }

    func comments(aid: Int, page: Int = 1, sort: CommentSort = .hot,
                  cookie: String? = nil) async throws -> CommentPage {
        var components = URLComponents(string: "https://api.bilibili.com/x/v2/reply")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "oid", value: "\(aid)"),
            URLQueryItem(name: "mode", value: sort == .hot ? "3" : "2"),
            URLQueryItem(name: "next", value: "\(max(1, page))"),
            URLQueryItem(name: "ps", value: "20")
        ]
        let root = try await requestObject(components.url!, cookie: cookie)
        let data = root["data"] as? [String: Any]
        let rows = data?["replies"] as? [[String: Any]] ?? []
        let comments = rows.compactMap(Self.comment)
        let cursor = data?["cursor"] as? [String: Any]
        let isEnd = Self.bool(cursor?["is_end"]) ?? (comments.count < 20)
        return CommentPage(
            comments: comments,
            total: Self.integer(data?["upper"]) ?? comments.count,
            hasMore: !isEnd
        )
    }

    /// Resolves a single, AVPlayer-compatible progressive stream. The response
    /// also returns the qualities that Bilibili actually made available for
    /// this account/video, so the UI never advertises unavailable resolutions.
    func playback(for video: Video, quality: Int? = nil, cookie: String? = nil) async throws -> Playback {
        guard let cid = video.cid else { throw APIError.invalidResponse }
        let requestedQuality = quality ?? 80
        var components = URLComponents(string: "https://api.bilibili.com/x/player/playurl")!
        components.queryItems = [
            URLQueryItem(name: "bvid", value: video.bvid),
            URLQueryItem(name: "cid", value: "\(cid)"),
            URLQueryItem(name: "qn", value: "\(requestedQuality)"),
            URLQueryItem(name: "fnval", value: "0"),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "fourk", value: "1")
        ]
        let root = try await requestObject(components.url!, cookie: cookie)
        guard let data = root["data"] as? [String: Any] else { throw APIError.invalidResponse }
        let qualities = Self.qualities(data)
        let actualQuality = Self.integer(data["quality"]) ?? requestedQuality
        if let rows = data["durl"] as? [[String: Any]],
           let value = rows.first.flatMap({ Self.text($0["url"]) }),
           let url = URL(string: value) {
            return Playback(url: url, quality: actualQuality, qualities: qualities)
        }
        if let dash = data["dash"] as? [String: Any],
           let rows = dash["video"] as? [[String: Any]],
           let value = rows.first.flatMap({ Self.text($0["baseUrl"] ?? $0["base_url"]) }),
           let url = URL(string: value) {
            return Playback(url: url, quality: actualQuality, qualities: qualities)
        }
        throw APIError.unavailable
    }

    /// Compatibility convenience for existing callers.
    func playableURL(for video: Video, cookie: String? = nil) async throws -> URL {
        try await playback(for: video, cookie: cookie).url
    }

    func subtitleCues(for subtitle: Subtitle) async throws -> [SubtitleCue] {
        await ensureVisitorCookies()
        var request = URLRequest(url: subtitle.url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let cookies = mergedRequestCookieHeader(nil)
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response),
              let root = Self.object(data),
              let rows = root["body"] as? [[String: Any]] else {
            throw APIError.invalidResponse
        }
        return rows.compactMap { row in
            guard let start = Self.double(row["from"]),
                  let end = Self.double(row["to"]),
                  let text = Self.text(row["content"]), !text.isEmpty else { return nil }
            return SubtitleCue(
                id: "\(start)-\(end)-\(text.hashValue)",
                start: start,
                end: end,
                text: text
            )
        }
    }

    private func requestObject(_ url: URL, cookie: String? = nil,
                               referer: String = "https://www.bilibili.com/") async throws -> [String: Any] {
        await ensureVisitorCookies()
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let cookies = mergedRequestCookieHeader(cookie), !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response), let root = Self.object(data) else {
            throw APIError.requestFailed
        }
        guard let code = Self.integer(root["code"]), code == 0 else {
            throw APIError.unavailable
        }
        return root
    }

    private static func video(_ raw: [String: Any]) -> Video? {
        let bvid = text(raw["bvid"]) ?? ""
        guard !bvid.isEmpty else { return nil }
        let owner = raw["owner"] as? [String: Any]
        let stat = raw["stat"] as? [String: Any]
        let firstPage = (raw["pages"] as? [[String: Any]])?.first
        let durationText = text(raw["duration"] ?? firstPage?["duration"]) ?? ""
        let subtitleRows = ((raw["subtitle"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        return Video(
            bvid: bvid,
            aid: integer(raw["aid"] ?? raw["id"]) ?? 0,
            cid: integer(raw["cid"] ?? firstPage?["cid"]),
            title: stripHTML(text(raw["title"]) ?? ""),
            coverURL: imageURL(text(raw["pic"])),
            author: stripHTML(text(raw["author"]) ?? text(owner?["name"]) ?? ""),
            authorID: integer(raw["mid"] ?? owner?["mid"]) ?? 0,
            authorAvatarURL: imageURL(text(raw["face"]) ?? text(owner?["face"])),
            description: stripHTML(text(raw["description"]) ?? text(raw["desc"]) ?? ""),
            duration: parseDuration(durationText),
            durationText: durationText,
            playCount: integer(raw["play"] ?? stat?["view"]) ?? 0,
            commentCount: integer(raw["review"] ?? stat?["reply"]) ?? 0,
            publishedAt: integer(raw["pubdate"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            subtitles: subtitleRows.compactMap(Self.subtitle)
        )
    }

    private static func subtitle(_ raw: [String: Any]) -> Subtitle? {
        guard let rawURL = text(raw["subtitle_url"]), !rawURL.isEmpty else { return nil }
        let normalizedURL: String
        if rawURL.hasPrefix("//") {
            normalizedURL = "https:" + rawURL
        } else if rawURL.hasPrefix("http://") {
            normalizedURL = "https://" + rawURL.dropFirst(7)
        } else {
            normalizedURL = rawURL
        }
        guard let url = URL(string: normalizedURL) else { return nil }
        let language = text(raw["lan"]) ?? ""
        return Subtitle(
            id: text(raw["id"]) ?? normalizedURL,
            language: language,
            title: text(raw["lan_doc"]) ?? language,
            url: url
        )
    }

    private static func qualities(_ data: [String: Any]) -> [VideoQuality] {
        let formats = (data["support_formats"] as? [[String: Any]] ?? []).compactMap { raw -> VideoQuality? in
            guard let code = integer(raw["quality"] ?? raw["qn"]), code > 0 else { return nil }
            let title = text(raw["new_description"] ?? raw["display_desc"] ?? raw["description"])
                ?? "\(code)p"
            return VideoQuality(code: code, title: title)
        }
        if !formats.isEmpty {
            return Array(Dictionary(grouping: formats, by: \.code).values.compactMap(\.first))
                .sorted { $0.code > $1.code }
        }

        let codes = data["accept_quality"] as? [Any] ?? []
        let descriptions = data["accept_description"] as? [Any] ?? []
        return codes.enumerated().compactMap { index, value in
            guard let code = integer(value), code > 0 else { return nil }
            let title = index < descriptions.count ? (text(descriptions[index]) ?? "\(code)p") : "\(code)p"
            return VideoQuality(code: code, title: title)
        }
        .sorted { $0.code > $1.code }
    }

    private static func user(_ raw: [String: Any]) -> User? {
        guard let mid = integer(raw["mid"]), mid > 0 else { return nil }
        return User(
            mid: mid,
            name: stripHTML(text(raw["uname"]) ?? text(raw["author"]) ?? ""),
            avatarURL: imageURL(text(raw["upic"] ?? raw["face"])),
            signature: stripHTML(text(raw["usign"] ?? raw["sign"]) ?? ""),
            followerCount: integer(raw["fans"] ?? raw["fans_num"]) ?? 0
        )
    }

    private static func collection(_ raw: [String: Any]) -> Collection? {
        let id = text(raw["season_id"] ?? raw["media_id"] ?? raw["id"]) ?? ""
        let title = stripHTML(text(raw["title"]) ?? text(raw["season_title"]) ?? "")
        guard !id.isEmpty, !title.isEmpty else { return nil }
        return Collection(
            id: id,
            title: title,
            coverURL: imageURL(text(raw["cover"] ?? raw["pic"])),
            subtitle: stripHTML(text(raw["desc"] ?? raw["description"] ?? raw["author"]) ?? ""),
            itemCount: integer(raw["eps"] ?? raw["episode_count"] ?? raw["total_count"]) ?? 0
        )
    }

    private static func comment(_ raw: [String: Any]) -> Comment? {
        let member = raw["member"] as? [String: Any]
        let content = raw["content"] as? [String: Any]
        let id = text(raw["rpid"] ?? raw["rpid_str"] ?? raw["id"]) ?? UUID().uuidString
        let message = stripHTML(text(content?["message"]) ?? "")
        guard !message.isEmpty else { return nil }
        return Comment(
            id: id,
            author: text(member?["uname"]) ?? "哔哩哔哩用户",
            avatarURL: imageURL(text(member?["avatar"])),
            message: message,
            likeCount: integer(raw["like"]) ?? 0,
            publishedAt: integer(raw["ctime"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            replyCount: integer(raw["rcount"]) ?? 0
        )
    }

    private func cookieHeader() -> String {
        let cookies = cookieStorage.cookies?.filter {
            sessionCookieNames.contains($0.name)
        } ?? []
        return cookies
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func cookieHeader(fromLoginURL rawURL: String?) -> String {
        let allowed = ["DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct", "sid"]
        var values: [String: String] = [:]

        guard let rawURL, !rawURL.isEmpty else { return "" }
        if let components = URLComponents(string: rawURL) {
            for item in components.queryItems ?? [] where allowed.contains(item.name) {
                guard let value = item.value, !value.isEmpty else { continue }
                values[item.name] = value
            }
        }

        // Recent Bilibili responses can escape the complete URL more than
        // once. Always merge a manually-decoded query so a valid QR login is
        // not later reported as expired just because one session field was
        // hidden inside an encoded redirect URL.
        var decodedURL = rawURL
        for _ in 0..<2 {
            guard let decoded = decodedURL.removingPercentEncoding,
                  decoded != decodedURL else { break }
            decodedURL = decoded
        }
        let query = decodedURL.split(separator: "?", maxSplits: 1).dropFirst().first ?? ""
        for item in query.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let name = pair[0].removingPercentEncoding ?? pair[0]
            let value = pair[1].removingPercentEncoding ?? pair[1]
            if allowed.contains(name), !value.isEmpty { values[name] = value }
        }
        return values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func mergedCookieHeaders(_ first: String, _ second: String) -> String {
        var values: [String: String] = [:]
        for header in [first, second] {
            for item in header.split(separator: ";") {
                let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                values[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1]
            }
        }
        return values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// Bilibili's playback edge can return HTTP 412 when a fresh client lacks
    /// its normal visitor fingerprint. Bootstrap only public visitor cookies;
    /// account cookies remain in the Keychain-backed session store.
    private func ensureVisitorCookies() async {
        guard !visitorBootstrapAttempted else { return }
        visitorBootstrapAttempted = true
        guard !hasVisitorCookies else { return }

        guard let endpoint = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") else { return }
        var request = URLRequest(url: endpoint)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              Self.isSuccess(response),
              let root = Self.object(data),
              Self.integer(root["code"]) == 0,
              let payload = root["data"] as? [String: Any] else { return }

        if let buvid3 = Self.text(payload["b_3"]) { storeVisitorCookie(name: "buvid3", value: buvid3) }
        if let buvid4 = Self.text(payload["b_4"]) { storeVisitorCookie(name: "buvid4", value: buvid4) }
    }

    private var hasVisitorCookies: Bool {
        (cookieStorage.cookies ?? []).contains { visitorCookieNames.contains($0.name) }
    }

    private func storeVisitorCookie(name: String, value: String) {
        guard let cookie = HTTPCookie(properties: [
            .domain: ".bilibili.com",
            .path: "/",
            .name: name,
            .value: value,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(365 * 24 * 60 * 60)
        ]) else { return }
        cookieStorage.setCookie(cookie)
    }

    private func mergedRequestCookieHeader(_ accountCookie: String?) -> String {
        let visitorCookies = (cookieStorage.cookies ?? [])
            .filter { visitorCookieNames.contains($0.name) }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        return Self.mergedCookieHeaders(visitorCookies, accountCookie ?? "")
    }

    private static func isSuccess(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value.isEmpty ? nil : value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func imageURL(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.hasPrefix("http://") ? "https://" + value.dropFirst(7) : value
    }

    private static func parseDuration(_ value: String) -> TimeInterval {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return 0 }
        return parts.reversed().enumerated().reduce(0) { result, item in
            result + item.element * pow(60, Double(item.offset))
        }
    }

    private static func stripHTML(_ value: String) -> String {
        var output = value
        ["<em class=\"keyword\">", "</em>", "<em>", "</em>"].forEach {
            output = output.replacingOccurrences(of: $0, with: "")
        }
        if let expression = try? NSRegularExpression(pattern: "<[^>]+>") {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = expression.stringByReplacingMatches(in: output, range: range, withTemplate: "")
        }
        return output
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
