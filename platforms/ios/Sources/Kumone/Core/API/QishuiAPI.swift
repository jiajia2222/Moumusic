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

    struct PlaylistResolution: Sendable {
        struct Track: Sendable {
            let id: String
            let name: String
            let artistName: String
            let albumName: String?
            let coverURL: String?
            let durationMS: Int
            let shareURL: URL
        }

        let id: String
        let name: String
        let coverURL: String?
        let revision: Int
        let tracks: [Track]
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

    static func isPlaylistURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host == "music.douyin.com" || host.hasSuffix(".douyin.com") else {
            return false
        }
        let path = url.path.lowercased()
        let hasPlaylistPath = path.contains("/qishui/share/playlist")
            || path.contains("/share/playlist")
        let hasPlaylistID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            ["playlist_id", "playlistid"].contains($0.name.lowercased())
        } == true
        return hasPlaylistPath || (hasPlaylistID && path.contains("playlist"))
    }

    /// Short Qishui share URLs must be resolved before deciding whether they
    /// represent a track or a playlist. Treating `/s/...` as a song here was
    /// the reason public playlist links were sent to the single-track API.
    static func isShortShareURL(_ url: URL) -> Bool {
        url.path.lowercased().hasPrefix("/s/")
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
              Self.isSuccess(root["code"]),
              let payload = root["data"] as? [String: Any],
              let rawAudioURL = Self.text(in: payload, keys: ["url", "audio_url", "audioUrl"]),
              let audioURL = URL(string: rawAudioURL.replacingOccurrences(of: "http://", with: "https://")),
              ["http", "https"].contains(audioURL.scheme?.lowercased() ?? "") else {
            throw APIError.invalidResponse
        }

        let metadata = Self.dictionary(in: payload, keys: ["video_meta", "videoMeta", "audio_meta", "audioMeta", "meta"])
        let bitrate = Self.integer(in: metadata, keys: ["real_bitrate", "realBitrate", "bitrate"])
            ?? Self.integer(in: payload, keys: ["real_bitrate", "realBitrate", "bitrate"])
        let format = Self.text(in: metadata, keys: ["vtype", "format", "codec", "codec_type"])
            ?? Self.text(in: payload, keys: ["format", "codec"])
        let qualityHint = Self.text(in: metadata, keys: ["quality"])
            ?? Self.text(in: payload, keys: ["quality"])
        let lyric = Self.text(in: payload, keys: ["lyric", "lyrics", "lrc"])
        let verbatimLyric = lyric.map(Self.normalizeVerbatimLyric)
        let title = Self.text(in: payload, keys: ["name", "songname", "song_name", "title", "music_name"])
        let albumName = Self.text(in: payload, keys: ["albumname", "album_name", "album"])
        let artistName = Self.text(in: payload, keys: ["artistsname", "artistname", "artist", "singer", "author"])
        let coverURL = Self.normalizedURL(
            Self.text(in: payload, keys: ["cover", "cover_url", "coverUrl", "albumcover", "albumCover", "pic", "picUrl", "image"])
        ) ?? Self.firstString(in: payload, keys: ["artistsmedium_avatar_url", "artistsMediumAvatarURL"])
        let durationMS = Self.durationMilliseconds(
            Self.value(in: metadata, keys: ["duration_ms", "durationMS", "timelength", "duration"])
                ?? Self.value(in: payload, keys: ["duration_ms", "durationMS", "timelength", "duration"])
        )

        let result = Resolution(
            audioURL: audioURL,
            quality: Self.qualityName(bitrate: bitrate, format: format, hint: qualityHint),
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

    func resolvePlaylist(sharedURL: URL) async throws -> PlaylistResolution {
        let requestURL = try await finalURL(for: sharedURL)
        guard Self.isPlaylistURL(requestURL) else { throw APIError.invalidShareURL }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 30
        request.setValue("Moumusic/1.0 (iOS; Qishui playlist resolver)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.requestFailed
        }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let html = String(data: data, encoding: .utf8),
              let routerData = Self.routerData(from: html),
              let loaderData = routerData["loaderData"] as? [String: Any],
              let page = loaderData["playlist_page"] as? [String: Any],
              let medias = page["medias"] as? [[String: Any]] else {
            throw APIError.invalidResponse
        }

        let playlistInfo = page["playlistInfo"] as? [String: Any] ?? [:]
        let playlistID = Self.text(in: playlistInfo, keys: ["id", "playlist_id"])
            ?? Self.queryValue(requestURL, names: ["playlist_id", "playlistid"])
        guard let playlistID, !playlistID.isEmpty else { throw APIError.invalidResponse }

        let playlistName = Self.text(in: playlistInfo, keys: ["title", "name", "public_title"])
            ?? "汽水歌单"
        let coverURL = Self.imageURL(in: playlistInfo["url_cover"])
        let revision = Self.integer(in: playlistInfo, keys: ["update_time", "updateTime", "create_time"]) ?? 0

        let tracks = medias.compactMap { media -> PlaylistResolution.Track? in
            guard let entity = media["entity"] as? [String: Any],
                  let track = entity["track"] as? [String: Any],
                  let id = Self.text(in: track, keys: ["id"]),
                  let name = Self.text(in: track, keys: ["name", "title"]),
                  let shareURL = URL(string: "https://music.douyin.com/qishui/share/track?track_id=\(id)") else {
                return nil
            }

            let artists = track["artists"] as? [[String: Any]] ?? []
            let artistName = artists.compactMap { Self.text(in: $0, keys: ["name", "simple_display_name"]) }
                .joined(separator: " / ")
            let album = track["album"] as? [String: Any]
            let albumName = Self.text(in: album ?? [:], keys: ["name"])
            let cover = Self.imageURL(in: album?["url_cover"])
            let durationMS = Self.integer(in: track, keys: ["duration", "duration_ms", "durationMS"]) ?? 0
            return PlaylistResolution.Track(
                id: id,
                name: name,
                artistName: artistName,
                albumName: albumName,
                coverURL: cover,
                durationMS: durationMS,
                shareURL: shareURL
            )
        }

        guard !tracks.isEmpty else { throw APIError.unavailable }
        return PlaylistResolution(id: playlistID, name: playlistName, coverURL: coverURL,
                                  revision: revision, tracks: tracks)
    }

    private func finalURL(for url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            return response.url ?? url
        } catch {
            throw APIError.requestFailed
        }
    }

    private static func routerData(from html: String) -> [String: Any]? {
        guard let marker = html.range(of: "_ROUTER_DATA"),
              let openBrace = html[marker.upperBound...].firstIndex(of: "{") else {
            return nil
        }

        var index = openBrace
        var depth = 0
        var inString = false
        var escaped = false
        while index < html.endIndex {
            let character = html[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let json = String(html[openBrace...index])
                    guard let data = json.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return nil
                    }
                    return object
                }
            }
            index = html.index(after: index)
        }
        return nil
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

    private static func queryValue(_ url: URL, names: [String]) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
            names.contains($0.name.lowercased())
        }?.value
    }

    private static func imageURL(in value: Any?) -> String? {
        guard let object = value as? [String: Any] else {
            return normalizedURL(value as? String)
        }
        let uri = text(in: object, keys: ["uri"])
        let base = firstString(in: object, keys: ["urls"])
        guard let uri, let base else { return nil }
        let prefix = object["template_prefix"] as? String ?? "tplv-b829550vbb"
        let value = "\(base)\(uri)~\(prefix)-crop-center:720:720.jpg"
        return normalizedURL(value)
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
