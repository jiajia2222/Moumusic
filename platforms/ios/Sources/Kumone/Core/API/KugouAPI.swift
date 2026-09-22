import Foundation
import Security

/// Minimal KuGou account client for validating a user-provided Web Cookie.
/// Audio resolution remains entirely inside the configured LX source.
actor KugouAPI {
    static let shared = KugouAPI()

    struct Profile {
        let id: String
        let name: String
        let avatarURL: String?
        let refreshedCookie: String?
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

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
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
