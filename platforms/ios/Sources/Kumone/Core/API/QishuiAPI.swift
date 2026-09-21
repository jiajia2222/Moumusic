import Foundation

/// Built-in resolver for public Qishui (汽水音乐) share links.
///
/// The documented BugPk endpoint accepts a Qishui share URL and returns a
/// short-lived audio URL plus the provider's actual bitrate and lyric payload.
/// We keep only the share URL in a playlist; signed audio URLs are deliberately
/// never persisted because they expire.
actor QishuiAPI {
    static let shared = QishuiAPI()

    struct Resolution: Sendable {
        let audioURL: URL
        let quality: String
        let lyric: String?
        let verbatimLyric: String?
        let title: String?
        let albumName: String?
        let artistName: String?
        let coverURL: String?
        let durationMS: Int
    }

    enum APIError: LocalizedError {
        case invalidShareURL
        case requestFailed
        case invalidResponse
        case unavailable

        var errorDescription: String? {
            switch self {
            case .invalidShareURL:
                return "请输入有效的汽水音乐分享链接"
            case .requestFailed:
                return "汽水音乐接口请求失败，请稍后重试"
            case .invalidResponse:
                return "汽水音乐接口返回格式不正确"
            case .unavailable:
                return "汽水音乐暂时没有可用播放地址"
            }
        }
    }

    private struct CacheEntry {
        let value: Resolution
        let expiresAt: Date
    }

    private let endpoint = URL(string: "https://api.bugpk.com/api/qsmusic")!
    private let session: URLSession
    private var cache: [String: CacheEntry] = [:]

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    /// Returns the share URL stored on an imported Qishui track.
    static func sharedURL(for track: Track) -> URL? {
        let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
        guard ["sd", "soda", "sodamusic", "soda-music", "qishui", "qishui-music"].contains(source) else {
            return nil
        }

        for key in ["qishuiURL", "qishuiUrl", "shareURL", "shareUrl", "sodaURL", "sodaUrl"] {
            guard let value = track.sourceMetadata[key],
                  let url = URL(string: value),
                  isSupportedShareURL(url) else { continue }
            return url
        }
        return nil
    }

    static func isSupportedShareURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let isQishuiHost = host.contains("qishui")
            || host == "music.douyin.com"
            || host.hasSuffix(".douyin.com")
        guard isQishuiHost else { return false }
        let path = url.path.lowercased()
        return path.contains("/s/") || path.contains("/share/") || path.contains("/track")
    }

    func resolve(sharedURL: URL) async throws -> Resolution {
        guard Self.isSupportedShareURL(sharedURL) else { throw APIError.invalidShareURL }
        let cacheKey = sharedURL.absoluteString
        if let cached = cache[cacheKey], cached.expiresAt > .now {
            return cached.value
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "url", value: sharedURL.absoluteString)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("Moumusic/1.0 (iOS; Qishui resolver)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.requestFailed
        }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw APIError.requestFailed
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isSuccess(root["code"]),
              let payload = root["data"] as? [String: Any],
              let rawAudioURL = text(in: payload, keys: ["url", "audio_url", "audioUrl"]),
              let audioURL = URL(string: rawAudioURL.replacingOccurrences(of: "http://", with: "https://")),
              ["http", "https"].contains(audioURL.scheme?.lowercased() ?? "") else {
            throw APIError.invalidResponse
        }

        let metadata = dictionary(in: payload, keys: ["video_meta", "videoMeta", "audio_meta", "audioMeta", "meta"])
        let bitrate = integer(in: metadata, keys: ["real_bitrate", "realBitrate", "bitrate"])
            ?? integer(in: payload, keys: ["real_bitrate", "realBitrate", "bitrate"])
        let format = text(in: metadata, keys: ["vtype", "format", "codec", "codec_type"])
            ?? text(in: payload, keys: ["format", "codec"])
        let qualityHint = text(in: metadata, keys: ["quality"])
            ?? text(in: payload, keys: ["quality"])
        let lyric = text(in: payload, keys: ["lyric", "lyrics", "lrc"])
        let verbatimLyric = lyric.map(Self.normalizeVerbatimLyric)
        let title = text(in: payload, keys: ["name", "songname", "song_name", "title", "music_name"])
        let albumName = text(in: payload, keys: ["albumname", "album_name", "album"])
        let artistName = text(in: payload, keys: ["artistsname", "artistname", "artist", "singer", "author"])
        let coverURL = normalizedURL(
            text(in: payload, keys: ["cover", "cover_url", "coverUrl", "albumcover", "albumCover", "pic", "picUrl", "image"])
        ) ?? firstString(in: payload, keys: ["artistsmedium_avatar_url", "artistsMediumAvatarURL"])
        let durationMS = durationMilliseconds(
            value(in: metadata, keys: ["duration_ms", "durationMS", "timelength", "duration"])
                ?? value(in: payload, keys: ["duration_ms", "durationMS", "timelength", "duration"])
        )

        let result = Resolution(
            audioURL: audioURL,
            quality: qualityName(bitrate: bitrate, format: format, hint: qualityHint),
            lyric: lyric,
            verbatimLyric: verbatimLyric,
            title: title,
            albumName: albumName,
            artistName: artistName,
            coverURL: coverURL,
            durationMS: durationMS
        )
        cache[cacheKey] = CacheEntry(value: result, expiresAt: .now.addingTimeInterval(300))
        return result
    }

    private static func isSuccess(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.intValue == 200 }
        if let string = value as? String { return string == "200" }
        return false
    }

    private static func dictionary(in object: [String: Any], keys: [String]) -> [String: Any] {
        for key in keys {
            if let value = object[key] as? [String: Any] { return value }
        }
        return [:]
    }

    private static func value(in object: [String: Any], keys: [String]) -> Any? {
        keys.first(where: { object[$0] != nil }).flatMap { object[$0] }
    }

    private static func text(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let values = object[key] as? [String], let first = values.first { return normalizedURL(first) }
            if let values = object[key] as? [Any],
               let first = values.compactMap({ $0 as? String }).first { return normalizedURL(first) }
            if let value = object[key] as? String { return normalizedURL(value) }
        }
        return nil
    }

    private static func integer(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = object[key] as? String, let number = Int(value) { return number }
            if let value = object[key] as? Double { return Int(value) }
        }
        return nil
    }

    private static func normalizedURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let normalized = value.hasPrefix("//") ? "https:" + value : value.replacingOccurrences(of: "http://", with: "https://")
        return URL(string: normalized) == nil ? nil : normalized
    }

    private static func durationMilliseconds(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Int(raw < 1000 ? raw * 1000 : raw)
        }
        guard let string = value as? String else { return 0 }
        if string.contains(":"),
           let seconds = string.split(separator: ":").compactMap({ Double($0) }).last {
            let minutes = Double(string.split(separator: ":").first ?? "0") ?? 0
            return Int((minutes * 60 + seconds) * 1000)
        }
        guard let raw = Double(string) else { return 0 }
        return Int(raw < 1000 ? raw * 1000 : raw)
    }

    private static func qualityName(bitrate: Int?, format: String?, hint: String?) -> String {
        let normalizedFormat = (format ?? "").lowercased()
        if let bitrate, bitrate > 0 {
            if ["flac", "ape", "wav"].contains(where: { normalizedFormat.contains($0) }), bitrate >= 700_000 {
                return "flac"
            }
            return bitrate >= 256_000 ? "320k" : "128k"
        }
        switch (hint ?? "").lowercased().replacingOccurrences(of: " ", with: "") {
        case "flac", "lossless", "ape", "wav": return "flac"
        case "320", "320k", "exhigh", "higher": return "320k"
        default: return "128k"
        }
    }

    /// Converts Qishui's `[lineStartMs,lineDurationMs]<wordStartMs,wordDurationMs,0>`
    /// format to the YRC form already understood by LyricsParser.
    private static func normalizeVerbatimLyric(_ lyric: String) -> String {
        lyric.replacingOccurrences(
            of: #"<(\d+),(\d+),(\d+)>"#,
            with: "($1,$2,$3)",
            options: .regularExpression
        )
    }
}
