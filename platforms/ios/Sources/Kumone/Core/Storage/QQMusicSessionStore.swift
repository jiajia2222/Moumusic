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
        // A Keychain value is only a persisted candidate.  Do not expose it
        // as a valid account until QQ Music accepts the credential.
        isLoggedIn = false
        if storedCookie != nil {
            Task { @MainActor [weak self] in
                await self?.refreshProfile()
            }
        }
    }

    func signIn(cookie rawCookie: String) async throws {
        try await signIn(cookie: rawCookie, requireProfile: true)
    }

    /// A successful QQ QR callback already contains the Music credential.
    /// Persist it before asking the profile endpoint for optional metadata;
    /// the profile endpoint frequently lags behind the OAuth exchange.
    func signInFromQR(cookie rawCookie: String) async throws {
        try await signIn(cookie: rawCookie, requireProfile: false)
        Task { @MainActor [weak self] in
            await self?.refreshProfile()
        }
    }

    /// Web/phone login has already been completed by QQ Music.  The profile
    /// endpoint is only metadata and can lag behind a successful session
    /// exchange, so do not make it a prerequisite for saving the credential.
    func signInFromWeb(cookie rawCookie: String) async throws {
        try await signIn(cookie: rawCookie, requireProfile: false)
        Task { @MainActor [weak self] in
            await self?.refreshProfile()
        }
    }

    private func signIn(cookie rawCookie: String, requireProfile: Bool) async throws {
        let cookie = ProviderSessionSupport.normalizedCookie(rawCookie)
        guard !cookie.isEmpty else { throw SessionError.emptyCookie }
        guard ProviderSessionSupport.looksLikeCookie(cookie) else { throw SessionError.invalidCookie }
        var profile: QQMusicAPI.Profile?
        if requireProfile {
            profile = try? await QQMusicAPI.shared.profile(cookie: cookie)
        }
        if requireProfile, profile == nil {
            throw SessionError.validationFailed
        }
        do {
            try ProviderSessionSupport.writeCookie(cookie, service: keychainService)
        } catch {
            throw SessionError.validationFailed
        }
        storedCookie = cookie
        if let refreshedCookie = profile?.refreshedCookie {
            try? ProviderSessionSupport.writeCookie(refreshedCookie, service: keychainService)
            storedCookie = refreshedCookie
        }
        profileName = profile?.name ?? "QQ 音乐用户"
        isLoggedIn = true
        sessionRevision &+= 1
    }

    func refreshProfile() async {
        guard let storedCookie else { return }
        guard let profile = try? await QQMusicAPI.shared.profile(cookie: storedCookie) else {
            // QQ can issue a valid music credential before its legacy profile
            // endpoint is ready. Keep the credential usable for account audio
            // and retry enrichment on the next refresh instead of converting a
            // successful QR/phone login into “未登录”.
            guard Self.hasUsableCredential(storedCookie) else {
                signOut()
                return
            }
            profileName = profileName ?? "QQ 音乐用户"
            isLoggedIn = true
            sessionRevision &+= 1
            return
        }
        profileName = profile.name
        isLoggedIn = true
        sessionRevision &+= 1
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

    private static func hasUsableCredential(_ cookie: String) -> Bool {
        let fields = cookie.split(separator: ";").reduce(into: [String: String]()) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let accountID = fields["uin"] ?? fields["p_uin"] ?? fields["pt2gguin"]
            ?? fields["qqmusic_uin"] ?? fields["loginuin"] ?? ""
        let credential = ["qqmusic_key", "qm_keyst", "musickey", "music_key",
                          "p_skey", "skey", "wxskey", "wx_skey",
                          "psrf_access_token", "psrf_qq_access_token"]
            .compactMap { fields[$0] }
            .first { !$0.isEmpty } ?? ""
        return !accountID.isEmpty && accountID != "0" && !credential.isEmpty
    }
}
#endif
