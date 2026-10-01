import Foundation

/// 远程配置（公告、平台/功能开关），来自 MoumusicServer 的 config.json。
@MainActor
final class RemoteControlStore: ObservableObject {
    static let shared = RemoteControlStore()

    @Published private(set) var announcementEnabled = false
    @Published private(set) var announcementText = ""
    @Published private(set) var announcementImageURL: URL?
    @Published private(set) var announcementTextColorHex = ""
    @Published private(set) var updatedAt = ""

    private let defaults = UserDefaults.standard
    private var lastFetch = Date.distantPast
    private enum Key {
        static let enabled = "beans.remoteAnnouncement.enabled"
        static let text = "beans.remoteAnnouncement.text"
        static let image = "beans.remoteAnnouncement.imageURL"
        static let color = "beans.remoteAnnouncement.textColor"
        static let updated = "beans.remoteAnnouncement.updatedAt"
    }

    private init() {
        announcementEnabled = defaults.bool(forKey: Key.enabled)
        announcementText = defaults.string(forKey: Key.text) ?? ""
        announcementImageURL = URL(string: defaults.string(forKey: Key.image) ?? "")
        announcementTextColorHex = defaults.string(forKey: Key.color) ?? ""
        updatedAt = defaults.string(forKey: Key.updated) ?? ""
    }

    func refreshIfNeeded(force: Bool = false) async {
        if !force, Date().timeIntervalSince(lastFetch) < 600 { return }
        lastFetch = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: MoumusicServer.request("config.json"))
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            apply(obj)
        } catch {
            // 保留上次缓存。
        }
    }

    private func apply(_ obj: [String: Any]) {
        announcementEnabled = (obj["enabled"] as? Bool ?? true) && (obj["announcement_enabled"] as? Bool ?? false)
        announcementText = obj["announcement"] as? String ?? ""
        let img = (obj["announcement_media_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? obj["announcement_image_url"] as? String ?? ""
        announcementImageURL = URL(string: img)
        announcementTextColorHex = obj["announcement_text_color"] as? String ?? ""
        updatedAt = obj["updated_at"] as? String ?? ""
        defaults.set(announcementEnabled, forKey: Key.enabled)
        defaults.set(announcementText, forKey: Key.text)
        defaults.set(img, forKey: Key.image)
        defaults.set(announcementTextColorHex, forKey: Key.color)
        defaults.set(updatedAt, forKey: Key.updated)
    }
}
