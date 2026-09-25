import Foundation
import Combine
import Security

#if os(iOS) || os(macOS)
@MainActor
final class BilibiliSessionStore: ObservableObject {
    static let shared = BilibiliSessionStore()

    enum SessionError: LocalizedError {
        case validationFailed

        var errorDescription: String? {
            switch self {
            case .validationFailed: return "哔哩哔哩登录已失效，请重新扫码"
            }
        }
    }

    @Published private(set) var isLoggedIn = false
    @Published private(set) var profileName: String?
    @Published private(set) var avatarURL: String?
    @Published private(set) var sessionRevision = 0

    /// The cookie is only exposed to the in-process Bilibili API actor. It is
    /// never persisted outside Keychain or returned to the UI layer.
    var cookie: String? { storedCookie }

    private let keychainService = "com.moumusic.bilibili.session"
    private var storedCookie: String?

    private init() {
        storedCookie = ProviderSessionSupport.readCookie(service: keychainService)
        isLoggedIn = storedCookie != nil
    }

    func signIn(cookie: String) async throws {
        guard !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ProviderSessionSupport.looksLikeCookie(cookie) else {
            throw SessionError.validationFailed
        }
        var profile: BilibiliAPI.Profile?
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                profile = try await BilibiliAPI.shared.profile(cookie: cookie)
                break
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
        }
        guard let profile else {
            throw lastError ?? SessionError.validationFailed
        }
        try ProviderSessionSupport.writeCookie(cookie, service: keychainService)
        storedCookie = cookie
        profileName = profile.name
        avatarURL = profile.avatarURL
        isLoggedIn = true
        sessionRevision &+= 1
    }

    func refreshProfile() async {
        guard let storedCookie else { return }
        guard let profile = try? await BilibiliAPI.shared.profile(cookie: storedCookie) else {
            signOut()
            return
        }
        profileName = profile.name
        avatarURL = profile.avatarURL
        isLoggedIn = true
    }

    func signOut() {
        ProviderSessionSupport.deleteCookie(service: keychainService)
        storedCookie = nil
        profileName = nil
        avatarURL = nil
        isLoggedIn = false
        sessionRevision &+= 1
    }
}
#endif
