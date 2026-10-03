import Foundation

/// Looks up the latest build published on the update host. iOS has no Sparkle, so Settings
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
        /// CI run number (CFBundleVersion); updates are decided by this.
        let build: Int
        /// The release page (fallback download link).
        let url: URL
        /// Direct download URL of the iOS IPA asset, when present.
        let ipaURL: URL?
        /// Release notes are kept for the update sheet and are never executed
        /// as HTML or Markdown inside the app.
        let notes: String?
    }

    /// Updates come from the image host (CI uploads every build there, see
    /// `.github/workflows/ios-build.yml`); nothing is published on GitHub Releases.
    static let host = URL(string: "https://yun.nadev.xyz")!
    static let manifestURL = URL(string: "https://yun.nadev.xyz/file/moumusic/latest.json")!
    static let releasesPage = URL(string: "https://yun.nadev.xyz")!

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
        // The manifest is replaced in place on every build: bypass every cache.
        var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("Moumusic-iOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NeteaseAPIError.decoding("release-http")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let short = obj["version"] as? String
        else { throw NeteaseAPIError.decoding("release") }
        let build = (obj["build"] as? Int) ?? Int(obj["build"] as? String ?? "") ?? 0
        let full = obj["full"] as? [String: Any]
        let ipaURL = (full?["url"] as? String).flatMap(URL.init)
        return Release(version: build > 0 ? "\(short).\(build)" : short,
                       build: build,
                       url: releasesPage,
                       ipaURL: ipaURL,
                       notes: (obj["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
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
