import Foundation

/// QQ Music account metadata used for optional recommendation synchronisation.
///
/// The account session is used for profile synchronisation and, when the
/// provider returns a full authorized URL, for QQ Music account playback.
actor QQMusicAPI {
    static let shared = QQMusicAPI()

    struct QRCodePayload: Sendable {
        let imageData: Data
        let qrsig: String
    }

    enum QRStatus: Sendable {
        case waiting
        case scanned
        case success(cookie: String)
        case expired
    }

    struct Profile {
        let id: String
        let name: String
        let avatarURL: String?
        /// A provider-issued session replacement, if the response rotated it.
        let refreshedCookie: String?
    }

    struct ResolvedAudio: Sendable {
        let url: URL
        let quality: String
    }

    enum APIError: LocalizedError {
        case invalidResponse
        case unavailable

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "QQ 音乐登录状态无法识别"
            case .unavailable: return "QQ 音乐登录已失效或 Cookie 已过期"
            }
        }
    }

    private let endpoint = URL(string: "https://c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg")!
    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        cookieStorage = HTTPCookieStorage()
        configuration.httpCookieStorage = cookieStorage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }

    /// QQ Music's old `/portal/login.html` page was removed.  The supported
    /// QR route is QQ's ptlogin flow: request the image, poll ptqrlogin, then
    /// follow the returned authorization URL so the Music cookies are stored.
    func qrCode() async throws -> QRCodePayload {
        var components = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrshow")!
        components.queryItems = [
            URLQueryItem(name: "appid", value: "716027609"),
            URLQueryItem(name: "e", value: "2"),
            URLQueryItem(name: "l", value: "M"),
            URLQueryItem(name: "s", value: "3"),
            URLQueryItem(name: "d", value: "72"),
            URLQueryItem(name: "v", value: "4"),
            URLQueryItem(name: "t", value: String(Double.random(in: 0..<1))),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
            URLQueryItem(name: "u1", value: "https://y.qq.com/")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response), let qrsig = Self.cookieValue("qrsig", from: response), !qrsig.isEmpty else {
            throw APIError.invalidResponse
        }
        guard !data.isEmpty else { throw APIError.invalidResponse }
        return QRCodePayload(imageData: data, qrsig: qrsig)
    }

    func poll(qrsig: String) async throws -> QRStatus {
        var components = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrlogin")!
        components.queryItems = [
            URLQueryItem(name: "u1", value: "https://y.qq.com/"),
            URLQueryItem(name: "ptqrtoken", value: String(Self.hash33(qrsig))),
            URLQueryItem(name: "ptredirect", value: "1"),
            URLQueryItem(name: "h", value: "1"),
            URLQueryItem(name: "t", value: "1"),
            URLQueryItem(name: "g", value: "1"),
            URLQueryItem(name: "from_ui", value: "1"),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "action", value: "0-0-\(Int(Date().timeIntervalSince1970))"),
            URLQueryItem(name: "js_ver", value: "10233"),
            URLQueryItem(name: "js_type", value: "1"),
            URLQueryItem(name: "login_sig", value: qrsig),
            URLQueryItem(name: "pt_uistyle", value: "40"),
            URLQueryItem(name: "aid", value: "716027609"),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("qrsig=\(qrsig)", forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response), let body = String(data: data, encoding: .utf8) else {
            throw APIError.requestFailed
        }

        let fields = Self.callbackFields(body)
        guard let status = fields.first else { throw APIError.invalidResponse }
        switch status {
        case "66": return .waiting
        case "67": return .scanned
        case "65": return .expired
        case "0":
            if fields.count > 2, let jumpURL = URL(string: fields[2]), jumpURL.scheme != nil {
                var follow = URLRequest(url: jumpURL)
                follow.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                follow.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
                _ = try? await session.data(for: follow)
            }
            let cookie = cookieHeader()
            guard !cookie.isEmpty else { throw APIError.unavailable }
            return .success(cookie: cookie)
        default:
            throw APIError.unavailable
        }
    }

    /// Resolve an authorized QQ Music URL through the account session. A
    /// missing/paid URL is reported to the caller so automatic playback can
    /// fall back to enabled LX sources instead of playing a preview segment.
    func musicURL(songMid: String, mediaMid: String?, quality: String,
                  cookie: String) async throws -> ResolvedAudio {
        let fields = Self.cookieFields(cookie)
        let uin = fields["qqmusic_uin"] ?? fields["uin"] ?? "0"
        let guid = String(Int.random(in: 100_000_000...2_000_000_000))
        let fileID = mediaMid?.isEmpty == false ? mediaMid! : songMid
        let file = Self.filename(for: quality, mediaMid: fileID)
        let requestBody: [String: Any] = [
            "comm": [
                "cv": 4747474,
                "ct": 24,
                "format": "json",
                "inCharset": "utf-8",
                "outCharset": "utf-8",
                "notice": 0,
                "platform": "yqq.json",
                "needNewCode": 1,
                "uin": Int(uin) ?? 0
            ],
            "req_1": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": [
                    "filename": [file],
                    "guid": guid,
                    "songmid": [songMid],
                    "songtype": [0],
                    "uin": uin,
                    "loginflag": 1,
                    "platform": "20"
                ]
            ]
        ]
        let endpoint = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        let container = (root["req_1"] as? [String: Any])
            ?? (root["req_0"] as? [String: Any])
        let payload = container?["data"] as? [String: Any]
        let info = (payload?["midurlinfo"] as? [[String: Any]])?.first
        guard let path = Self.text(info?["purl"]), !path.isEmpty else {
            throw APIError.unavailable
        }
        let rawURL: String
        if let absolute = URL(string: path), absolute.scheme != nil {
            rawURL = path
        } else if let host = (payload?["sip"] as? [String])?.first, !host.isEmpty {
            rawURL = host + path
        } else {
            throw APIError.unavailable
        }
        guard let url = URL(string: rawURL.replacingOccurrences(of: "http://", with: "https://")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw APIError.unavailable
        }
        let returnedName = Self.text(info?["filename"]) ?? file
        return ResolvedAudio(url: url, quality: Self.quality(forFilename: returnedName))
    }

    func profile(cookie: String) async throws -> Profile {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq"),
            URLQueryItem(name: "needNewCode", value: "0"),
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let object = Self.jsonObject(from: data) else {
            throw APIError.invalidResponse
        }

        if let code = Self.integer(in: object, keys: ["code", "subcode"]), code != 0 {
            throw APIError.unavailable
        }

        let dataObject = object["data"] as? [String: Any] ?? object
        let info = dataObject["info"] as? [String: Any]
            ?? dataObject["user"] as? [String: Any]
            ?? dataObject["profile"] as? [String: Any]
            ?? dataObject
        guard let id = Self.text(in: info, keys: ["uin", "uid", "user_id", "loginUin"]),
              !id.isEmpty else {
            throw APIError.unavailable
        }
        let name = Self.text(in: info, keys: ["nick", "nickname", "name", "nickName"])
            ?? "QQ 音乐用户"
        let avatar = Self.text(in: info, keys: ["logo", "avatar", "avatarUrl", "avatar_url"])
        return Profile(id: id, name: name, avatarURL: avatar,
                       refreshedCookie: Self.mergedCookie(
                        original: cookie,
                        response: response as? HTTPURLResponse
                       ))
    }

    private static func jsonObject(from data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        return try? JSONSerialization.jsonObject(
            with: Data(text[start...end].utf8)
        ) as? [String: Any]
    }

    private static func text(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func integer(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = object[key] as? String, let number = Int(value) { return number }
        }
        return nil
    }

    private static func isSuccess(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
    }

    private static func cookieValue(_ name: String, from response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        for (key, value) in http.allHeaderFields {
            guard String(describing: key).lowercased() == "set-cookie" else { continue }
            let text = String(describing: value)
            for item in text.split(separator: ",") {
                let pair = item.split(separator: ";", maxSplits: 1).first ?? ""
                let fields = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces) == name {
                    return fields[1]
                }
            }
        }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func callbackFields(_ body: String) -> [String] {
        guard let start = body.firstIndex(of: "("),
              let end = body.lastIndex(of: ")"), start < end else { return [] }
        let payload = body[body.index(after: start)..<end]
        return payload.split(separator: ",", omittingEmptySubsequences: false).map { value in
            var item = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if item.hasPrefix("'") && item.hasSuffix("'") && item.count >= 2 {
                item.removeFirst()
                item.removeLast()
            }
            return item.replacingOccurrences(of: "\\'", with: "'")
        }
    }

    private static func hash33(_ value: String) -> Int {
        var hash = 0
        for byte in value.utf8 {
            hash = (hash &* 33 &+ Int(byte)) & 0x7fffffff
        }
        return hash
    }

    private func cookieHeader() -> String {
        let allowed = Set([
            "uin", "skey", "p_uin", "p_skey", "pt4_token", "qqmusic_uin",
            "qqmusic_key", "qm_keyst", "musicid", "loginUin", "pskey"
        ])
        let cookies = cookieStorage.cookies?.filter {
            allowed.contains($0.name)
        } ?? []
        return cookies
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func mergedCookie(original: String, response: HTTPURLResponse?) -> String? {
        guard let response,
              let header = response.allHeaderFields.first(where: {
                  String(describing: $0.key).lowercased() == "set-cookie"
              })?.value else { return nil }
        var values = cookieFields(original)
        let text = String(describing: header)
        for part in text.split(separator: ",") {
            let pair = part.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            let fields = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if fields.count == 2 { values[fields[0].trimmingCharacters(in: .whitespaces)] = fields[1] }
        }
        return values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private static func cookieFields(_ cookie: String) -> [String: String] {
        cookie.split(separator: ";").reduce(into: [String: String]()) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1]
        }
    }

    private static func filename(for quality: String, mediaMid: String) -> String {
        switch quality.lowercased() {
        case "master", "atmos", "dolby", "surround", "hires", "flac", "lossless":
            return "F000\(mediaMid).flac"
        case "exhigh", "higher", "320k", "320":
            return "M800\(mediaMid).mp3"
        default:
            return "M500\(mediaMid).mp3"
        }
    }

    private static func quality(forFilename filename: String) -> String {
        let value = filename.uppercased()
        if value.hasPrefix("F000") { return "flac" }
        if value.hasPrefix("M800") { return "320k" }
        if value.hasPrefix("C600") { return "192k" }
        return "128k"
    }
}
