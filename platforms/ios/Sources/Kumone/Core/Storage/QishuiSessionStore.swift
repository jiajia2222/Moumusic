import Foundation
import Security
import Combine

#if os(iOS) || os(macOS)
@MainActor
final class QishuiSessionStore: ObservableObject {
    static let shared = QishuiSessionStore()

    enum SessionError: LocalizedError {
        case emptyCookie
        case invalidCookie
        case validationFailed

        var errorDescription: String? {
            switch self {
            case .emptyCookie: return "请粘贴汽水音乐 Cookie"
            case .invalidCookie: return "Cookie 格式不正确，请粘贴浏览器中的完整 Cookie"
            case .validationFailed: return "汽水登录已失效或 Cookie 已过期"
            }
        }
    }

    @Published private(set) var isLoggedIn = false
    @Published private(set) var profileName: String?
    @Published private(set) var sessionRevision = 0

    /// This value is intentionally readable only inside the app's networking
    /// layer. It is never written to UserDefaults or included in diagnostics.
    var cookie: String? { storedCookie }

    private let keychainService = "com.moumusic.qishui.session"
    private let keychainAccount = "cookie"
    private var storedCookie: String?

    private init() {
        storedCookie = readCookie()
        isLoggedIn = storedCookie != nil
    }

    func signIn(cookie rawCookie: String) async throws {
        let cookie = Self.normalizedCookie(rawCookie)
        guard !cookie.isEmpty else { throw SessionError.emptyCookie }
        guard Self.looksLikeCookie(cookie) else { throw SessionError.invalidCookie }

        // Validate before persisting. A rejected cookie never remains in the
        // keychain, and the error path never echoes the credential.
        guard let profile = try? await QishuiAPI.shared.profile(cookie: cookie) else {
            throw SessionError.validationFailed
        }
        try writeCookie(cookie)
        storedCookie = cookie
        if let refreshedCookie = profile.refreshedCookie {
            try? writeCookie(refreshedCookie)
            storedCookie = refreshedCookie
        }
        profileName = profile.name
        isLoggedIn = true
        sessionRevision &+= 1
    }

    func refreshProfile() async {
        guard let storedCookie else { return }
        guard let profile = try? await QishuiAPI.shared.profile(cookie: storedCookie) else {
            signOut()
            return
        }
        profileName = profile.name
        isLoggedIn = true
        if let refreshedCookie = profile.refreshedCookie {
            try? writeCookie(refreshedCookie)
            self.storedCookie = refreshedCookie
        }
    }

    func signOut() {
        deleteCookie()
        storedCookie = nil
        profileName = nil
        isLoggedIn = false
        sessionRevision &+= 1
    }

    private static func normalizedCookie(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "cookie:", options: [.caseInsensitive, .anchored]) {
            value.removeSubrange(range)
        }
        value = value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func looksLikeCookie(_ value: String) -> Bool {
        guard value.count <= 32_000, value.contains("=") else { return false }
        return value.split(separator: ";").contains { part in
            part.split(separator: "=", maxSplits: 1).count == 2
        }
    }

    private func readCookie() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
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

    private func writeCookie(_ cookie: String) throws {
        let data = Data(cookie.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        var attributes: [String: Any] = [kSecValueData as String: data]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw SessionError.validationFailed
            }
        } else if status != errSecSuccess {
            throw SessionError.validationFailed
        }
    }

    private func deleteCookie() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
