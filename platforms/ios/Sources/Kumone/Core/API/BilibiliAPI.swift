import Foundation

/// Small, first-party Bilibili account client.
///
/// This is account synchronisation only: it validates the QR session and
/// reads the public account profile. It is deliberately not an audio source.
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
        var request = URLRequest(url: endpoint)
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
        components.queryItems = [URLQueryItem(name: "qrcode_key", value: key)]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response), let root = Self.object(data),
              let payload = root["data"] as? [String: Any] else {
            throw APIError.requestFailed
        }

        let code = Self.integer(payload["code"])
        switch code {
        case 86101: return .waiting
        case 86090: return .scanned
        case 86038: return .expired
        case 0:
            let cookies = cookieHeader()
            guard !cookies.isEmpty else { throw APIError.unavailable }
            return .success(cookie: cookies)
        default:
            throw APIError.unavailable
        }
    }

    func profile(cookie: String) async throws -> Profile {
        let endpoint = URL(string: "https://api.bilibili.com/x/web-interface/nav")!
        var request = URLRequest(url: endpoint)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
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

    private func cookieHeader() -> String {
        let cookies = cookieStorage.cookies?.filter {
            ["DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct", "sid"].contains($0.name)
        } ?? []
        return cookies
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
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
}
