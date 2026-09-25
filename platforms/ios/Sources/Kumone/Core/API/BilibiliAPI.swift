import Foundation

/// Bilibili public-content and account client.
///
/// The player consumes the same public playurl/subtitle data used by
/// PiliPlus.  Account cookies are only passed in-process and are never
/// returned by this API to a web page.
actor BilibiliAPI {
    static let shared = BilibiliAPI()

    struct QRCodePayload: Sendable {
        let url: String
        let key: String
    }

    enum QRStatus: Sendable {
        case waiting
        case scanned
        case success(cookie: String)
        case expired
    }

    struct Profile: Sendable {
        let id: String
        let name: String
        let avatarURL: String?
    }

    struct Video: Identifiable, Hashable, Sendable {
        let bvid: String
        let aid: Int
        let cid: Int?
        let title: String
        let coverURL: String?
        let author: String
        let authorID: Int
        let authorAvatarURL: String?
        let description: String
        let duration: TimeInterval
        let durationText: String
        let playCount: Int
        let commentCount: Int
        let publishedAt: Date?
        let subtitles: [Subtitle]

        var id: String { bvid }

        func replacingSubtitles(_ subtitles: [Subtitle]) -> Video {
            Video(
                bvid: bvid,
                aid: aid,
                cid: cid,
                title: title,
                coverURL: coverURL,
                author: author,
                authorID: authorID,
                authorAvatarURL: authorAvatarURL,
                description: description,
                duration: duration,
                durationText: durationText,
                playCount: playCount,
                commentCount: commentCount,
                publishedAt: publishedAt,
                subtitles: subtitles
            )
        }
    }

    struct VideoQuality: Identifiable, Hashable, Sendable {
        let code: Int
        let title: String

        var id: Int { code }
    }

    /// A DASH audio representation returned by Bilibili.  The title is
    /// derived from the response bitrate; it is never upgraded to a label
    /// such as lossless unless the service actually exposes that data.
    struct BilibiliAudioQuality: Identifiable, Hashable, Sendable {
        let code: Int
        let title: String
        let bitrate: Int?

        var id: Int { code }
    }

    struct AudioPlayback: Sendable {
        let url: URL
        let quality: BilibiliAudioQuality
        let qualities: [BilibiliAudioQuality]
    }

    struct Subtitle: Identifiable, Hashable, Sendable {
        let id: String
        let language: String
        let title: String
        let url: URL
        let isAIGenerated: Bool
        let isTranslated: Bool
        let format: String

        var displayTitle: String {
            if isAIGenerated && isTranslated {
                return "AI 翻译字幕 · \(title)"
            }
            if isAIGenerated {
                return "AI 字幕 · \(title)"
            }
            if isTranslated {
                return "翻译字幕 · \(title)"
            }
            return title
        }
    }

    struct SubtitleCue: Identifiable, Hashable, Sendable {
        let id: String
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    struct Playback: Sendable {
        let url: URL
        let quality: Int
        let qualities: [VideoQuality]
    }

    struct LiveArea: Identifiable, Hashable, Sendable {
        let id: Int
        let parentID: Int
        let name: String
        let parentName: String

        var title: String {
            guard !parentName.isEmpty, parentName != name else { return name }
            return "\(parentName) · \(name)"
        }
    }

    struct LiveRoom: Identifiable, Hashable, Sendable {
        let roomID: Int
        let uid: Int
        let title: String
        let coverURL: String?
        let userName: String
        let userAvatarURL: String?
        let areaName: String
        let parentAreaName: String
        let online: Int
        let liveStatus: Int
        let isPortrait: Bool

        var id: Int { roomID }
        var isLive: Bool { liveStatus == 1 || liveStatus == 2 }
    }

    struct LiveQuality: Identifiable, Hashable, Sendable {
        let code: Int
        let title: String

        var id: Int { code }
    }

    struct LivePlayback: Sendable {
        let url: URL
        let quality: Int
        let qualities: [LiveQuality]
    }

    struct User: Identifiable, Hashable, Sendable {
        let mid: Int
        let name: String
        let avatarURL: String?
        let signature: String
        let followerCount: Int

        var id: Int { mid }
    }

    struct Collection: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let coverURL: String?
        let subtitle: String
        let itemCount: Int
    }

    struct SearchPage: Sendable {
        let videos: [Video]
        let users: [User]
        let collections: [Collection]
        let total: Int
    }

    enum CommentSort: String, Hashable, Sendable {
        case hot
        case latest
    }

    struct Comment: Identifiable, Hashable, Sendable {
        let id: String
        let author: String
        let avatarURL: String?
        let message: String
        let likeCount: Int
        let publishedAt: Date?
        let replyCount: Int
    }

    struct CommentPage: Sendable {
        let comments: [Comment]
        let total: Int
        let hasMore: Bool
    }

    enum APIError: LocalizedError {
        case requestFailed
        case invalidResponse
        case unavailable
        case offline

        var errorDescription: String? {
            switch self {
            case .requestFailed:
                return "B 站请求失败，请检查网络后重试"
            case .invalidResponse:
                return "B 站返回的数据格式无法识别"
            case .unavailable:
                return "B 站服务暂时不可用，请稍后重试"
            case .offline:
                return "这个直播间当前未开播"
            }
        }
    }

    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
    private var visitorBootstrapAttempted = false
    private let sessionCookieNames = [
        "DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct", "sid"
    ]
    private let visitorCookieNames = ["buvid3", "buvid4", "b_nut", "_uuid", "buvid_fp"]

    private init() {
        cookieStorage = HTTPCookieStorage()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = cookieStorage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }

    func qrCode() async throws -> QRCodePayload {
        let endpoint = URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate")!
        var request = URLRequest(url: endpoint.appending(queryItems: [
            URLQueryItem(name: "source", value: "main_web")
        ]))
        applyHeaders(to: &request, referer: "https://www.bilibili.com/")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response),
              let root = Self.object(data),
              let payload = root["data"] as? [String: Any],
              let url = Self.text(payload["url"]),
              let key = Self.text(payload["qrcode_key"]),
              !url.isEmpty, !key.isEmpty else {
            throw APIError.invalidResponse
        }
        return QRCodePayload(url: url, key: key)
    }

    func poll(key: String) async throws -> QRStatus {
        var components = URLComponents(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll")!
        components.queryItems = [
            URLQueryItem(name: "qrcode_key", value: key),
            URLQueryItem(name: "source", value: "main_web")
        ]
        var request = URLRequest(url: components.url!)
        applyHeaders(to: &request, referer: "https://www.bilibili.com/")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response),
              let root = Self.object(data),
              let payload = root["data"] as? [String: Any] else {
            throw APIError.requestFailed
        }

        let code = Self.integer(payload["code"]) ?? Self.integer(root["code"])
        switch code {
        case 86101:
            return .waiting
        case 86090:
            return .scanned
        case 86038:
            return .expired
        case 0:
            let stored = cookieHeader()
            let fromURL = Self.cookieHeader(fromLoginURL: Self.text(payload["url"]) ?? Self.text(root["url"]))
            let cookies = Self.mergedCookieHeaders(stored, fromURL)
            guard !cookies.isEmpty else { throw APIError.unavailable }
            return .success(cookie: cookies)
        default:
            throw APIError.unavailable
        }
    }

    func profile(cookie: String) async throws -> Profile {
        await ensureVisitorCookies()
        let endpoint = URL(string: "https://api.bilibili.com/x/web-interface/nav")!
        var request = URLRequest(url: endpoint)
        applyHeaders(to: &request, referer: "https://www.bilibili.com/")
        request.setValue(mergedRequestCookieHeader(cookie), forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response),
              let root = Self.object(data),
              Self.integer(root["code"]) == 0,
              let payload = root["data"] as? [String: Any],
              Self.bool(payload["isLogin"]) == true,
              let id = Self.text(payload["mid"]),
              let name = Self.text(payload["uname"]),
              !name.isEmpty else {
            throw APIError.unavailable
        }
        return Profile(id: id, name: name, avatarURL: Self.imageURL(Self.text(payload["face"])))
    }

    func popularVideos(page: Int = 1, cookie: String? = nil) async throws -> [Video] {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/popular")!
        components.queryItems = [
            URLQueryItem(name: "ps", value: "20"),
            URLQueryItem(name: "pn", value: "\(max(1, page))")
        ]
        let root = try await requestObject(components.url!, cookie: cookie)
        let data = root["data"] as? [String: Any]
        let rows = data?["list"] as? [[String: Any]] ?? []
        return rows.compactMap(Self.video)
    }

    // MARK: - Live

    /// Returns the currently popular live rooms.  The response mapping is an
    /// independent Swift implementation of Bilibili's public live endpoints;
    /// no PiliPlus source or Flutter runtime is embedded in Moumusic.
    func popularLiveRooms(page: Int = 1, pageSize: Int = 30,
                          cookie: String? = nil) async throws -> [LiveRoom] {
        try await liveRooms(parentAreaID: 0, areaID: 0, page: page,
                            pageSize: pageSize, cookie: cookie)
    }

    func liveRooms(parentAreaID: Int, areaID: Int, page: Int = 1,
                   pageSize: Int = 30, cookie: String? = nil) async throws -> [LiveRoom] {
        var components = URLComponents(string: "https://api.live.bilibili.com/room/v1/area/getRoomList")!
        components.queryItems = [
            URLQueryItem(name: "area_id", value: "\(max(0, areaID))"),
            URLQueryItem(name: "sort_type", value: "online"),
            URLQueryItem(name: "page_size", value: "\(min(max(1, pageSize), 50))"),
            URLQueryItem(name: "page_no", value: "\(max(1, page))")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://live.bilibili.com/")
        let rows = Self.liveRoomRows(root["data"])
        let rooms = Self.uniqueLiveRooms(rows.compactMap(Self.liveRoom))
        guard !rooms.isEmpty else { throw APIError.invalidResponse }
        return rooms
    }

    func liveAreas(cookie: String? = nil) async throws -> [LiveArea] {
        let endpoint = URL(string: "https://api.live.bilibili.com/room/v1/Area/getList")!
        let root = try await requestObject(endpoint, cookie: cookie,
                                           referer: "https://live.bilibili.com/")
        let data = root["data"]
        let parents: [[String: Any]]
        if let rows = data as? [[String: Any]] {
            parents = rows
        } else if let payload = data as? [String: Any] {
            parents = (payload["data"] as? [[String: Any]])
                ?? (payload["list"] as? [[String: Any]])
                ?? []
        } else {
            parents = []
        }

        var areas: [LiveArea] = []
        for parent in parents {
            let parentID = Self.integer(parent["id"] ?? parent["parent_id"]) ?? 0
            let parentName = Self.stripHTML(Self.text(parent["name"] ?? parent["parent_name"]) ?? "")
            let children = (parent["list"] as? [[String: Any]])
                ?? (parent["children"] as? [[String: Any]])
                ?? []
            if children.isEmpty, parentID > 0, !parentName.isEmpty {
                areas.append(LiveArea(id: parentID, parentID: parentID,
                                      name: parentName, parentName: parentName))
            } else {
                for child in children {
                    let id = Self.integer(child["id"] ?? child["area_id"]) ?? 0
                    let name = Self.stripHTML(Self.text(child["name"] ?? child["area_name"]) ?? "")
                    guard id > 0, !name.isEmpty else { continue }
                    areas.append(LiveArea(id: id, parentID: parentID,
                                         name: name, parentName: parentName))
                }
            }
        }
        var seen = Set<Int>()
        return areas.filter { seen.insert($0.id).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func searchLiveRooms(keyword: String, page: Int = 1,
                         cookie: String? = nil) async throws -> [LiveRoom] {
        let cleaned = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return try await popularLiveRooms(cookie: cookie) }
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/wbi/search/type")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: cleaned),
            URLQueryItem(name: "search_type", value: "live_room"),
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "order", value: "online"),
            URLQueryItem(name: "highlight", value: "0")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://search.bilibili.com/")
        let rooms = Self.uniqueLiveRooms(Self.liveRoomRows(root["data"])
            .compactMap(Self.liveRoom))
        return rooms
    }

    /// Resolves a room to an HLS-compatible URL for WKWebView.  The v2
    /// endpoint is preferred, with the public legacy playUrl endpoint as a
    /// fallback for older room responses.
    func livePlayback(for roomID: Int, quality: Int? = nil,
                      cookie: String? = nil) async throws -> LivePlayback {
        guard roomID > 0 else { throw APIError.invalidResponse }
        let resolved = try await resolveLiveRoom(roomID: roomID, cookie: cookie)
        guard resolved.liveStatus == nil || resolved.liveStatus == 1 || resolved.liveStatus == 2 else {
            throw APIError.offline
        }

        do {
            return try await livePlaybackV2(roomID: resolved.roomID,
                                            quality: quality, cookie: cookie)
        } catch {
            return try await livePlaybackLegacy(roomID: resolved.roomID,
                                                quality: quality, cookie: cookie)
        }
    }

    private func resolveLiveRoom(roomID: Int, cookie: String?) async throws -> (roomID: Int, liveStatus: Int?) {
        var components = URLComponents(string: "https://api.live.bilibili.com/room/v1/Room/room_init")!
        components.queryItems = [URLQueryItem(name: "id", value: "\(roomID)")]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://live.bilibili.com/\(roomID)")
        guard let data = root["data"] as? [String: Any],
              let resolvedID = Self.integer(data["room_id"] ?? data["roomid"]),
              resolvedID > 0 else {
            throw APIError.invalidResponse
        }
        return (resolvedID, Self.integer(data["live_status"]))
    }

    private func livePlaybackV2(roomID: Int, quality: Int?, cookie: String?) async throws -> LivePlayback {
        var components = URLComponents(string: "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo")!
        components.queryItems = [
            URLQueryItem(name: "room_id", value: "\(roomID)"),
            URLQueryItem(name: "protocol", value: "0,1"),
            URLQueryItem(name: "format", value: "0,1,2"),
            URLQueryItem(name: "codec", value: "0,1"),
            URLQueryItem(name: "qn", value: "\(quality ?? 0)"),
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "ptype", value: "8"),
            URLQueryItem(name: "dolby", value: "5"),
            URLQueryItem(name: "panorama", value: "1"),
            URLQueryItem(name: "no_playurl", value: "0")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://live.bilibili.com/\(roomID)")
        guard let data = root["data"] as? [String: Any],
              let playurlInfo = data["playurl_info"] as? [String: Any],
              let playurl = playurlInfo["playurl"] as? [String: Any],
              let streams = playurl["stream"] as? [[String: Any]] else {
            throw APIError.invalidResponse
        }

        var qualityNames: [Int: String] = [:]
        var qualityCodes = Set<Int>()
        var candidates: [(url: URL, quality: Int, score: Int)] = []
        let qualityDescriptions = playurl["g_qn_desc"] as? [[String: Any]] ?? []
        for description in qualityDescriptions {
            guard let code = Self.integer(description["qn"]), code > 0 else { continue }
            qualityNames[code] = Self.text(description["desc"] ?? description["description"])
                ?? Self.liveQualityTitle(code)
        }
        for stream in streams {
            let protocolName = Self.text(stream["protocol_name"]) ?? ""
            let formats = stream["format"] as? [[String: Any]] ?? []
            for format in formats {
                let formatName = Self.text(format["format_name"]) ?? ""
                let codecs = format["codec"] as? [[String: Any]] ?? []
                for codec in codecs {
                    let accepted = Self.integers(codec["accept_qn"] ?? codec["accept_quality"])
                    let currentQuality = Self.integer(codec["current_qn"] ?? codec["qn"])
                        ?? quality ?? accepted.max() ?? 80
                    for code in accepted where code > 0 { qualityCodes.insert(code) }
                    let descriptions = codec["accept_description"] as? [Any] ?? []
                    for (index, code) in accepted.enumerated() where index < descriptions.count {
                        if let description = Self.text(descriptions[index]), !description.isEmpty {
                            qualityNames[code] = description
                        }
                    }

                    let baseURL = Self.text(codec["base_url"] ?? codec["baseUrl"]) ?? ""
                    guard !baseURL.isEmpty else { continue }
                    let urlInfos = codec["url_info"] as? [[String: Any]] ?? []
                    for info in urlInfos {
                        let host = Self.text(info["host"]) ?? ""
                        let extra = Self.text(info["extra"]) ?? ""
                        guard let url = URL(string: host + baseURL + extra) else { continue }
                        let lower = url.absoluteString.lowercased()
                        let hlsScore = lower.contains("m3u8") || protocolName.localizedCaseInsensitiveContains("hls") ? 100 : 0
                        let formatScore = formatName.localizedCaseInsensitiveContains("fmp4") ? 20 : 0
                        candidates.append((url: url, quality: currentQuality,
                                           score: hlsScore + formatScore))
                    }
                }
            }
        }

        guard let candidate = candidates.sorted(by: { $0.score > $1.score }).first else {
            throw APIError.unavailable
        }
        if qualityCodes.isEmpty { qualityCodes.insert(candidate.quality) }
        let qualities = qualityCodes.sorted(by: >).map { code in
            LiveQuality(code: code, title: qualityNames[code] ?? Self.liveQualityTitle(code))
        }
        return LivePlayback(url: candidate.url,
                            quality: candidate.quality,
                            qualities: qualities)
    }

    private func livePlaybackLegacy(roomID: Int, quality: Int?, cookie: String?) async throws -> LivePlayback {
        var components = URLComponents(string: "https://api.live.bilibili.com/room/v1/Room/playUrl")!
        components.queryItems = [
            URLQueryItem(name: "cid", value: "\(roomID)"),
            URLQueryItem(name: "platform", value: "h5"),
            URLQueryItem(name: "qn", value: "\(quality ?? 0)"),
            URLQueryItem(name: "quality", value: "4"),
            URLQueryItem(name: "https_url_req", value: "1")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://live.bilibili.com/\(roomID)")
        guard let data = root["data"] as? [String: Any],
              let rows = data["durl"] as? [[String: Any]] else {
            throw APIError.invalidResponse
        }
        let qualityRows = data["quality_description"] as? [[String: Any]] ?? []
        let qualities = qualityRows.compactMap { row -> LiveQuality? in
            guard let code = Self.integer(row["qn"] ?? row["quality"]), code > 0 else { return nil }
            return LiveQuality(code: code,
                               title: Self.text(row["desc"] ?? row["description"]) ?? Self.liveQualityTitle(code))
        }.sorted { $0.code > $1.code }
        for row in rows {
            for key in ["url", "base_url", "baseUrl"] {
                if let value = Self.text(row[key]), let url = URL(string: value) {
                    let actual = Self.integer(data["current_qn"])
                        ?? Self.queryInteger(url, name: "qn")
                        ?? Self.integer(data["quality"])
                        ?? quality ?? qualities.first?.code ?? 80
                    let available = qualities.isEmpty
                        ? [LiveQuality(code: actual, title: Self.liveQualityTitle(actual))]
                        : qualities
                    return LivePlayback(url: url, quality: actual, qualities: available)
                }
            }
        }
        throw APIError.unavailable
    }

    func rankedVideos(categoryID: Int, cookie: String? = nil) async throws -> [Video] {
        if categoryID == 0 { return try await popularVideos(cookie: cookie) }
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/ranking/v2")!
        components.queryItems = [
            URLQueryItem(name: "rid", value: "\(categoryID)"),
            URLQueryItem(name: "type", value: "all")
        ]
        let root = try await requestObject(components.url!, cookie: cookie)
        let data = root["data"] as? [String: Any]
        let rows = data?["list"] as? [[String: Any]] ?? []
        return rows.compactMap(Self.video)
    }

    func searchVideos(keyword: String, page: Int = 1, cookie: String? = nil) async throws -> SearchPage {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/search/type")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "search_type", value: "video"),
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "order", value: "totalrank"),
            URLQueryItem(name: "highlight", value: "0")
        ]
        let root = try await requestObject(components.url!, cookie: cookie, referer: "https://search.bilibili.com/")
        let data = root["data"] as? [String: Any]
        let rows = data?["result"] as? [[String: Any]] ?? []
        return SearchPage(
            videos: rows.compactMap(Self.video),
            users: [],
            collections: [],
            total: Self.integer(data?["numResults"]) ?? rows.count
        )
    }

    func searchUsers(keyword: String, page: Int = 1, cookie: String? = nil) async throws -> [User] {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/search/type")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "search_type", value: "bili_user"),
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "order", value: "fans")
        ]
        let root = try await requestObject(components.url!, cookie: cookie, referer: "https://search.bilibili.com/")
        let data = root["data"] as? [String: Any]
        let rows = data?["result"] as? [[String: Any]] ?? []
        return rows.compactMap(Self.user)
    }

    func searchCollections(keyword: String, page: Int = 1, cookie: String? = nil) async throws -> [Collection] {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/search/type")!
        components.queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "search_type", value: "media_bangumi"),
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "order", value: "totalrank")
        ]
        let root = try await requestObject(components.url!, cookie: cookie, referer: "https://search.bilibili.com/")
        let data = root["data"] as? [String: Any]
        let rows = data?["result"] as? [[String: Any]] ?? []
        return rows.compactMap(Self.collection)
    }

    /// Loads the video detail and then asks x/player/v2 for subtitle tracks.
    /// The latter is important: AI-generated and translated tracks are
    /// exposed there even when x/web-interface/view has no subtitle list.
    func videoDetail(bvid: String, cookie: String? = nil) async throws -> Video {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/view")!
        components.queryItems = [URLQueryItem(name: "bvid", value: bvid)]
        let root = try await requestObject(components.url!, cookie: cookie)
        guard let data = root["data"] as? [String: Any],
              let base = Self.video(data) else {
            throw APIError.invalidResponse
        }
        guard let cid = base.cid else { return base }
        let tracks = (try? await subtitleTracks(
            bvid: base.bvid,
            aid: base.aid,
            cid: cid,
            cookie: cookie
        )) ?? base.subtitles
        return base.replacingSubtitles(Self.uniqueSubtitles(tracks))
    }

    func comments(aid: Int, page: Int = 1, sort: CommentSort = .hot,
                  cookie: String? = nil) async throws -> CommentPage {
        var components = URLComponents(string: "https://api.bilibili.com/x/v2/reply")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "oid", value: "\(aid)"),
            URLQueryItem(name: "mode", value: sort == .hot ? "3" : "2"),
            URLQueryItem(name: "next", value: "\(max(1, page))"),
            URLQueryItem(name: "ps", value: "20")
        ]
        let root = try await requestObject(components.url!, cookie: cookie)
        let data = root["data"] as? [String: Any]
        let rows = data?["replies"] as? [[String: Any]] ?? []
        let comments = rows.compactMap(Self.comment)
        let cursor = data?["cursor"] as? [String: Any]
        let isEnd = Self.bool(cursor?["is_end"]) ?? (comments.count < 20)
        return CommentPage(
            comments: comments,
            total: Self.integer(data?["upper"]) ?? comments.count,
            hasMore: !isEnd
        )
    }

    /// Returns one progressive stream plus the qualities actually accepted
    /// by the current account/video.  The UI never invents an unavailable
    /// resolution.
    func playback(for video: Video, quality: Int? = nil, cookie: String? = nil) async throws -> Playback {
        guard let cid = video.cid else { throw APIError.invalidResponse }
        let requestedQuality = quality ?? 80
        var components = URLComponents(string: "https://api.bilibili.com/x/player/playurl")!
        components.queryItems = [
            URLQueryItem(name: "bvid", value: video.bvid),
            URLQueryItem(name: "cid", value: "\(cid)"),
            URLQueryItem(name: "qn", value: "\(requestedQuality)"),
            URLQueryItem(name: "fnval", value: "0"),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "fourk", value: "1")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://www.bilibili.com/video/\(video.bvid)")
        guard let data = root["data"] as? [String: Any] else { throw APIError.invalidResponse }
        let actualQuality = Self.integer(data["quality"]) ?? requestedQuality
        var available = Self.qualities(data)
        if available.isEmpty {
            available = [VideoQuality(code: actualQuality, title: "\(actualQuality)p")]
        } else if !available.contains(where: { $0.code == actualQuality }) {
            available.append(VideoQuality(code: actualQuality, title: "\(actualQuality)p"))
            available.sort { $0.code > $1.code }
        }

        if let rows = data["durl"] as? [[String: Any]] {
            for row in rows {
                for key in ["url", "baseUrl", "base_url"] {
                    if let value = Self.text(row[key]), let url = URL(string: value) {
                        return Playback(url: url, quality: actualQuality, qualities: available)
                    }
                }
            }
        }
        if let dash = data["dash"] as? [String: Any],
           let rows = dash["video"] as? [[String: Any]] {
            for row in rows {
                for key in ["baseUrl", "base_url", "url"] {
                    if let value = Self.text(row[key]), let url = URL(string: value) {
                        return Playback(url: url, quality: actualQuality, qualities: available)
                    }
                }
            }
        }
        throw APIError.unavailable
    }

    func playableURL(for video: Video, cookie: String? = nil) async throws -> URL {
        try await playback(for: video, cookie: cookie).url
    }

    /// Returns the audio representations advertised by Bilibili's DASH
    /// response.  This is kept separate from the video playback request so
    /// the download UI can offer only qualities that really exist for the
    /// selected video.
    func audioQualities(for video: Video, cookie: String? = nil) async throws -> [BilibiliAudioQuality] {
        let candidates = try await audioCandidates(for: video, quality: nil, cookie: cookie)
        return candidates.map(\.quality)
    }

    /// Resolves a fresh, signed DASH audio URL immediately before a download.
    /// Bilibili media URLs expire, so callers should not cache this URL.
    func audioPlayback(for video: Video, quality: Int? = nil,
                       cookie: String? = nil) async throws -> AudioPlayback {
        let candidates = try await audioCandidates(for: video, quality: quality, cookie: cookie)
        let selected = quality.flatMap { requested in
            candidates.first(where: { $0.quality.code == requested })
        } ?? candidates.first
        guard let selected else {
            throw APIError.unavailable
        }
        return AudioPlayback(
            url: selected.url,
            quality: selected.quality,
            qualities: candidates.map(\.quality)
        )
    }

    private struct AudioCandidate: Sendable {
        let url: URL
        let quality: BilibiliAudioQuality
    }

    private func audioCandidates(for video: Video, quality: Int?, cookie: String?) async throws -> [AudioCandidate] {
        guard let cid = video.cid else { throw APIError.invalidResponse }
        var components = URLComponents(string: "https://api.bilibili.com/x/player/playurl")!
        components.queryItems = [
            URLQueryItem(name: "bvid", value: video.bvid),
            URLQueryItem(name: "cid", value: "\(cid)"),
            URLQueryItem(name: "qn", value: "\(quality ?? 80)"),
            URLQueryItem(name: "fnval", value: "16"),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "fourk", value: "1")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://www.bilibili.com/video/\(video.bvid)")
        guard let data = root["data"] as? [String: Any],
              let dash = data["dash"] as? [String: Any],
              let rows = dash["audio"] as? [[String: Any]],
              !rows.isEmpty else {
            throw APIError.unavailable
        }

        var candidates: [AudioCandidate] = []
        var seen = Set<Int>()
        for (index, row) in rows.enumerated() {
            let bitrate = Self.integer(row["bandwidth"] ?? row["bandwidth_kbps"])
            let fallbackCode = bitrate.map { max(1, $0) } ?? (index + 1)
            let code = Self.integer(row["id"] ?? row["quality"] ?? row["code"]) ?? fallbackCode
            guard seen.insert(code).inserted else { continue }

            let rawURL = Self.text(row["baseUrl"] ?? row["base_url"] ?? row["url"])
                ?? (row["backupUrl"] as? [Any])?.compactMap { Self.text($0) }.first
            guard let rawURL, let url = URL(string: rawURL) else { continue }

            let title: String
            if let bitrate, bitrate > 0 {
                title = "\(max(1, Int((Double(bitrate) / 1000.0).rounded()))) kbps"
            } else {
                title = "音频 \(code)"
            }
            candidates.append(AudioCandidate(
                url: url,
                quality: BilibiliAudioQuality(code: code, title: title, bitrate: bitrate)
            ))
        }

        guard !candidates.isEmpty else { throw APIError.unavailable }
        return candidates.sorted {
            ($0.quality.bitrate ?? 0, $0.quality.code) > ($1.quality.bitrate ?? 0, $1.quality.code)
        }
    }

    /// Reads all subtitle tracks from x/player/v2.  This includes normal,
    /// translated, and AI-generated captions when Bilibili exposes them.
    func subtitleTracks(bvid: String, aid: Int, cid: Int,
                        cookie: String? = nil) async throws -> [Subtitle] {
        var components = URLComponents(string: "https://api.bilibili.com/x/player/v2")!
        components.queryItems = [
            URLQueryItem(name: "bvid", value: bvid),
            URLQueryItem(name: "aid", value: "\(aid)"),
            URLQueryItem(name: "cid", value: "\(cid)")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://www.bilibili.com/video/\(bvid)")
        let data = root["data"] as? [String: Any]
        let subtitleData = data?["subtitle"] as? [String: Any]
        let rows = (subtitleData?["list"] as? [[String: Any]])
            ?? (data?["subtitle"] as? [[String: Any]])
            ?? []
        return rows.compactMap(Self.subtitle)
    }

    func subtitleCues(for subtitle: Subtitle, cookie: String? = nil) async throws -> [SubtitleCue] {
        await ensureVisitorCookies()
        var request = URLRequest(url: subtitle.url)
        applyHeaders(to: &request, referer: "https://www.bilibili.com/")
        let cookies = mergedRequestCookieHeader(cookie)
        if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response) else { throw APIError.requestFailed }
        let object = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let root = object as? [String: Any] {
            rows = (root["body"] as? [[String: Any]]) ?? []
        } else {
            rows = object as? [[String: Any]] ?? []
        }
        let cues = rows.compactMap(Self.subtitleCue)
            .sorted { $0.start < $1.start }
        guard !cues.isEmpty else { throw APIError.invalidResponse }
        return cues
    }

    private func requestObject(_ url: URL, cookie: String? = nil,
                               referer: String = "https://www.bilibili.com/") async throws -> [String: Any] {
        await ensureVisitorCookies()
        var request = URLRequest(url: url)
        applyHeaders(to: &request, referer: referer)
        if let cookies = mergedRequestCookieHeader(cookie), !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response), let root = Self.object(data) else {
            throw APIError.requestFailed
        }
        guard Self.integer(root["code"]) == 0 else { throw APIError.unavailable }
        return root
    }

    private func applyHeaders(to request: inout URLRequest, referer: String) {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let origin = referer.contains("live.bilibili.com")
            ? "https://live.bilibili.com"
            : "https://www.bilibili.com"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    }

    private static func liveRoomRows(_ value: Any?) -> [[String: Any]] {
        if let rows = value as? [[String: Any]] { return rows }
        guard let payload = value as? [String: Any] else { return [] }
        if let rows = payload["list"] as? [[String: Any]] { return rows }
        if let rows = payload["result"] as? [[String: Any]] { return rows }
        if let rows = payload["rooms"] as? [[String: Any]] { return rows }
        if let room = payload["live_room"] as? [String: Any] { return [room] }
        return []
    }

    private static func liveRoom(_ raw: [String: Any]) -> LiveRoom? {
        let roomID = integer(raw["roomid"] ?? raw["room_id"] ?? raw["roomId"]) ?? 0
        guard roomID > 0 else { return nil }
        let anchor = raw["anchor_info"] as? [String: Any]
        let baseInfo = anchor?["base_info"] as? [String: Any]
        let watchedShow = raw["watched_show"] as? [String: Any]
        let title = stripHTML(text(raw["title"]) ?? "B 站直播间")
        let userName = stripHTML(text(raw["uname"] ?? raw["user_name"]
                                      ?? baseInfo?["uname"]) ?? "B 站主播")
        let cover = imageURL(text(raw["user_cover"] ?? raw["cover_from_user"]
                                  ?? raw["keyframe"] ?? raw["cover"]))
        let avatar = imageURL(text(raw["face"] ?? raw["uface"] ?? baseInfo?["face"]))
        return LiveRoom(
            roomID: roomID,
            uid: integer(raw["uid"] ?? raw["mid"] ?? baseInfo?["uid"]) ?? 0,
            title: title.isEmpty ? "B 站直播间" : title,
            coverURL: cover,
            userName: userName,
            userAvatarURL: avatar,
            areaName: stripHTML(text(raw["area_name"] ?? raw["areaName"] ?? raw["cate_name"]) ?? ""),
            parentAreaName: stripHTML(text(raw["parent_area_name"] ?? raw["parentAreaName"]) ?? ""),
            online: integer(raw["online"] ?? raw["online_num"] ?? watchedShow?["num"]) ?? 0,
            liveStatus: integer(raw["live_status"] ?? raw["liveStatus"]) ?? 1,
            isPortrait: bool(raw["is_portrait"] ?? raw["isPortrait"]) ?? false
        )
    }

    private static func uniqueLiveRooms(_ rooms: [LiveRoom]) -> [LiveRoom] {
        var seen = Set<Int>()
        return rooms.filter { seen.insert($0.roomID).inserted }
    }

    private static func integers(_ value: Any?) -> [Int] {
        if let values = value as? [Any] {
            return values.compactMap(integer)
        }
        if let value = value as? String {
            return value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        return []
    }

    private static func liveQualityTitle(_ code: Int) -> String {
        switch code {
        case 80: return "流畅"
        case 150: return "高清"
        case 250: return "超清"
        case 400: return "蓝光"
        case 800: return "超高清"
        case 10000: return "原画"
        case 20000: return "4K"
        case 25000: return "杜比"
        case 30000: return "真 4K"
        default: return "(code)"
        }
    }

    private static func video(_ raw: [String: Any]) -> Video? {
        let bvid = text(raw["bvid"]) ?? ""
        guard !bvid.isEmpty else { return nil }
        let owner = raw["owner"] as? [String: Any]
        let stat = raw["stat"] as? [String: Any]
        let firstPage = (raw["pages"] as? [[String: Any]])?.first
        let durationText = text(raw["duration"] ?? firstPage?["duration"]) ?? ""
        let subtitleRows = ((raw["subtitle"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        return Video(
            bvid: bvid,
            aid: integer(raw["aid"] ?? raw["id"]) ?? 0,
            cid: integer(raw["cid"] ?? firstPage?["cid"]),
            title: stripHTML(text(raw["title"]) ?? ""),
            coverURL: imageURL(text(raw["pic"])),
            author: stripHTML(text(raw["author"]) ?? text(owner?["name"]) ?? ""),
            authorID: integer(raw["mid"] ?? owner?["mid"]) ?? 0,
            authorAvatarURL: imageURL(text(raw["face"]) ?? text(owner?["face"])),
            description: stripHTML(text(raw["description"]) ?? text(raw["desc"]) ?? ""),
            duration: parseDuration(durationText),
            durationText: durationText,
            playCount: integer(raw["play"] ?? stat?["view"]) ?? 0,
            commentCount: integer(raw["review"] ?? stat?["reply"]) ?? 0,
            publishedAt: integer(raw["pubdate"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            subtitles: subtitleRows.compactMap(Self.subtitle)
        )
    }

    private static func subtitle(_ raw: [String: Any]) -> Subtitle? {
        guard let rawURL = text(raw["subtitle_url"]), !rawURL.isEmpty else { return nil }
        let normalizedURL: String
        if rawURL.hasPrefix("//") {
            normalizedURL = "https:" + rawURL
        } else if rawURL.hasPrefix("http://") {
            normalizedURL = "https://" + rawURL.dropFirst(7)
        } else if rawURL.hasPrefix("/") {
            normalizedURL = "https://www.bilibili.com" + rawURL
        } else {
            normalizedURL = rawURL
        }
        guard let url = URL(string: normalizedURL) else { return nil }

        let language = text(raw["lan"]) ?? ""
        let rawTitle = text(raw["lan_doc"] ?? raw["lan_doc_short"])
            ?? (language.isEmpty ? "字幕" : language)
        let type = integer(raw["type"]) ?? 0
        let aiStatus = integer(raw["ai_status"]) ?? 0
        let aiType = integer(raw["ai_type"]) ?? 0
        let aiGenerated = aiStatus > 0 || aiType > 0 || type == 1
        let translated = type == 2 || rawTitle.localizedCaseInsensitiveContains("translate")
            || rawTitle.contains("翻译") || rawTitle.contains("译")
        let format = normalizedURL.localizedCaseInsensitiveContains(".bcc") ? "bcc" : "json"
        return Subtitle(
            id: text(raw["id"]) ?? normalizedURL,
            language: language,
            title: rawTitle,
            url: url,
            isAIGenerated: aiGenerated,
            isTranslated: translated,
            format: format
        )
    }

    private static func subtitleCue(_ row: [String: Any]) -> SubtitleCue? {
        guard let start = double(row["from"] ?? row["start"]),
              let end = double(row["to"] ?? row["end"]) else { return nil }
        let textValue: String
        if let value = text(row["content"]) {
            textValue = value
        } else if let values = row["content"] as? [String] {
            textValue = values.joined()
        } else {
            return nil
        }
        let clean = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, end >= start else { return nil }
        return SubtitleCue(
            id: "\(start)-\(end)-\(clean)",
            start: start,
            end: end,
            text: clean
        )
    }

    private static func qualities(_ data: [String: Any]) -> [VideoQuality] {
        let formats = (data["support_formats"] as? [[String: Any]] ?? []).compactMap { raw -> VideoQuality? in
            guard let code = integer(raw["quality"] ?? raw["qn"]), code > 0 else { return nil }
            let title = text(raw["new_description"] ?? raw["display_desc"] ?? raw["description"])
                ?? "\(code)p"
            return VideoQuality(code: code, title: title)
        }
        if !formats.isEmpty {
            return Array(Dictionary(grouping: formats, by: \.code).values.compactMap(\.first))
                .sorted { $0.code > $1.code }
        }

        let codes = data["accept_quality"] as? [Any] ?? []
        let descriptions = data["accept_description"] as? [Any] ?? []
        return codes.enumerated().compactMap { index, value in
            guard let code = integer(value), code > 0 else { return nil }
            let title = index < descriptions.count ? (text(descriptions[index]) ?? "\(code)p") : "\(code)p"
            return VideoQuality(code: code, title: title)
        }
        .sorted { $0.code > $1.code }
    }

    private static func uniqueSubtitles(_ subtitles: [Subtitle]) -> [Subtitle] {
        var seen = Set<String>()
        return subtitles.filter { seen.insert($0.id).inserted }
    }

    private static func user(_ raw: [String: Any]) -> User? {
        guard let mid = integer(raw["mid"]), mid > 0 else { return nil }
        return User(
            mid: mid,
            name: stripHTML(text(raw["uname"] ?? raw["author"]) ?? "B 站用户"),
            avatarURL: imageURL(text(raw["upic"] ?? raw["face"])),
            signature: stripHTML(text(raw["usign"] ?? raw["sign"]) ?? ""),
            followerCount: integer(raw["fans"] ?? raw["fans_num"]) ?? 0
        )
    }

    private static func collection(_ raw: [String: Any]) -> Collection? {
        let id = text(raw["season_id"] ?? raw["media_id"] ?? raw["id"]) ?? ""
        let title = stripHTML(text(raw["title"] ?? raw["season_title"]) ?? "")
        guard !id.isEmpty, !title.isEmpty else { return nil }
        return Collection(
            id: id,
            title: title,
            coverURL: imageURL(text(raw["cover"] ?? raw["pic"])),
            subtitle: stripHTML(text(raw["desc"] ?? raw["description"] ?? raw["author"]) ?? ""),
            itemCount: integer(raw["eps"] ?? raw["episode_count"] ?? raw["total_count"]) ?? 0
        )
    }

    private static func comment(_ raw: [String: Any]) -> Comment? {
        let member = raw["member"] as? [String: Any]
        let content = raw["content"] as? [String: Any]
        let id = text(raw["rpid"] ?? raw["rpid_str"] ?? raw["id"]) ?? UUID().uuidString
        let message = stripHTML(text(content?["message"]) ?? "")
        guard !message.isEmpty else { return nil }
        return Comment(
            id: id,
            author: text(member?["uname"]) ?? "B 站用户",
            avatarURL: imageURL(text(member?["avatar"])),
            message: message,
            likeCount: integer(raw["like"]) ?? 0,
            publishedAt: integer(raw["ctime"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            replyCount: integer(raw["rcount"]) ?? 0
        )
    }

    private func cookieHeader() -> String {
        let cookies = cookieStorage.cookies?.filter { sessionCookieNames.contains($0.name) } ?? []
        return cookies.sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func cookieHeader(fromLoginURL rawURL: String?) -> String {
        let allowed = ["DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct", "sid"]
        var values: [String: String] = [:]
        guard let rawURL, !rawURL.isEmpty else { return "" }

        if let components = URLComponents(string: rawURL) {
            for item in components.queryItems ?? [] where allowed.contains(item.name) {
                if let value = item.value, !value.isEmpty { values[item.name] = value }
            }
        }

        var decodedURL = rawURL
        for _ in 0..<2 {
            guard let decoded = decodedURL.removingPercentEncoding, decoded != decodedURL else { break }
            decodedURL = decoded
        }
        let query = decodedURL.split(separator: "?", maxSplits: 1).dropFirst().first ?? ""
        for item in query.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let name = pair[0].removingPercentEncoding ?? pair[0]
            let value = pair[1].removingPercentEncoding ?? pair[1]
            if allowed.contains(name), !value.isEmpty { values[name] = value }
        }
        return values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func mergedCookieHeaders(_ first: String, _ second: String) -> String {
        var values: [String: String] = [:]
        for header in [first, second] {
            for item in header.split(separator: ";") {
                let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                values[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1]
            }
        }
        return values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    private func ensureVisitorCookies() async {
        guard !visitorBootstrapAttempted else { return }
        visitorBootstrapAttempted = true
        guard !hasVisitorCookies else { return }
        guard let endpoint = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") else { return }
        var request = URLRequest(url: endpoint)
        applyHeaders(to: &request, referer: "https://www.bilibili.com/")
        guard let (data, response) = try? await session.data(for: request),
              Self.isSuccess(response),
              let root = Self.object(data),
              Self.integer(root["code"]) == 0,
              let payload = root["data"] as? [String: Any] else { return }

        if let buvid3 = Self.text(payload["b_3"]) { storeVisitorCookie(name: "buvid3", value: buvid3) }
        if let buvid4 = Self.text(payload["b_4"]) { storeVisitorCookie(name: "buvid4", value: buvid4) }
    }

    private var hasVisitorCookies: Bool {
        (cookieStorage.cookies ?? []).contains { visitorCookieNames.contains($0.name) }
    }

    private func storeVisitorCookie(name: String, value: String) {
        guard let cookie = HTTPCookie(properties: [
            .domain: ".bilibili.com",
            .path: "/",
            .name: name,
            .value: value,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(365 * 24 * 60 * 60)
        ]) else { return }
        cookieStorage.setCookie(cookie)
    }

    private func mergedRequestCookieHeader(_ accountCookie: String?) -> String {
        let visitorCookies = (cookieStorage.cookies ?? [])
            .filter { visitorCookieNames.contains($0.name) }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        return Self.mergedCookieHeaders(visitorCookies, accountCookie ?? "")
    }

    private static func isSuccess(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func text(_ value: Any?) -> String? {
        if let value = value as? String { return value.isEmpty ? nil : value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func queryInteger(_ url: URL, name: String) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == name })?.value.flatMap { Int($0) }
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func imageURL(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("//") { return "https:" + value }
        return value.hasPrefix("http://") ? "https://" + value.dropFirst(7) : value
    }

    private static func parseDuration(_ value: String) -> TimeInterval {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return 0 }
        return parts.reversed().enumerated().reduce(0) { result, item in
            result + item.element * pow(60, Double(item.offset))
        }
    }

    private static func stripHTML(_ value: String) -> String {
        var output = value
        if let expression = try? NSRegularExpression(pattern: "<[^>]+>") {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = expression.stringByReplacingMatches(in: output, range: range, withTemplate: "")
        }
        return output
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
