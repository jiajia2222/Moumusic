import Foundation

struct UpdateChecker {
    static let repoPath = "jiajia2222/Moumusic"
    static let releasePageURL = URL(string: "https://yun.nadev.xyz")!
    private static let latestAPI = URL(string: "https://yun.nadev.xyz/file/moumusic/latest.json")!
    private static let suppressedVersionKey = "beans.updateCheck.suppressedVersion"

    struct ReleaseInfo {
        let version: String
        let build: Int
        let name: String
        let body: String
        let htmlURL: URL
        let assetURL: URL?
        let notesImageURL: URL?
        let notesTextColorHex: String?
    }

    enum CheckResult {
        case update(ReleaseInfo)
        case upToDate
        case failed
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    static func checkIfNeeded() async -> ReleaseInfo? {
        guard let info = try? await fetchLatest(), info.build > currentBuild else { return nil }
        if UserDefaults.standard.string(forKey: suppressedVersionKey) == info.version { return nil }
        return info
    }

    static func checkNow() async -> CheckResult {
        do {
            let info = try await fetchLatest()
            return info.build > currentBuild ? .update(info) : .upToDate
        } catch {
            return .failed
        }
    }

    static func suppress(version: String) {
        UserDefaults.standard.set(version, forKey: suppressedVersionKey)
        UserDefaults.standard.synchronize()
    }

    static func fetchLatest() async throws -> ReleaseInfo {
        var components = URLComponents(url: latestAPI, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("Beans-Music/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let short = json["version"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        let build = (json["build"] as? Int) ?? Int(json["build"] as? String ?? "") ?? 0
        let assetURL = ((json["compat"] as? [String: Any])?["url"] as? String).flatMap { URL(string: $0) }
        return ReleaseInfo(
            version: build > 0 ? "\(short).\(build)" : short,
            build: build,
            name: "Moumusic \(short) (\(build))",
            body: json["notes"] as? String ?? "",
            htmlURL: releasePageURL,
            assetURL: assetURL,
            notesImageURL: nil,
            notesTextColorHex: nil
        )
    }

    static func isNewer(_ remote: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").compactMap { Int($0) }
        }
        let r = parts(remote)
        let c = parts(current)
        let count = max(r.count, c.count)
        for i in 0..<count {
            let a = i < r.count ? r[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }

}
