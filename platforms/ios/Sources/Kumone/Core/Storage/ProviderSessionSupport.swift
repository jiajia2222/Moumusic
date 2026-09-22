import Foundation
import Security

enum ProviderSessionSupport {
    static func normalizedCookie(_ rawCookie: String) -> String {
        var value = rawCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "cookie:", options: [.caseInsensitive, .anchored]) {
            value.removeSubrange(range)
        }
        value = value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func looksLikeCookie(_ value: String) -> Bool {
        guard value.count <= 32_000, value.contains("=") else { return false }
        return value.split(separator: ";").contains {
            $0.split(separator: "=", maxSplits: 1).count == 2
        }
    }

    static func readCookie(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "cookie",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func writeCookie(_ cookie: String, service: String) throws {
        let data = Data(cookie.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "cookie",
        ]
        var attributes: [String: Any] = [kSecValueData as String: data]
#if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SessionError.storageFailed }
        } else if status != errSecSuccess {
            throw SessionError.storageFailed
        }
    }

    static func deleteCookie(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "cookie",
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum SessionError: LocalizedError {
        case storageFailed
        var errorDescription: String? { "无法安全保存登录状态，请稍后重试" }
    }
}
