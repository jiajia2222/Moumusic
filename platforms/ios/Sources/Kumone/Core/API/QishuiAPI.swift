import Foundation

/// Public Qishui playlist importer.
///
/// Qishui is intentionally not an audio, lyric, quality, or playback source
/// in Moumusic. This type only reads public playlist metadata. Imported tracks
/// are resolved later by the user's enabled LX User API sources.
actor QishuiAPI {
    static let shared = QishuiAPI()

    struct QRCodePayload: Sendable {
        let token: String
        let value: String
        let copywriting: String
        let expiresIn: Int
    }

    enum QRLoginStatus: Sendable {
        case waiting
        case scanned
        case success(cookie: String?, sessionID: String?)
        case expired
        case failed(String)
    }

    struct Profile {
        let id: String
        let name: String
        let avatarURL: String?
        let refreshedCookie: String?
    }

    struct Recommendation {
        let playlists: [LXPlaylistSummary]
        let tracks: [Track]
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
                return "请输入有效的汽水音乐公开歌单链接"
            case .requestFailed:
                return "汽水公开歌单请求失败，请稍后重试"
            case .invalidResponse:
                return "汽水公开歌单返回格式不正确"
            case .unavailable:
                return "汽水歌单暂时没有可导入的歌曲"
            }
        }
    }

    private let playlistEndpoint = URL(string: "https://api.qishui.com/luna/playlist/detail")!
    private let discoverEndpoint = URL(string: "https://beta-luna.douyin.com/luna/discover/mix")!
    private let profileEndpoint = URL(string: "https://api.qishui.com/luna/pc/me")!
    private let passportEndpoint = URL(string: "https://api.qishui.com")!
    private let session: URLSession

    private enum Passport {
        static let aid = "386088"
        static let iid = "27960026095955"
        static let jssdkVersion = "2.4.13"
        static let jssdkType = "normal"
        static let next = "https://api.qishui.com"
        static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
    }

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }

    /// Starts the provider's native passport QR flow. The returned `value` is
    /// the payload encoded by the QR image; it is not a webpage login form.
    /// The user scans it with the Douyin app, as required by the current
    /// Qishui passport flow.
    func qrCode() async throws -> QRCodePayload {
        var components = URLComponents(
            url: passportEndpoint.appendingPathComponent("passport/web/get_qrcode/"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "passport_jssdk_version", value: Passport.jssdkVersion),
            URLQueryItem(name: "passport_jssdk_type", value: Passport.jssdkType),
            URLQueryItem(name: "is_from_ttaccountsdk", value: "1"),
            URLQueryItem(name: "aid", value: Passport.aid),
            URLQueryItem(name: "next", value: Passport.next),
            URLQueryItem(name: "need_logo", value: "false"),
            URLQueryItem(name: "need_short_url", value: "false"),
            URLQueryItem(name: "is_new_login", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(Passport.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.requestFailed
        }

        let payload = Self.dictionary(in: root, keys: ["data"]) ?? root
        guard let token = Self.text(in: payload, keys: ["token", "qrcode_token"]),
              let value = Self.text(in: payload, keys: ["qrcode", "qr_code", "qrcode_url"]),
              !token.isEmpty, !value.isEmpty else {
            throw APIError.invalidResponse
        }
        return QRCodePayload(
            token: token,
            value: value,
            copywriting: Self.text(in: payload, keys: ["copywriting", "message"])
                ?? "使用抖音 App 扫码登录",
            expiresIn: Self.integer(in: payload, keys: ["expire_time", "expires_in"]) ?? 180
        )
    }

    /// Polls the same passport QR session. Credentials are only returned to
    /// the in-process session store after the provider confirms the scan.
    func qrLoginStatus(token: String) async throws -> QRLoginStatus {
        var components = URLComponents(
            url: passportEndpoint.appendingPathComponent("passport/web/check_qrconnect/"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "passport_jssdk_version", value: Passport.jssdkVersion),
            URLQueryItem(name: "passport_jssdk_type", value: Passport.jssdkType),
            URLQueryItem(name: "is_from_ttaccountsdk", value: "1"),
            URLQueryItem(name: "aid", value: Passport.aid),
            URLQueryItem(name: "iid", value: Passport.iid)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(Passport.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncoded([
            "need_logo": "false",
            "need_short_url": "false",
            "is_frontier": "true",
            "token": token,
            "is_new_login": "1",
            "next": Passport.next
        ])

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.requestFailed
        }

        let payload = Self.dictionary(in: root, keys: ["data"]) ?? root
        let rawStatus = Self.text(in: payload, keys: ["status", "code", "status_code"])
            ?? String(Self.integer(in: payload, keys: ["status", "code", "status_code"]) ?? -1)
        let status = rawStatus.lowercased()
        switch status {
        // The passport endpoint returns `new` for a freshly-created QR code.
        // Treat it as a waiting state instead of surfacing a false login error.
        case "new", "801", "wait", "waiting", "pending":
            return .waiting
        case "802", "scan", "scanned", "scaned", "scanning", "confirm":
            return .scanned
        case "803", "success", "confirmed", "ok":
            let auth = Self.dictionary(in: payload, keys: ["auth", "credential"])
            let sessionID = Self.text(in: auth ?? payload, keys: ["sessionid", "session_id"])
            let cookie = Self.cookieHeader(from: response as? HTTPURLResponse)
            return .success(cookie: cookie.isEmpty ? nil : cookie, sessionID: sessionID)
        case "800", "expired", "timeout":
            return .expired
        default:
            let message = Self.text(in: payload, keys: ["message", "msg", "error_message"])
                ?? "汽水扫码登录失败"
            return .failed(message)
        }
    }

    /// Validates a pasted browser Cookie against Qishui's account endpoint.
    /// The Cookie is sent only as an HTTP header and is never returned in a
    /// model, error, or diagnostic string.
    func profile(cookie: String) async throws -> Profile {
        var components = URLComponents(url: profileEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "aid", value: "386088")]
        let result = try await requestObject(url: components.url!, cookie: cookie)
        let root = result.root
        let info = root["my_info"] as? [String: Any]
            ?? root["user"] as? [String: Any]
            ?? root
        guard let id = Self.text(in: info, keys: ["id", "uid", "user_id"]),
              let name = Self.text(in: info, keys: ["nickname", "name"]),
              !name.isEmpty else {
            throw APIError.invalidResponse
        }
        return Profile(id: id, name: name,
                       avatarURL: Self.imageURL(in: info["avatar_url"])
                        ?? Self.imageURL(in: info["avatar"])
                        ?? Self.normalizedURL(Self.text(in: info, keys: ["avatarUrl"])),
                       refreshedCookie: result.refreshedCookie)
    }

    /// Returns Qishui's live discover feed. Passing a valid Cookie makes the
    /// upstream return the signed-in account's recommendation blocks; without
    /// it the same adapter intentionally falls back to public recommendations.
    func recommendedContent(cookie: String?, limit: Int = 30) async throws -> Recommendation {
        let body: [String: Any] = ["count": max(1, min(limit, 50))]
        let root = try await requestObject(url: discoverEndpoint, method: "POST",
                                           body: body, cookie: cookie).root
        let blocks = root["inner_block"] as? [[String: Any]] ?? []
        var playlists: [LXPlaylistSummary] = []
        var tracks: [Track] = []
        var seenPlaylists = Set<String>()
        var seenTracks = Set<String>()

        for block in blocks {
            let resources = block["resources"] as? [[String: Any]] ?? []
            for resource in resources {
                let entity = resource["entity"] as? [String: Any] ?? resource
                if let playlist = entity["playlist"] as? [String: Any],
                   let id = Self.text(in: playlist, keys: ["id", "playlist_id"]),
                   seenPlaylists.insert(id).inserted {
                    let stats = playlist["stats"] as? [String: Any]
                    let owner = playlist["owner"] as? [String: Any]
                    playlists.append(LXPlaylistSummary(
                        id: id,
                        name: Self.text(in: playlist, keys: ["title", "name", "public_title"])
                            ?? "汽水歌单",
                        coverURL: Self.imageURL(in: playlist["url_cover"])
                            ?? Self.normalizedURL(Self.text(in: playlist, keys: ["cover_url", "coverUrl"])),
                        playCount: Self.integer(in: stats ?? [:], keys: ["count_played", "play_count"]) ?? 0,
                        trackCount: Self.integer(in: playlist,
                                                 keys: ["count_tracks", "track_count", "song_count"]) ?? 0,
                        description: Self.text(in: playlist, keys: ["desc", "description", "intro"]),
                        author: Self.text(in: owner ?? [:], keys: ["nickname", "name"]),
                        source: .sd
                    ))
                }

                let trackObject = (entity["track_wrapper"] as? [String: Any])
                    ?? (entity["track"] as? [String: Any])
                if let trackObject,
                   let track = Self.track(from: trackObject),
                   seenTracks.insert(track.playbackKey).inserted {
                    tracks.append(track)
                }
            }
        }
        return Recommendation(playlists: Array(playlists.prefix(limit)),
                              tracks: Array(tracks.prefix(limit)))
    }

    /// Resolves a recommendation playlist through the public share page. The
    /// share page currently carries the full track list in router data, while
    /// the mobile detail endpoint may return metadata only.
    func resolvePlaylist(id: String, cookie: String? = nil) async throws -> PlaylistResolution {
        guard !id.isEmpty,
              let url = URL(string: "https://music.douyin.com/qishui/share/playlist?playlist_id=\(id)") else {
            throw APIError.invalidShareURL
        }
        do {
            return try await resolvePlaylistFromHTML(url: url, cookie: cookie)
        } catch {
            return try await resolvePlaylistFromAPI(id: id, cookie: cookie)
        }
    }

    static func isPlaylistURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host == "music.douyin.com" || host == "m.douyin.com"
                || host == "qishui.douyin.com" || host.hasSuffix(".douyin.com") else {
            return false
        }
        let path = url.path.lowercased()
        let hasPlaylistPath = path.contains("/qishui/playlist")
            || path.contains("/qishui/share/playlist")
            || path.contains("/share/playlist")
            || path.contains("/playlist/")
        let hasPlaylistID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            ["playlist_id", "playlistid", "id"].contains($0.name.lowercased())
        } == true
        return hasPlaylistPath || (hasPlaylistID && path.contains("playlist"))
    }

    /// Short Qishui links must be redirected before checking whether they are
    /// public playlists. A direct song link is intentionally not supported.
    static func isShortShareURL(_ url: URL) -> Bool {
        url.path.lowercased().hasPrefix("/s/")
    }

    func resolvePlaylist(sharedURL: URL) async throws -> PlaylistResolution {
        let requestURL = try await finalURL(for: sharedURL)
        guard Self.isPlaylistURL(requestURL),
              let playlistID = Self.playlistID(from: requestURL),
              !playlistID.isEmpty else {
            throw APIError.invalidShareURL
        }

        // The public page is a SEO preview and commonly contains only the
        // first 50/100 entries. The public detail endpoint exposes a cursor;
        // walk every page so a 400-song playlist is not silently truncated.
        do {
            return try await resolvePlaylistFromAPI(id: playlistID, cookie: nil)
        } catch {
            // Keep a page parser as a compatibility fallback for old links or
            // temporary endpoint failures. It can still import every entry
            // embedded in the public page, but it is never used for playback.
            do {
                return try await resolvePlaylistFromHTML(url: requestURL, cookie: nil)
            } catch {
                throw error
            }
        }
    }

    private func resolvePlaylistFromAPI(id: String, cookie: String?) async throws -> PlaylistResolution {
        var cursor = ""
        var playlistInfo: [String: Any] = [:]
        var collected: [PlaylistResolution.Track] = []
        var seenIDs = Set<String>()

        for _ in 0..<100 {
            var request = URLRequest(url: playlistEndpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("Moumusic/1.0 (iOS; public Qishui playlist import)",
                             forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let cookie, !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            let body: [String: Any] = [
                "playlist_id": id,
                "playlist_type": 0,
                "count": 100,
                "cursor": cursor,
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
                  Self.isSuccessfulPlaylistResponse(root) else {
                throw APIError.invalidResponse
            }

            if let info = root["playlist"] as? [String: Any] {
                playlistInfo = info
            }
            let resources = root["media_resources"] as? [[String: Any]] ?? []
            for resource in resources {
                guard let track = Self.playlistTrack(from: resource),
                      seenIDs.insert(track.id).inserted else { continue }
                collected.append(track)
            }

            let hasMore = Self.bool(in: root, keys: ["has_more", "hasMore"])
            let nextCursor = Self.text(in: root, keys: ["next_cursor", "nextCursor", "cursor"]) ?? ""
            let expectedCount = Self.integer(in: playlistInfo,
                                              keys: ["count_tracks", "track_count", "resource_count"]) ?? 0
            let reachedExpectedCount = expectedCount > 0 && collected.count >= expectedCount
            guard !reachedExpectedCount,
                  !resources.isEmpty,
                  !nextCursor.isEmpty,
                  nextCursor != cursor,
                  hasMore || expectedCount > collected.count else {
                break
            }
            cursor = nextCursor
        }

        guard !collected.isEmpty else { throw APIError.unavailable }
        let name = Self.text(in: playlistInfo, keys: ["title", "public_title", "name"])
            ?? "汽水歌单"
        let coverURL = Self.imageURL(in: playlistInfo["url_cover"])
        let revision = Self.integer(in: playlistInfo,
                                    keys: ["update_time", "updateTime", "create_time"]) ?? 0
        return PlaylistResolution(id: id, name: name, coverURL: coverURL,
                                  revision: revision, tracks: collected)
    }

    private func resolvePlaylistFromHTML(url: URL, cookie: String?) async throws -> PlaylistResolution {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.requestFailed
        }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let html = String(data: data, encoding: .utf8) else {
            throw APIError.invalidResponse
        }

        if let payload = Self.routerPlaylistPayload(from: html) {
            return try Self.playlistResolution(from: payload, fallbackID: Self.playlistID(from: url))
        }
        if let payload = Self.ssrPlaylistPayload(from: html) {
            return try Self.ssrPlaylistResolution(from: payload,
                                                  fallbackID: Self.playlistID(from: url))
        }
        throw APIError.invalidResponse
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

    private static func playlistTrack(from resource: [String: Any]) -> PlaylistResolution.Track? {
        let entity = resource["entity"] as? [String: Any] ?? [:]
        let wrapper = entity["track_wrapper"] as? [String: Any]
        let track = (wrapper?["track"] as? [String: Any])
            ?? (entity["track"] as? [String: Any])
            ?? (resource["track"] as? [String: Any])
            ?? [:]
        return trackValue(track)
    }

    private static func track(from value: [String: Any]) -> Track? {
        guard let id = text(in: value, keys: ["id", "track_id"]), !id.isEmpty,
              let name = text(in: value, keys: ["name", "title"]), !name.isEmpty else {
            return nil
        }
        let artists = value["artists"] as? [[String: Any]] ?? []
        let artistNames = artists.compactMap {
            text(in: $0, keys: ["name", "simple_display_name"])
        }
        let album = value["album"] as? [String: Any] ?? [:]
        let cover = imageURL(in: album["url_cover"])
            ?? imageURL(in: value["url_cover"])
            ?? normalizedURL(text(in: value, keys: ["cover", "cover_url", "coverUrl"]))
        let duration = integer(in: value, keys: ["duration", "duration_ms", "durationMS"]) ?? 0
        let numericID = Int(id) ?? stableNumericID(id)
        guard numericID > 0 else { return nil }
        return Track(id: numericID,
                     name: name,
                     artists: artistNames.map { ArtistRef(id: 0, name: $0) },
                     album: AlbumRef(id: Int(text(in: album, keys: ["id"]) ?? "") ?? 0,
                                     name: text(in: album, keys: ["name"]) ?? "",
                                     picUrl: cover),
                     durationMS: duration < 1000 ? duration * 1000 : duration,
                     source: "sd",
                     sourceMetadata: ["songmid": id, "source": "sd"])
    }

    private static func stableNumericID(_ value: String) -> Int {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return Int(hash & 0x3fff_ffff_ffff_ffff) + 1
    }

    private struct RequestResult {
        let root: [String: Any]
        let refreshedCookie: String?
    }

    private func requestObject(url: URL, method: String = "GET",
                               body: [String: Any]? = nil,
                               cookie: String? = nil) async throws -> RequestResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Luna/19.1.0 Android", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.requestFailed
        }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.requestFailed
        }
        if let status = Self.integer(in: root, keys: ["status_code", "code"]), status != 0,
           status != 200 {
            throw APIError.unavailable
        }
        return RequestResult(root: root,
                             refreshedCookie: Self.mergedCookie(
                                original: cookie,
                                response: response as? HTTPURLResponse
                             ))
    }

    private static func trackValue(_ track: [String: Any]) -> PlaylistResolution.Track? {
        guard let id = text(in: track, keys: ["id", "track_id"]), !id.isEmpty,
              let name = text(in: track, keys: ["name", "title"]), !name.isEmpty else {
            return nil
        }
        let artists = track["artists"] as? [[String: Any]] ?? []
        var artistNames = artists.compactMap { text(in: $0, keys: ["name", "simple_display_name"]) }
        if artistNames.isEmpty, let values = track["artist_name_list"] as? [String] {
            artistNames = values
        }
        let artistName = artistNames.joined(separator: " / ")
        let album = track["album"] as? [String: Any] ?? [:]
        let albumName = text(in: album, keys: ["name"])
        let coverURL = imageURL(in: album["url_cover"])
            ?? imageURL(in: track["url_cover"])
            ?? normalizedURL(text(in: track, keys: ["cover", "cover_url", "coverUrl"]))
        let durationMS = integer(in: track, keys: ["duration_ms", "durationMS", "duration"])
            ?? durationMilliseconds(track["duration"])
        let shareURL = URL(string: "https://music.douyin.com/qishui/share/track?track_id=\(id)")!
        return PlaylistResolution.Track(id: id, name: name, artistName: artistName,
                                        albumName: albumName, coverURL: coverURL,
                                        durationMS: durationMS, shareURL: shareURL)
    }

    private static func playlistResolution(from page: [String: Any], fallbackID: String?) throws -> PlaylistResolution {
        let info = page["playlistInfo"] as? [String: Any] ?? [:]
        let id = text(in: info, keys: ["id", "playlist_id"]) ?? fallbackID ?? ""
        let medias = page["medias"] as? [[String: Any]] ?? []
        let tracks = medias.compactMap { playlistTrack(from: $0) }
        guard !id.isEmpty, !tracks.isEmpty else { throw APIError.unavailable }
        return PlaylistResolution(
            id: id,
            name: text(in: info, keys: ["title", "name", "public_title"]) ?? "汽水歌单",
            coverURL: imageURL(in: info["url_cover"]),
            revision: integer(in: info, keys: ["update_time", "updateTime", "create_time"]) ?? 0,
            tracks: deduplicated(tracks)
        )
    }

    private static func ssrPlaylistResolution(from playlist: [String: Any], fallbackID: String?) throws -> PlaylistResolution {
        let rawItems = playlist["music_list"] as? [[String: Any]] ?? []
        let tracks = rawItems.compactMap { item -> PlaylistResolution.Track? in
            guard let id = text(in: item, keys: ["track_id", "id"]),
                  let name = text(in: item, keys: ["name", "title"]) else { return nil }
            var itemWithTrack = item
            itemWithTrack["id"] = id
            itemWithTrack["artist_name_list"] = item["artist_name_list"] ?? []
            return trackValue(itemWithTrack)
        }
        guard !tracks.isEmpty else { throw APIError.unavailable }
        let id = text(in: playlist, keys: ["UniqId", "uniq_id", "id"]) ?? fallbackID ?? ""
        guard !id.isEmpty else { throw APIError.invalidResponse }
        return PlaylistResolution(id: id,
                                  name: text(in: playlist, keys: ["keyword", "title", "name"]) ?? "汽水歌单",
                                  coverURL: normalizedURL(text(in: playlist, keys: ["cover_url", "coverUrl"])),
                                  revision: 0, tracks: deduplicated(tracks))
    }

    private static func deduplicated(_ tracks: [PlaylistResolution.Track]) -> [PlaylistResolution.Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    private static func routerPlaylistPayload(from html: String) -> [String: Any]? {
        guard let root = jsonObject(after: "_ROUTER_DATA", in: html),
              let loaderData = root["loaderData"] as? [String: Any],
              let page = loaderData["playlist_page"] as? [String: Any] else { return nil }
        return page
    }

    private static func ssrPlaylistPayload(from html: String) -> [String: Any]? {
        guard let root = jsonObject(after: "window._SSR_DATA", in: html),
              let data = root["data"] as? [String: Any],
              let loaders = data["loadersData"] as? [String: Any] else { return nil }
        for value in loaders.values {
            guard let loader = value as? [String: Any],
                  let loaderData = loader["data"] as? [String: Any],
                  let playlist = loaderData["qishui_playlist"] as? [String: Any] else { continue }
            return playlist
        }
        return nil
    }

    private static func jsonObject(after marker: String, in text: String) -> [String: Any]? {
        guard let markerRange = text.range(of: marker),
              let openBrace = text[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        var index = openBrace
        var depth = 0
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" { inString = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let json = String(text[openBrace...index])
                    guard let data = json.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return nil
                    }
                    return object
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func playlistID(from url: URL) -> String? {
        if let value = queryValue(url, names: ["playlist_id", "playlistid", "id"]), !value.isEmpty {
            return value
        }
        let parts = url.path.split(separator: "/").map(String.init)
        for marker in ["playlist", "list"] {
            if let index = parts.firstIndex(where: { $0.lowercased() == marker }), index + 1 < parts.count {
                let value = parts[index + 1].split(separator: ".").first.map(String.init) ?? ""
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func isSuccessfulPlaylistResponse(_ object: [String: Any]) -> Bool {
        if let value = integer(object["status_code"]), value != 0 { return false }
        if let value = integer(object["code"]), value != 0 && value != 200 { return false }
        return object["playlist"] is [String: Any]
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let number = Int(value) { return number }
        return nil
    }

    private static func dictionary(in object: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = object[key] as? [String: Any] { return value }
        }
        return nil
    }

    private static func formEncoded(_ values: [String: String]) -> Data? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = values
            .sorted { $0.key < $1.key }
            .map { key, value in
                let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(escapedKey)=\(escapedValue)"
            }
            .joined(separator: "&")
        return body.data(using: .utf8)
    }

    private static func cookieHeader(from response: HTTPURLResponse?) -> String {
        guard let response else { return "" }
        let rawValues = response.allHeaderFields.reduce(into: [String]()) { result, entry in
            guard String(describing: entry.key).lowercased() == "set-cookie" else { return }
            if let values = entry.value as? [String] {
                result.append(contentsOf: values)
            } else {
                result.append(String(describing: entry.value))
            }
        }
        return rawValues
            .flatMap { $0.split(separator: ",") }
            .compactMap { $0.split(separator: ";", maxSplits: 1).first }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
    }

    private static func bool(in object: [String: Any], keys: [String]) -> Bool {
        for key in keys {
            if let value = object[key] as? Bool { return value }
            if let value = object[key] as? NSNumber { return value.boolValue }
            if let value = object[key] as? String { return ["1", "true", "yes"].contains(value.lowercased()) }
        }
        return false
    }

    private static func text(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
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

    private static func queryValue(_ url: URL, names: [String]) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first {
            names.contains($0.name.lowercased())
        }?.value
    }

    private static func normalizedURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let normalized = value.hasPrefix("//") ? "https:" + value : value.replacingOccurrences(of: "http://", with: "https://")
        return URL(string: normalized) == nil ? nil : normalized
    }

    private static func mergedCookie(original: String?, response: HTTPURLResponse?) -> String? {
        guard let original,
              let response,
              let header = response.allHeaderFields.first(where: {
                  String(describing: $0.key).lowercased() == "set-cookie"
              })?.value else { return nil }
        var values = original.split(separator: ";").reduce(into: [String: String]()) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1]
        }
        for part in String(describing: header).split(separator: ",") {
            let pair = part.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            let fields = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if fields.count == 2 { values[fields[0].trimmingCharacters(in: .whitespaces)] = fields[1] }
        }
        return values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private static func imageURL(in value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return normalizedURL(value as? String) }
        let uri = text(in: object, keys: ["uri"])
        let base = object["urls"] as? [String]
        let firstBase = base?.first(where: { !$0.isEmpty })
        if let uri, let firstBase {
            let prefix = object["template_prefix"] as? String ?? "tplv-b829550vbb"
            return normalizedURL("\(firstBase)\(uri)~\(prefix)-crop-center:720:720.jpg")
        }
        return normalizedURL(firstBase)
    }

    private static func durationMilliseconds(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Int(raw < 1000 ? raw * 1000 : raw)
        }
        guard let string = value as? String else { return 0 }
        if string.contains(":"), let seconds = string.split(separator: ":").compactMap({ Double($0) }).last {
            let minutes = Double(string.split(separator: ":").first ?? "0") ?? 0
            return Int((minutes * 60 + seconds) * 1000)
        }
        guard let raw = Double(string) else { return 0 }
        return Int(raw < 1000 ? raw * 1000 : raw)
    }
}
