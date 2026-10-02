#if os(iOS)
import Foundation
import Security
import UIKit

/// Moumusic 自有服务端（设备 ID / 心跳 / 远程配置 / 反馈 / 资料卡片同步）。
/// 协议参照 Beans 2.0.2 的 DeviceReporter / RemoteControlStore，服务端见 moumusic-server。
enum MoumusicServer {
    private static let overrideKey = "moumusic.serverBase"
    /// 经 Cloudflare Tunnel 对外，源站 IP 不暴露；可在 UserDefaults 写入 moumusic.serverBase 覆盖。
    static let defaultBase = "https://musicserver.nadev.xyz/moumusic"

    static var base: URL {
        let raw = UserDefaults.standard.string(forKey: overrideKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = raw.isEmpty ? defaultBase : raw
        return URL(string: text.hasSuffix("/") ? String(text.dropLast()) : text) ?? URL(string: defaultBase)!
    }

    static func url(_ path: String) -> URL {
        base.appendingPathComponent(path)
    }

    static func request(_ path: String, method: String = "GET", json: [String: Any]? = nil, timeout: TimeInterval = 15) -> URLRequest {
        var req = URLRequest(url: url(path), timeoutInterval: timeout)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let json = json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }
}

/// 每台设备一个稳定标识：Keychain 优先（卸载重装后保留），UserDefaults 兜底。
enum StableDeviceID {
    private static let service = "com.moumusic.device"
    private static let account = "stable-public-id"
    private static let defaultsKey = "beans.stablePublicID"

    /// The device code. It is stored in four places (Keychain, UserDefaults, and two
    /// files) so reinstalling or installing over the top keeps the same ID; a code
    /// from a previous install can also be restored by hand (see `restore`).
    static var value: String {
        if let v = readKeychain(), isValid(v) { remember(v); return v }
        if let v = UserDefaults.standard.string(forKey: defaultsKey), isValid(v) { remember(v); return v }
        for url in backupFiles() {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let v = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if isValid(v) { remember(v); return v }
            }
        }
        let fresh = UUID().uuidString.lowercased()
        remember(fresh)
        return fresh
    }

    /// Replaces the device code with one copied from a previous install.
    @discardableResult
    static func restore(_ code: String) -> Bool {
        let v = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValid(v) else { return false }
        remember(v)
        return true
    }

    private static func remember(_ v: String) {
        UserDefaults.standard.set(v, forKey: defaultsKey)
        writeKeychain(v)
        for url in backupFiles() { try? v.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Application Support survives an over-the-top install; Documents is also kept
    /// by some sideloading tools when the app is replaced.
    private static func backupFiles() -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory] {
            guard let base = fm.urls(for: directory, in: .userDomainMask).first else { continue }
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            urls.append(base.appendingPathComponent(".moumusic-device-code"))
        }
        return urls
    }

    private static func isValid(_ s: String) -> Bool {
        s.range(of: "^[a-f0-9-]{16,80}$", options: .regularExpression) != nil
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func readKeychain() -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = baseQuery()
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

/// 心跳上报与服务端下发的身份信息（公开 ID、专属 ID、徽章、封禁、下载权限）。
@MainActor
final class DeviceReporter: ObservableObject {
    static let shared = DeviceReporter()

    enum BadgeStyle: String {
        case blackPurpleGold = "black_purple_gold"
        case classicGold = "classic_gold"
    }

    @Published private(set) var publicUserID: String
    @Published private(set) var exclusiveID: String
    @Published private(set) var badgeStyle: BadgeStyle
    @Published private(set) var isBlocked: Bool
    @Published private(set) var downloadUnlocked: Bool
    @Published private(set) var downloadGlobalEnabled: Bool
    @Published private(set) var isDeveloper: Bool

    private let defaults = UserDefaults.standard
    private var heartbeatInFlight = false
    private var timer: Timer?

    private enum Key {
        static let publicID = "beans.backend.publicID"
        static let exclusiveID = "beans.backend.exclusiveID"
        static let badge = "beans.backend.exclusiveIDBadgeStyle"
        static let blocked = "beans.backend.userBlocked"
        static let download = "beans.backend.downloadUnlocked"
        static let downloadGlobal = "beans.downloadGlobalFeatureEnabled"
        static let developer = "beans.backend.isDeveloper"
    }

    private init() {
        let d = UserDefaults.standard
        publicUserID = d.string(forKey: Key.publicID) ?? ""
        exclusiveID = d.string(forKey: Key.exclusiveID) ?? ""
        badgeStyle = BadgeStyle(rawValue: d.string(forKey: Key.badge) ?? "") ?? .blackPurpleGold
        isBlocked = d.bool(forKey: Key.blocked)
        downloadUnlocked = d.bool(forKey: Key.download)
        downloadGlobalEnabled = d.bool(forKey: Key.downloadGlobal)
        isDeveloper = d.bool(forKey: Key.developer)
    }

    /// 设备在服务端的标识（私有，仅用于心跳/同步）。
    var deviceUserID: String { StableDeviceID.value }

    /// 页面展示用 ID：专属 ID 优先，其次公开 ID。
    /// The ID shown in the UI: exclusive ID, else the server's random six-digit ID.
    /// Until the first heartbeat answers, a stable six-digit placeholder derived from
    /// this device is shown so a long device code never leaks into the UI.
    var displayID: String {
        if !exclusiveID.isEmpty { return exclusiveID }
        if !publicUserID.isEmpty { return publicUserID }
        var hash: UInt64 = 1469598103934665603
        for byte in StableDeviceID.value.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(100000 + Int(hash % 900000))
    }

    /// Re-reads the identity after the device code was replaced.
    func adoptRestoredDeviceCode() {
        publicUserID = ""
        exclusiveID = ""
        defaults.removeObject(forKey: Key.publicID)
        defaults.removeObject(forKey: Key.exclusiveID)
        start()
    }

    func start() {
        Task { await reportHeartbeat() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reportHeartbeat() }
        }
    }

    func reportHeartbeat() async {
        guard !heartbeatInFlight else { return }
        heartbeatInFlight = true
        defer { heartbeatInFlight = false }

        let stats = ListeningStatsStore.shared
        let info = Bundle.main.infoDictionary
        let body: [String: Any] = [
            "user_id": StableDeviceID.value,
            "device_model": Self.hardwareIdentifier(),
            "device_name": UIDevice.current.name,
            "system_name": UIDevice.current.systemName,
            "system_version": UIDevice.current.systemVersion,
            "app_version": info?["CFBundleShortVersionString"] as? String ?? "",
            "app_build": info?["CFBundleVersion"] as? String ?? "",
            "listening_seconds": Int(stats.totalSeconds),
            "listening_play_count": stats.totalPlayCount,
        ]
        do {
            let (data, resp) = try await URLSession.shared.data(for: MoumusicServer.request("heartbeat", method: "POST", json: body))
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            apply(obj)
        } catch {
            // 离线或服务端不可用时保留上次缓存的身份信息。
        }
    }

    /// 反馈提交成功后服务端会解锁下载，立即同步到本地。
    func markDownloadUnlocked() {
        downloadUnlocked = true
        defaults.set(true, forKey: Key.download)
    }

    private func apply(_ obj: [String: Any]) {
        if let v = obj["original_public_user_id"] as? String ?? obj["public_user_id"] as? String {
            publicUserID = v; defaults.set(v, forKey: Key.publicID)
        }
        let ex = obj["exclusive_id"] as? String ?? ""
        exclusiveID = ex; defaults.set(ex, forKey: Key.exclusiveID)
        if let raw = obj["exclusive_badge_style"] as? String, let style = BadgeStyle(rawValue: raw) {
            badgeStyle = style; defaults.set(raw, forKey: Key.badge)
        }
        if let b = obj["blocked"] as? Bool { isBlocked = b; defaults.set(b, forKey: Key.blocked) }
        if let b = obj["download_unlocked"] as? Bool { downloadUnlocked = b; defaults.set(b, forKey: Key.download) }
        if let b = obj["download_global_enabled"] as? Bool { downloadGlobalEnabled = b; defaults.set(b, forKey: Key.downloadGlobal) }
        if let b = obj["is_developer"] as? Bool { isDeveloper = b; defaults.set(b, forKey: Key.developer) }
    }

    private static func hardwareIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }
}
#endif
