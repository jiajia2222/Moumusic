import Foundation
import Combine

#if os(iOS) || os(macOS)
@MainActor
final class QQMusicSessionStore: ObservableObject {
    static let shared = QQMusicSessionStore()

    enum SessionError: LocalizedError {
        case emptyCookie
        case invalidCookie
        case validationFailed

        var errorDescription: String? {
            switch self {
            case .emptyCookie: return "请粘贴 QQ 音乐 Cookie"
            case .invalidCookie: return "Cookie 格式不正确，请粘贴 QQ 音乐网页中的完整 Cookie"
            case .validationFailed: return "QQ 音乐登录已失效或 Cookie 已过期"
            }
        }
    }

    @Published private(set) var isLoggedIn = false
    @Published private(set) var profileName: String?
    @Published private(set) var sessionRevision = 0

    var cookie: String? { storedCookie }

    private let keychainService = "com.moumusic.qqmusic.session"
    private var storedCookie: String?

    private init() {
        storedCookie = ProviderSessionSupport.readCookie(service: keychainService)
        isLoggedIn = storedCookie != nil
    }

    func signIn(cookie rawCookie: String) async throws {
        let cookie = ProviderSessionSupport.normalizedCookie(rawCookie)
        guard !cookie.isEmpty else { throw SessionError.emptyCookie }
        guard ProviderSessionSupport.looksLikeCookie(cookie) else { throw SessionError.invalidCookie }
        guard let profile = try? await QQMusicAPI.shared.profile(cookie: cookie) else {
            throw SessionError.validationFailed
        }
        do {
            try ProviderSessionSupport.writeCookie(cookie, service: keychainService)
        } catch {
            throw SessionError.validationFailed
        }
        storedCookie = cookie
        if let refreshedCookie = profile.refreshedCookie {
            try? ProviderSessionSupport.writeCookie(refreshedCookie, service: keychainService)
            storedCookie = refreshedCookie
        }
        profileName = profile.name
        isLoggedIn = true
        sessionRevision &+= 1
    }

    func refreshProfile() async {
        guard let storedCookie else { return }
        guard let profile = try? await QQMusicAPI.shared.profile(cookie: storedCookie) else {
            signOut()
            return
        }
        profileName = profile.name
        isLoggedIn = true
        if let refreshedCookie = profile.refreshedCookie {
            try? ProviderSessionSupport.writeCookie(refreshedCookie, service: keychainService)
            self.storedCookie = refreshedCookie
        }
    }

    func signOut() {
        ProviderSessionSupport.deleteCookie(service: keychainService)
        storedCookie = nil
        profileName = nil
        isLoggedIn = false
        sessionRevision &+= 1
    }
}
#endif
