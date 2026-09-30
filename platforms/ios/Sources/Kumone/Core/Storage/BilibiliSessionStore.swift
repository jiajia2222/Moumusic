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
    @Published private(set) var isVIP = false
    @Published private(set) var vipType = 0
    @Published private(set) var vipDueDate: Date?
    @Published private(set) var membershipLabel: String?
    @Published private(set) var sessionRevision = 0

    var membershipTitle: String? {
        guard isVIP else { return nil }
        if let membershipLabel, !membershipLabel.isEmpty {
            return membershipLabel
        }
        return vipType >= 2 ? "\u{5927}\u{4F1A}\u{5458}" : "\u{666E}\u{901A}\u{4F1A}\u{5458}"
    }

    /// The cookie is only exposed to the in-process Bilibili API actor. It is
    /// never persisted outside Keychain or returned to the UI layer.
    var cookie: String? { storedCookie }

    private let keychainService = "com.moumusic.bilibili.session"
    private var storedCookie: String?

    private init() {
        storedCookie = ProviderSessionSupport.readCookie(service: keychainService)
        // A Keychain value is only a persisted candidate.  Bilibili cookies
        // expire and can be revoked independently of the app, so exposing
        // this as logged-in before `/nav` succeeds makes the login sheet
        // dismiss itself and leaves the UI in a false logged-in state.
        isLoggedIn = false
        if storedCookie != nil {
            Task { @MainActor [weak self] in
                await self?.refreshProfile()
            }
        }
    }

    func signIn(cookie: String) async throws {
        try await signIn(cookie: cookie, requireProfile: true)
    }

    /// QR polling already received a provider-confirmed login response. Do
    /// not make the QR sheet wait for `/nav`: that endpoint can be throttled
    /// or briefly unavailable immediately after the scan, which used to turn
    /// a successful scan into a false login failure/expired-code screen.
    func signInFromQR(cookie: String) async throws {
        try await signIn(cookie: cookie, requireProfile: false)
        Task { @MainActor [weak self] in
            await self?.refreshProfile()
        }
    }

    /// Web/phone login has completed on Bilibili's own page.  Save the
    /// provider-confirmed session first, then enrich it with `/nav` in the
    /// background so a transient profile response cannot reject the login.
    func signInFromWeb(cookie: String) async throws {
        try await signIn(cookie: cookie, requireProfile: false)
        Task { @MainActor [weak self] in
            await self?.refreshProfile()
        }
    }

    private func signIn(cookie rawCookie: String, requireProfile: Bool) async throws {
        let cookie = rawCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ProviderSessionSupport.looksLikeCookie(cookie),
              Self.hasAccountCookie(cookie) else {
            throw SessionError.validationFailed
        }
        var profile: BilibiliAPI.Profile?
        var lastError: Error?
        if requireProfile {
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
        }
        if requireProfile, profile == nil {
            throw lastError ?? SessionError.validationFailed
        }
        try ProviderSessionSupport.writeCookie(cookie, service: keychainService)
        storedCookie = cookie
        profileName = profile?.name ?? "\u{54D4}\u{54E9}\u{54D4}\u{54E9}\u{7528}\u{6237}"
        avatarURL = profile?.avatarURL
        isVIP = profile?.isVIP ?? false
        vipType = profile?.vipType ?? 0
        vipDueDate = profile?.vipDueDate
        membershipLabel = profile?.membershipLabel
        isLoggedIn = true
        sessionRevision &+= 1
    }

    func refreshProfile() async {
        guard let storedCookie else { return }
        guard let profile = try? await BilibiliAPI.shared.profile(cookie: storedCookie) else {
            // `/nav` may briefly fail immediately after a QR confirmation or
            // while Bilibili is rate-limiting the account endpoint. Keep a
            // structurally valid session instead of turning a successful
            // login into an apparent logout. Playback will still validate the
            // session and the next refresh can enrich the profile fields.
            guard Self.hasAccountCookie(storedCookie) else {
                signOut()
                return
            }
            profileName = profileName ?? "哔哩哔哩用户"
            isLoggedIn = true
            sessionRevision &+= 1
            return
        }
        profileName = profile.name
        avatarURL = profile.avatarURL
        isVIP = profile.isVIP
        vipType = profile.vipType
        vipDueDate = profile.vipDueDate
        membershipLabel = profile.membershipLabel
        isLoggedIn = true
        sessionRevision &+= 1
    }

    private static func hasAccountCookie(_ cookie: String) -> Bool {
        let fields = cookie.split(separator: ";").reduce(into: Set<String>()) { result, item in
            let name = item.split(separator: "=", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { result.insert(name) }
        }
        return fields.contains("SESSDATA") || fields.contains("DedeUserID")
    }

    func signOut() {
        ProviderSessionSupport.deleteCookie(service: keychainService)
        storedCookie = nil
        profileName = nil
        avatarURL = nil
        isVIP = false
        vipType = 0
        vipDueDate = nil
        membershipLabel = nil
        isLoggedIn = false
        sessionRevision &+= 1
    }
}
#endif
