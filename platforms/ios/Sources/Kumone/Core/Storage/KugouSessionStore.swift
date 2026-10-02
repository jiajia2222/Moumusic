import Foundation
import Combine

#if os(iOS) || os(macOS)
@MainActor
final class KugouSessionStore: ObservableObject {
    static let shared = KugouSessionStore()

    enum SessionError: LocalizedError {
        case emptyCookie
        case invalidCookie
        case validationFailed

        var errorDescription: String? {
            switch self {
            case .emptyCookie: return "请粘贴酷狗音乐 Cookie"
            case .invalidCookie: return "Cookie 格式不正确，请粘贴酷狗音乐网页中的完整 Cookie"
            case .validationFailed: return "酷狗音乐登录已失效或 Cookie 已过期"
            }
        }
    }

    @Published private(set) var isLoggedIn = false
    @Published private(set) var profileName: String?
    @Published private(set) var isVIP = false
    @Published private(set) var sessionRevision = 0

    var cookie: String? { storedCookie }

    private let keychainService = "com.moumusic.kugou.session"
    private var storedCookie: String?

    private init() {
        storedCookie = ProviderSessionSupport.readCookie(service: keychainService)
        // A persisted cookie is only a candidate until the provider accepts it.
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

    /// QR and Web/phone login callbacks are provider-confirmed credentials.
    /// Save them first; profile enrichment is retried independently below.
    func signInFromQR(cookie rawCookie: String) async throws {
        try await signIn(cookie: rawCookie, requireProfile: false)
        Task { @MainActor [weak self] in
            await self?.refreshProfile()
        }
    }

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
        var profile: KugouAPI.Profile?
        if requireProfile {
            profile = try? await KugouAPI.shared.profile(cookie: cookie)
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
        profileName = profile?.name ?? "酷狗音乐用户"
        isVIP = profile?.isVIP ?? false
        isLoggedIn = true
        sessionRevision &+= 1
    }

    func refreshProfile() async {
        guard let storedCookie else { return }
        guard let profile = try? await KugouAPI.shared.profile(cookie: storedCookie) else {
            // The login endpoints can return a valid playback token before
            // usercenter exposes nickname/avatar. Keep the account session and
            // let official playback validate it; a profile timeout must not
            // erase a successful QR/phone login.
            guard Self.hasUsableCredential(storedCookie) else {
                signOut()
                return
            }
            profileName = profileName ?? "酷狗音乐用户"
            isLoggedIn = true
            sessionRevision &+= 1
            return
        }
        profileName = profile.name
        isVIP = profile.isVIP
        isLoggedIn = true
        if let refreshedCookie = profile.refreshedCookie {
            try? ProviderSessionSupport.writeCookie(refreshedCookie, service: keychainService)
            self.storedCookie = refreshedCookie
        }
    }

    /// Registers this device with Kugou (needed for the account playlist APIs) and keeps
    /// the resulting `dfid` with the session. Returns the cookie to use for requests.
    func cookieWithDevice() async -> String? {
        guard let cookie = storedCookie else { return nil }
        // Only our own registration counts: web cookies also carry `dfid`/`kg_dfid`,
        // but those belong to a browser device and the Android gateway rejects them (20010).
        if cookie.contains("kugou_api_guid=") { return cookie }
        guard let registered = await KugouAPI.shared.registerDevice(cookie: cookie) else { return cookie }
        let kept = cookie.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.lowercased().hasPrefix("dfid=") && !$0.lowercased().hasPrefix("kg_dfid=") }
            .joined(separator: "; ")
        let updated = kept + "; dfid=\(registered.dfid); kugou_api_guid=\(registered.guid)"
        try? ProviderSessionSupport.writeCookie(updated, service: keychainService)
        storedCookie = updated
        return updated
    }

    func signOut() {
        ProviderSessionSupport.deleteCookie(service: keychainService)
        storedCookie = nil
        profileName = nil
        isVIP = false
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
        let token = fields["token"] ?? fields["login_token"] ?? fields["kugou_token"] ?? fields["kg_token"] ?? ""
        let userID = fields["userid"] ?? fields["user_id"] ?? fields["kugooid"]
            ?? fields["kugoo_id"] ?? fields["kg_mid"] ?? fields["mid"] ?? ""
        return !token.isEmpty && !userID.isEmpty
    }
}
#endif
