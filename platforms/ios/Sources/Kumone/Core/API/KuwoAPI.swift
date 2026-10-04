import Foundation

/// Kuwo Music's own listen route (the one its client uses), no account needed. Each tier is a different `br`
/// request; a reply only counts when it answers for the song that was asked for and its file really responds,
/// and the player then measures the file itself before any label is shown.
actor KuwoAPI {
    static let shared = KuwoAPI()

    struct ResolvedAudio: Sendable {
        let url: URL
        /// Canonical tier name (`AudioQuality.lxType`).
        let quality: String
    }

    enum KuwoError: Error { case unavailable, unsupported }

    private static func bitrateToken(for lxType: String) -> (br: String, quality: String)? {
        switch lxType.lowercased() {
        case "flac24bit", "hires", "flac24", "jymaster", "master": return ("4000kflac", "flac24bit")
        case "flac", "lossless": return ("2000kflac", "flac")
        case "320k", "exhigh", "higher", "320": return ("320kmp3", "320k")
        case "128k", "standard", "128": return ("128kmp3", "128k")
        default: return nil
        }
    }

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    func musicURL(songID: String, quality: String) async throws -> ResolvedAudio {
        guard let tier = Self.bitrateToken(for: quality) else { throw KuwoError.unsupported }
        var components = URLComponents(string: "https://mobi.kuwo.cn/mobi.s")!
        components.queryItems = [
            URLQueryItem(name: "f", value: "web"),
            URLQueryItem(name: "source", value: "kwplayerhd_ar_4.3.0.8_tianbao_T1A_qirui.apk"),
            URLQueryItem(name: "type", value: "convert_url_with_sign"),
            URLQueryItem(name: "br", value: tier.br),
            URLQueryItem(name: "rid", value: songID),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("okhttp/3.10.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["code"] as? Int) == 200,
              let payload = object["data"] as? [String: Any],
              let raw = payload["url"] as? String, !raw.isEmpty,
              // A reply for another song (or a short clip) is a placeholder, not this track.
              String(describing: payload["rid"] ?? "") == songID,
              let url = URL(string: raw.replacingOccurrences(of: "http://", with: "https://")) else {
            throw KuwoError.unavailable
        }
        // The reply's own format must match the tier (a flac request answered with mp3 is a downgrade).
        let format = (payload["format"] as? String)?.lowercased() ?? ""
        if tier.quality.hasPrefix("flac"), format != "flac" { throw KuwoError.unavailable }
        if !tier.quality.hasPrefix("flac"), !format.isEmpty, format != "mp3" { throw KuwoError.unavailable }
        var probe = URLRequest(url: url)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await session.bytes(for: probe),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 || http.statusCode == 206 else { throw KuwoError.unavailable }
        return ResolvedAudio(url: url, quality: tier.quality)
    }

    /// Tiers of this song that really answer, checked at the same time.
    func availableQualities(songID: String) async -> [String] {
        guard !songID.isEmpty else { return [] }
        return await withTaskGroup(of: String?.self) { group in
            for token in ["flac24bit", "flac", "320k", "128k"] {
                group.addTask { (try? await self.musicURL(songID: songID, quality: token))?.quality }
            }
            var found: [String] = []
            for await value in group { if let value { found.append(value) } }
            return found
        }
    }
}
