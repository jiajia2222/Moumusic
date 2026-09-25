import Foundation
import Security
import CryptoKit

/// KuGou account client for native QR login, session validation, and
/// provider-authorized audio resolution. The account Cookie is only sent to
/// KuGou's own endpoints; third-party LX sources never receive it.
actor KugouAPI {
    static let shared = KugouAPI()

    struct Profile {
        let id: String
        let name: String
        let avatarURL: String?
        let refreshedCookie: String?
    }

    struct ResolvedAudio: Sendable {
        let url: URL
        let quality: String
    }

    struct QRCodePayload: Sendable {
        let url: String
        let key: String
        let cookie: String
    }

    enum QRStatus: Sendable {
        case waiting
        case scanned
        case success(cookie: String)
        case expired
    }

    enum APIError: LocalizedError {
        case invalidCookie
        case invalidResponse
        case unavailable

        var errorDescription: String? {
            switch self {
            case .invalidCookie: return "酷狗 Cookie 缺少 token 或 userid"
            case .invalidResponse: return "酷狗登录状态无法识别"
            case .unavailable: return "酷狗登录已失效或 Cookie 已过期"
            }
        }
    }

    private let endpoint = URL(string: "https://usercenter.kugou.com/v3/get_my_info")!
    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage
    private let deviceMid = String(Int64(Date().timeIntervalSince1970 * 1000))

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        let cookieStorage = HTTPCookieStorage()
        configuration.httpCookieStorage = cookieStorage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        self.cookieStorage = cookieStorage
        session = URLSession(configuration: configuration)
    }

    /// Native KuGou QR login. This is the same login-user flow used by the
    /// open KuGouMusicApi adapter; it does not open `/loginReg.php` in a web
    /// view and does not require a third-party API key.
    func qrCode() async throws -> QRCodePayload {
        let clientTime = Int(Date().timeIntervalSince1970)
        var parameters = baseParameters(clientTime: clientTime)
        parameters["appid"] = "1001"
        parameters["type"] = "1"
        parameters["plat"] = "4"
        parameters["srcappid"] = "2919"
        parameters["qrcode_txt"] = "https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=1005&"
        parameters["signature"] = Self.signature(parameters)

        let endpoint = URL(string: "https://login-user.kugou.com/v2/qrcode")!
        let request = try Self.request(endpoint: endpoint, parameters: parameters)
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response),
              let root = Self.jsonObject(from: data),
              let payload = root["data"] as? [String: Any],
              let key = Self.text(payload["qrcode"] ?? payload["key"] ?? root["qrcode"]),
              !key.isEmpty else {
            throw APIError.invalidResponse
        }

        return QRCodePayload(
            url: "https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=\(key)",
            key: key,
            cookie: cookieHeader()
        )
    }

    func poll(qrcode: String, cookie: String) async throws -> QRStatus {
        let clientTime = Int(Date().timeIntervalSince1970)
        var parameters = baseParameters(clientTime: clientTime)
        parameters["plat"] = "4"
        parameters["appid"] = "1005"
        parameters["srcappid"] = "2919"
        parameters["qrcode"] = qrcode
        parameters["dev"] = Self.cookieFields(cookie)["kugou_api_dev"] ?? ""
        parameters["signature"] = Self.signature(parameters)

        let endpoint = URL(string: "https://login-user.kugou.com/v2/get_userinfo_qrcode")!
        var request = try Self.request(endpoint: endpoint, parameters: parameters)
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response), let root = Self.jsonObject(from: data) else {
            throw APIError.invalidResponse
        }

        let payload = root["data"] as? [String: Any] ?? root
        switch Self.integer(payload["status"] ?? root["status"]) {
        case 0: return .expired
        case 1: return .waiting
        case 2, 3: return .scanned
        case 4:
            guard let token = Self.text(payload["token"] ?? root["token"]),
                  let userID = Self.text(payload["userid"] ?? payload["user_id"] ?? root["userid"]),
                  !token.isEmpty, !userID.isEmpty else {
                throw APIError.unavailable
            }
            let sessionCookie = [cookie, "token=\(token)", "userid=\(userID)"]
                .filter { !$0.isEmpty }
                .joined(separator: "; ")
            return .success(cookie: sessionCookie)
        default:
            throw APIError.unavailable
        }
    }

    func profile(cookie: String) async throws -> Profile {
        let fields = Self.cookieFields(cookie)
        guard let token = fields["token"],
              let userID = fields["userid"] ?? fields["kugooid"],
              !token.isEmpty, !userID.isEmpty else {
            throw APIError.invalidCookie
        }

        let visitTime = Int(Date().timeIntervalSince1970)
        let payload = "{\"token\":\"\(Self.jsonEscaped(token))\",\"clienttime\":\(visitTime)}"
        guard let signature = Self.rawRSAHex(Data(payload.utf8)) else {
            throw APIError.invalidResponse
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "plat", value: "1")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("usercenter.kugou.com", forHTTPHeaderField: "x-router")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let body = [
            "visit_time=\(visitTime)",
            "usertype=1",
            "p=\(signature)",
            "userid=\(Self.formEncoded(userID))",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }

        if let code = Self.integer(in: root, keys: ["status", "status_code", "code"]),
           code != 0, code != 200 {
            throw APIError.unavailable
        }
        let info = (root["data"] as? [String: Any])
            ?? (root["user"] as? [String: Any])
            ?? root
        guard let id = Self.text(in: info, keys: ["userid", "user_id", "uid", "kugooid"]) ?? fields["userid"],
              let name = Self.text(in: info, keys: ["nickname", "nick_name", "username", "name", "nick"]),
              !name.isEmpty else {
            throw APIError.unavailable
        }
        return Profile(
            id: id,
            name: name,
            avatarURL: Self.text(in: info, keys: ["avatar", "avatar_url", "avatarUrl", "headurl"]),
            refreshedCookie: Self.mergedCookie(
                original: cookie,
                response: response as? HTTPURLResponse
            )
        )
    }

    /// Resolves a KuGou catalogue hash through the authenticated provider
    /// route. The authorization step is deliberately kept here instead of in
    /// LXUserAPIService so the account token never enters an LX source script.
    func musicURL(hash: String, quality: String, cookie: String,
                  albumID: String? = nil, albumAudioID: String? = nil) async throws -> ResolvedAudio {
        let normalizedHash = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHash.isEmpty else { throw APIError.invalidResponse }

        var fields = Self.cookieFields(cookie)
        let dfid = fields["dfid"] ?? Self.randomDfid()
        fields["dfid"] = dfid
        let requestCookie = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")

        let authorization = try await resolveAuthorization(
            hash: normalizedHash,
            albumAudioID: albumAudioID,
            cookie: requestCookie,
            fields: fields
        )

        let requestedQuality = Self.qualityToken(for: quality)
        let params: [String: String] = [
            "album_id": albumID ?? "0",
            "album_audio_id": albumAudioID ?? "0",
            "area_code": "1",
            "auth": authorization.auth,
            "behavior": "play",
            "cdnBackup": "1",
            "clientver": "11561",
            "dfid": dfid,
            "hash": normalizedHash,
            "module": "",
            "module_id": "51",
            "mtype": "0",
            "need_m": "0",
            "need_ogg": "1",
            "open_time": authorization.openTime,
            "page_id": "151369488",
            "pid": "2",
            "pidversion": "3001",
            "ppage_id": "463467626,350369493,788954147",
            "ptype": "0",
            "quality": requestedQuality,
            "ssa_flag": "is_fromtrack",
            "version": "11430",
        ]
        let endpoint = URL(string: "https://trackercdngz.kugou.com/tracker/v5/url")!
        var request = try Self.request(endpoint: endpoint, parameters: params)
        request.setValue(requestCookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response), let root = Self.jsonObject(from: data) else {
            throw APIError.invalidResponse
        }

        let payload = root["data"] ?? root
        guard let rawURL = Self.firstURL(in: payload),
              let url = URL(string: rawURL.replacingOccurrences(of: "http://", with: "https://")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw APIError.unavailable
        }
        let returnedQuality = Self.text(in: (payload as? [String: Any]) ?? [:], keys: [
            "quality", "type", "format", "ext", "extension", "bitrate"
        ])
        return ResolvedAudio(
            url: url,
            quality: Self.canonicalQuality(returnedQuality ?? requestedQuality)
        )
    }

    private func resolveAuthorization(hash: String, albumAudioID: String?, cookie: String,
                                      fields: [String: String]) async throws -> (auth: String, openTime: String) {
        let params = [
            "authorization": fields["auth"] ?? "",
            "module_id": "51",
            "album_audio_id": albumAudioID ?? "0",
            "clientver": "11561",
            "hash": hash,
        ]
        let endpoint = URL(string: "https://trackercdngz.kugou.com/v1/authorization")!
        var request = try Self.request(endpoint: endpoint, parameters: params)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response), let root = Self.jsonObject(from: data) else {
            throw APIError.invalidResponse
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        guard let auth = Self.text(in: payload, keys: ["auth", "authorization"]),
              let openTime = Self.text(in: payload, keys: ["open_time", "openTime"]),
              !auth.isEmpty, !openTime.isEmpty else {
            throw APIError.unavailable
        }
        return (auth, openTime)
    }

    private func baseParameters(clientTime: Int) -> [String: String] {
        [
            "dfid": "-",
            "mid": deviceMid,
            "uuid": "-",
            "appid": "1005",
            "clientver": "20489",
            "clienttime": String(clientTime),
        ]
    }

    private static func request(endpoint: URL, parameters: [String: String]) throws -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "kg-rc")
        request.setValue("5d816a0", forHTTPHeaderField: "kg-thash")
        request.setValue("1", forHTTPHeaderField: "kg-rec")
        request.setValue("B9EDA08A64250DEFFBCADDEE00F8F25F", forHTTPHeaderField: "kg-rf")
        if let dfid = parameters["dfid"] { request.setValue(dfid, forHTTPHeaderField: "dfid") }
        if let clientTime = parameters["clienttime"] { request.setValue(clientTime, forHTTPHeaderField: "clienttime") }
        if let mid = parameters["mid"] { request.setValue(mid, forHTTPHeaderField: "mid") }
        return request
    }

    private func cookieHeader() -> String {
        (cookieStorage.cookies ?? [])
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func signature(_ parameters: [String: String]) -> String {
        let joined = parameters
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined()
        return md5("NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt\(joined)NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt")
    }

    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isSuccess(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
    }

    private static func jsonObject(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func text(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func firstURL(in value: Any) -> String? {
        if let string = value as? String,
           let url = URL(string: string),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return string
        }
        if let object = value as? [String: Any] {
            let preferredKeys = ["url", "play_url", "playUrl", "audio_url", "audioUrl",
                                 "backup_url", "backupUrl", "file_url", "fileUrl"]
            for key in preferredKeys where object[key] != nil {
                if let result = firstURL(in: object[key]!) { return result }
            }
            for child in object.values {
                if let result = firstURL(in: child) { return result }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let result = firstURL(in: child) { return result }
            }
        }
        return nil
    }

    private static func randomDfid() -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<24).compactMap { _ in characters.randomElement() })
    }

    private static func qualityToken(for value: String) -> String {
        switch value.lowercased().replacingOccurrences(of: " ", with: "") {
        case "standard", "128", "128k": return "128"
        case "higher", "exhigh", "320", "320k": return "320"
        case "lossless", "flac": return "flac"
        case "hires", "flac24bit", "highres": return "high"
        case "atmos": return "viper_atmos"
        case "master", "jymaster": return "viper_tape"
        case "dolby", "surround": return "viper_clear"
        default: return value
        }
    }

    private static func canonicalQuality(_ value: String) -> String {
        switch value.lowercased().replacingOccurrences(of: " ", with: "") {
        case "128", "128k", "mp3": return "128k"
        case "320", "320k": return "320k"
        case "flac", "lossless": return "flac"
        case "high", "hires", "flac24", "flac24bit": return "flac24bit"
        case "viper_atmos", "atmos": return "atmos"
        case "viper_tape", "master": return "jymaster"
        case "viper_clear", "dolby": return "dolby"
        default: return value
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func cookieFields(_ cookie: String) -> [String: String] {
        cookie.split(separator: ";").reduce(into: [String: String]()) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return value }
        return String(encoded.dropFirst().dropLast())
    }

    /// KuGou's user-center request uses a raw RSA operation over a 1024-bit
    /// public key, represented as uppercase hexadecimal. Security.framework
    /// performs the operation locally; the Cookie and token never leave the
    /// request that is already being made to KuGou.
    private static func rawRSAHex(_ data: Data) -> String? {
        let modulusBase64 = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIAG7QOELSYoIJvTFJhMpe1s/gbjDJX51HBNnEl5HXqTW6lQ7LC8jr9fWZTwusknp+sVGzwd40MwP6U5yDE27M/X1+UR4tvOGOqp94TJtQ1EPnWGWXngpeIW5GxoQGao1rmYWAu6oi1z9XkChrsUdC6DJE5E221wf/4WLFxwAtRQIDAQAB"
        guard let der = Data(base64Encoded: modulusBase64) else { return nil }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionRaw) else { return nil }
        let keyLength = SecKeyGetBlockSize(key)
        guard data.count <= keyLength else { return nil }
        var padded = Data(repeating: 0, count: keyLength)
        // Match KuGou's client implementation: the payload occupies the
        // leading bytes and the remaining block is zero-filled.
        padded.replaceSubrange(0..<data.count, with: data)
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            key, .rsaEncryptionRaw, padded as CFData, &error
        ) as Data? else { return nil }
        return encrypted.map { String(format: "%02X", $0) }.joined()
    }

    private static func text(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
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

    private static func mergedCookie(original: String, response: HTTPURLResponse?) -> String? {
        guard let response,
              let header = response.allHeaderFields.first(where: {
                  String(describing: $0.key).lowercased() == "set-cookie"
              })?.value else { return nil }
        var values = cookieFields(original)
        for part in String(describing: header).split(separator: ",") {
            let pair = part.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            let fields = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if fields.count == 2 { values[fields[0].trimmingCharacters(in: .whitespaces)] = fields[1] }
        }
        return values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

}
