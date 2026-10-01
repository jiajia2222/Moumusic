#if os(iOS)
import Foundation
import SwiftUI

/// Client for the Moumusic personal-card service.
///
/// The service owns only the Moumusic ID, profile card, and administrator
/// flags. Music-provider cookies remain in their own stores. The access token
/// is an opaque session token and is kept in the iOS Keychain.
@MainActor
final class MoumusicServerStore: ObservableObject {
    static let shared = MoumusicServerStore()

    struct ServerInfo: Codable, Equatable {
        let ipv4: String?
        let ipv6: String?
        let cpuCores: Int?
        let memoryMB: Int?
        let storageGB: Int?
        let networkPortMbps: Int?
    }

    struct ServerConfig: Codable, Equatable {
        let configured: Bool
        let serverID: String
        let version: String
        let downloadsEnabled: Bool
        let serverInfo: ServerInfo?
    }

    struct Profile: Codable, Equatable, Identifiable {
        let id: String
        let role: String
        var nickname: String
        var avatarURL: String?
        var signature: String?
        /// Optional public profile artwork. Older server responses may omit it.
        var backgroundURL: String?
        let createdAt: String?
        let updatedAt: String?
        var disabled: Bool?

        var isAdmin: Bool { role == "admin" }
    }

    @Published private(set) var config: ServerConfig?
    @Published private(set) var profile: Profile?
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?

    private struct AuthResponse: Decodable {
        let accessToken: String
        let profile: Profile
        let server: ServerConfig
    }

    private struct ConfigResponse: Decodable {
        let config: ServerConfig
    }

    private struct ProfileResponse: Decodable {
        let profile: Profile
    }

    private struct UsersResponse: Decodable {
        let users: [Profile]
    }

    private struct ProfileWithServerResponse: Decodable {
        let profile: Profile
        let server: ServerConfig
    }

    private struct ErrorResponse: Decodable {
        let error: ErrorBody?
    }

    private struct ErrorBody: Decodable {
        let message: String?
        let code: String?
    }

    private struct RegisterBody: Encodable {
        let deviceID: String
        let nickname: String
    }

    private struct AdminLoginBody: Encodable {
        let username: String
        let password: String
    }

    private struct ProfilePatch: Encodable {
        let nickname: String?
        let avatarURL: String?
        let signature: String?
        let backgroundURL: String?
        let publicID: String?
    }

    private struct ManagedUserPatch: Encodable {
        let publicID: String?
        let nickname: String?
        let avatarURL: String?
        let signature: String?
        let backgroundURL: String?
        let disabled: Bool?
    }

    private struct DownloadSettings: Encodable {
        let downloadsEnabled: Bool
    }

    private enum ServerError: LocalizedError {
        case invalidURL
        case invalidResponse
        case rejected(String, String?)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "个人资料服务地址无效"
            case .invalidResponse:
                return "个人资料服务返回的数据无效"
            case .rejected(let message, let code):
                if code == "PUBLIC_ID_CONFLICT" {
                    return "这个 ID 已被占用，请换一个"
                }
                if code == "INVALID_PUBLIC_ID" {
                    return "ID 需要使用 3-32 位字母、数字、点、下划线或连字符"
                }
                return message
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let baseURL: URL
    private let deviceID: String
    private let sessionService = "com.moumusic.account.session"
    private let localBackgroundKey = "moumusic.profile.backgroundURL"

    private init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "MOUMUSIC_SERVER_URL") as? String
        let value = configured?.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURL = URL(string: value?.isEmpty == false ? value! : "https://music.nadev.xyz")!

        if let saved = defaults.string(forKey: "moumusic.server.deviceID"), !saved.isEmpty {
            deviceID = saved
        } else {
            let generated = UUID().uuidString.lowercased()
            defaults.set(generated, forKey: "moumusic.server.deviceID")
            deviceID = generated
        }
    }

    var isReady: Bool { config != nil && profile != nil }
    var isAdmin: Bool { profile?.isAdmin == true }
    var displayID: String {
        if let id = profile?.id, !id.isEmpty { return id }
        return lastError == nil ? "待分配" : "服务器暂不可用"
    }

    var statusText: String {
        if isChecking { return "正在连接个人资料服务…" }
        if let lastError, !lastError.isEmpty { return "个人资料服务暂不可用" }
        if let config {
            return config.downloadsEnabled ? "在线 · 下载已开启" : "在线 · 下载已关闭"
        }
        return "未连接个人资料服务"
    }

    private func applyingLocalOverrides(to remote: Profile) -> Profile {
        var value = remote
        if let background = defaults.string(forKey: localBackgroundKey), !background.isEmpty {
            value.backgroundURL = background
        }
        return value
    }

    /// Called during app warm-up. It never blocks the music UI indefinitely.
    @discardableResult
    func start() async -> Bool {
        guard !isChecking else { return isReady }
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        guard await checkConfiguration() else { return false }
        if let token = ProviderSessionSupport.readCookie(service: sessionService),
           !token.isEmpty,
           await loadMe(token: token) {
            return true
        }

        ProviderSessionSupport.deleteCookie(service: sessionService)
        do {
            let body = try JSONEncoder().encode(RegisterBody(deviceID: deviceID, nickname: "Moumusic User"))
            let response: AuthResponse = try await request(
                "/api/moumusic/auth/register",
                method: "POST",
                body: body
            )
            try ProviderSessionSupport.writeCookie(response.accessToken, service: sessionService)
            profile = applyingLocalOverrides(to: response.profile)
            config = response.server
            return true
        } catch {
            lastError = "个人资料服务暂不可用"
            return false
        }
    }

    @discardableResult
    func checkConfiguration() async -> Bool {
        do {
            let response: ConfigResponse = try await request("/api/moumusic/config")
            config = response.config
            return response.config.configured
        } catch {
            lastError = "个人资料服务暂不可用"
            return false
        }
    }

    func updateProfile(
        nickname: String? = nil,
        avatarURL: String? = nil,
        signature: String? = nil,
        backgroundURL: String? = nil,
        publicID: String? = nil
    ) async {
        guard let token = ProviderSessionSupport.readCookie(service: sessionService), !token.isEmpty else { return }
        if let backgroundURL {
            let value = backgroundURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                defaults.removeObject(forKey: localBackgroundKey)
            } else {
                defaults.set(value, forKey: localBackgroundKey)
            }
        }
        do {
            let body = try JSONEncoder().encode(ProfilePatch(
                nickname: nickname,
                avatarURL: avatarURL,
                signature: signature,
                backgroundURL: backgroundURL,
                publicID: publicID
            ))
            let response: ProfileResponse = try await request(
                "/api/moumusic/profile",
                method: "PATCH",
                body: body,
                token: token
            )
            profile = applyingLocalOverrides(to: response.profile)
        } catch {
            lastError = "Profile could not be saved"
        }
    }

    func adminLogin(username: String, password: String) async -> Bool {
        do {
            let body = try JSONEncoder().encode(AdminLoginBody(username: username, password: password))
            let response: AuthResponse = try await request(
                "/api/moumusic/auth/admin/login",
                method: "POST",
                body: body
            )
            try ProviderSessionSupport.writeCookie(response.accessToken, service: sessionService)
            profile = applyingLocalOverrides(to: response.profile)
            config = response.server
            lastError = nil
            return true
        } catch {
            lastError = "Administrator login failed"
            return false
        }
    }

    func setDownloadsEnabled(_ enabled: Bool) async {
        guard isAdmin, let token = ProviderSessionSupport.readCookie(service: sessionService) else { return }
        do {
            let body = try JSONEncoder().encode(DownloadSettings(downloadsEnabled: enabled))
            let response: ConfigResponse = try await request(
                "/api/moumusic/admin/settings",
                method: "PATCH",
                body: body,
                token: token
            )
            config = response.config
        } catch {
            lastError = "Download setting could not be saved"
        }
    }

    @discardableResult
    func loadManagedUsers() async -> [Profile] {
        guard isAdmin, let token = ProviderSessionSupport.readCookie(service: sessionService) else { return [] }
        do {
            let response: UsersResponse = try await request("/api/moumusic/admin/users", token: token)
            lastError = nil
            return response.users
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    @discardableResult
    func updateManagedUser(
        id: String,
        publicID: String? = nil,
        nickname: String? = nil,
        avatarURL: String? = nil,
        signature: String? = nil,
        backgroundURL: String? = nil,
        disabled: Bool? = nil
    ) async -> Bool {
        guard isAdmin, let token = ProviderSessionSupport.readCookie(service: sessionService) else { return false }
        do {
            let body = try JSONEncoder().encode(ManagedUserPatch(
                publicID: publicID,
                nickname: nickname,
                avatarURL: avatarURL,
                signature: signature,
                backgroundURL: backgroundURL,
                disabled: disabled
            ))
            let pathID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            let _: ProfileResponse = try await request(
                "/api/moumusic/admin/users/\(pathID)",
                method: "PATCH",
                body: body,
                token: token
            )
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func logout() async {
        if let token = ProviderSessionSupport.readCookie(service: sessionService) {
            _ = try? await requestData("/api/moumusic/auth/logout", method: "POST", token: token)
        }
        ProviderSessionSupport.deleteCookie(service: sessionService)
        profile = nil
    }

    private func loadMe(token: String) async -> Bool {
        do {
            let response: ProfileWithServerResponse = try await request("/api/moumusic/me", token: token)
            profile = applyingLocalOverrides(to: response.profile)
            config = response.server
            return true
        } catch {
            return false
        }
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        token: String? = nil
    ) async throws -> T {
        let data = try await requestData(path, method: method, body: body, token: token)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServerError.invalidResponse
        }
    }

    private func requestData(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        token: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw ServerError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServerError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw ServerError.rejected(
                errorBody?.error?.message ?? "Server request failed",
                errorBody?.error?.code
            )
        }
        return data
    }
}
#endif
