import Foundation

/// Looks up the latest GitHub release. iOS has no Sparkle, so Settings
/// offers a manual check that links to the release page for re-sideloading.
enum ReleaseChecker {
    struct AppIdentity: Equatable {
        let shortVersion: String
        let buildNumber: String

        var displayVersion: String {
            buildNumber.isEmpty ? shortVersion : "\(shortVersion) (\(buildNumber))"
        }

        var isValid: Bool {
            !shortVersion.isEmpty && !shortVersion.contains("$(") &&
                !buildNumber.isEmpty && !buildNumber.contains("$(")
        }
    }

    struct Release {
        let version: String
        /// The release page (fallback download link).
        let url: URL
        /// Direct download URL of the iOS IPA asset, when present.
        let ipaURL: URL?
        /// Release notes are kept for the update sheet and are never executed
        /// as HTML or Markdown inside the app.
        let notes: String?
    }

    private static let repository = "jiajia2222/Moumusic"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!

    static var currentIdentity: AppIdentity {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppIdentity(
            shortVersion: (info["CFBundleShortVersionString"] as? String ?? "0").trimmingCharacters(in: .whitespacesAndNewlines),
            buildNumber: (info["CFBundleVersion"] as? String ?? "0").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static var currentVersion: String {
        currentIdentity.shortVersion
    }

    static var currentBuildNumber: String {
        currentIdentity.buildNumber
    }

    static var currentDisplayVersion: String {
        currentIdentity.displayVersion
    }

    static func latest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Moumusic-iOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NeteaseAPIError.decoding("release-http")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let html = obj["html_url"] as? String, let url = URL(string: html)
        else { throw NeteaseAPIError.decoding("release") }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let ipa = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }
        let ipaURL = (ipa?["browser_download_url"] as? String).flatMap(URL.init)
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       url: url,
                       ipaURL: ipaURL,
                       notes: (obj["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True when `remote` is newer than `local` (numeric dotted compare).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = versionComponents(remote)
        let b = versionComponents(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Accept normal semantic versions as well as numeric versions such as
    /// `110000`. This is only a comparison helper; it does not change the
    /// bundle build number or the release workflow's build numbering.
    private static func versionComponents(_ value: String) -> [Int] {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let components = normalized.split(separator: ".").map { part in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        return components.isEmpty ? [0] : components
    }
}
