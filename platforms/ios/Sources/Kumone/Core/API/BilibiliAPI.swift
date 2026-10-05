import CryptoKit
import Foundation
import VideoToolbox
import CoreMedia

/// Bilibili public-content and account client.
///
/// The player consumes the same public playurl/subtitle data used by
/// PiliPlus.  Account cookies are only passed in-process and are never
/// returned by this API to a web page.
private final class BilibiliDanmakuXMLParser: NSObject, XMLParserDelegate {
    struct Item {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let color: UInt32
        let mode: Int
    }

    private(set) var items: [Item] = []
    private var current: Item?
    private var currentText = ""

    func parse(_ data: Data) throws -> [Item] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { throw BilibiliAPI.APIError.invalidResponse }
        return items
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        guard elementName == "d", let raw = attributeDict["p"] else { return }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Double(parts.first ?? "") else { return }
        let mode = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        let color = parts.count > 3 ? UInt32(String(parts[3]), radix: 16) ?? 0xFFFFFF : 0xFFFFFF
        current = Item(start: start, end: start + 6, text: "", color: color, mode: mode)
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard current != nil else { return }
        currentText.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "d", var item = current else { return }
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            item = Item(start: item.start, end: item.end, text: text,
                        color: item.color, mode: item.mode)
            items.append(item)
        }
        current = nil
        currentText = ""
    }
}
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
        let isVIP: Bool
        let vipType: Int
        let vipDueDate: Date?
        let membershipLabel: String?

        var membershipTitle: String? {
            guard isVIP else { return nil }
            if let membershipLabel, !membershipLabel.isEmpty {
                return membershipLabel
            }
            return vipType >= 2 ? "\u{5927}\u{4F1A}\u{5458}" : "\u{666E}\u{901A}\u{4F1A}\u{5458}"
        }
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
        /// Display size after rotation; 0 when the API did not report it.
        var videoWidth: Int = 0
        var videoHeight: Int = 0
        /// Parts (分P) of a multi-part video; empty for the usual single-part upload.
        var pages: [VideoPage] = []

        var id: String { bvid }

        /// width / height of the picture, 16:9 when unknown.
        var displayAspectRatio: CGFloat {
            guard videoWidth > 0, videoHeight > 0 else { return 16.0 / 9.0 }
            return CGFloat(videoWidth) / CGFloat(videoHeight)
        }

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
                subtitles: subtitles,
                videoWidth: videoWidth,
                videoHeight: videoHeight,
                pages: pages
            )
        }

        /// The same video pointed at another part: new cid, its own length, no (first-part) subtitles.
        func withPage(_ page: VideoPage) -> Video {
            Video(
                bvid: bvid,
                aid: aid,
                cid: page.cid,
                title: title,
                coverURL: coverURL,
                author: author,
                authorID: authorID,
                authorAvatarURL: authorAvatarURL,
                description: description,
                duration: page.duration > 0 ? page.duration : duration,
                durationText: durationText,
                playCount: playCount,
                commentCount: commentCount,
                publishedAt: publishedAt,
                subtitles: [],
                videoWidth: videoWidth,
                videoHeight: videoHeight,
                pages: pages
            )
        }
    }

    struct VideoPage: Identifiable, Hashable, Sendable {
        let cid: Int
        let page: Int
        let part: String
        let duration: TimeInterval

        var id: Int { cid }
        var title: String { part.isEmpty ? "P\(page)" : "P\(page) \(part)" }
    }

    struct VideoQuality: Identifiable, Hashable, Sendable {
        let code: Int
        let title: String
        let requiresLogin: Bool
        let requiresVIP: Bool
        let isHDR: Bool
        let isDolby: Bool

        init(code: Int, title: String, requiresLogin: Bool = false,
             requiresVIP: Bool = false, isHDR: Bool = false, isDolby: Bool = false) {
            self.code = code
            self.title = title
            self.requiresLogin = requiresLogin
            self.requiresVIP = requiresVIP
            self.isHDR = isHDR
            self.isDolby = isDolby
        }

        var displayTitle: String {
            if requiresVIP { return "\(title) · 会员" }
            if requiresLogin { return "\(title) · 登录" }
            return title
        }

        var id: Int { code }
    }

    /// A DASH audio representation returned by Bilibili.  The title is
    /// derived from the response bitrate; it is never upgraded to a label
    /// such as lossless unless the service actually exposes that data.
    struct BilibiliAudioQuality: Identifiable, Hashable, Sendable {
        let code: Int
        let title: String
        let bitrate: Int?
        let requiresLogin: Bool
        let requiresVIP: Bool
        let isHiRes: Bool
        let isDolby: Bool

        init(code: Int, title: String, bitrate: Int?, requiresLogin: Bool = false,
             requiresVIP: Bool = false, isHiRes: Bool = false, isDolby: Bool = false) {
            self.code = code
            self.title = title
            self.bitrate = bitrate
            self.requiresLogin = requiresLogin
            self.requiresVIP = requiresVIP
            self.isHiRes = isHiRes
            self.isDolby = isDolby
        }

        var displayTitle: String {
            if requiresVIP { return "\(title) · 会员" }
            if requiresLogin { return "\(title) · 登录" }
            return title
        }

        var id: Int { code }
    }

    struct AudioPlayback: Sendable {
        let url: URL
        let quality: BilibiliAudioQuality
        let qualities: [BilibiliAudioQuality]
        /// The same track with its init / index ranges, for audio-only HLS (nil when Bilibili gives no index).
        var dash: BiliDashTrack? = nil
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
        /// Separate audio track when the stream is DASH (video-only `url`).
        var audioURL: URL? = nil
        /// Same quality in other codecs / backup CDNs, tried before lowering the quality.
        var alternateURLs: [URL] = []
        /// Index data for HLS playback (nil for muxed MP4 / unusual responses).
        var dash: BiliDashSource? = nil
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
        /// Uploader collections (合集 / 系列) carry the owner and open into a video list.
        var mid: Int = 0
        var isUGC: Bool = false
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
        var likeCount: Int
        let publishedAt: Date?
        var replyCount: Int
        var liked: Bool = false
        var previewReplies: [Comment] = []
    }

    struct CommentPage: Sendable {
        let comments: [Comment]
        let total: Int
        let hasMore: Bool
    }

    struct DanmakuCue: Identifiable, Hashable, Sendable {
        let id: String
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let color: UInt32
        let mode: Int
    }

    struct InteractionState: Sendable {
        let isLiked: Bool
        let coinCount: Int
        let isFavorited: Bool
    }

    struct DynamicItem: Identifiable, Hashable, Sendable {
        let id: String
        let author: String
        let avatarURL: String?
        let text: String
        let coverURL: String?
        let publishedAt: Date?
        let likeCount: Int
        let commentCount: Int
        let video: Video?
    }

    // Account surfaces used by the Beans 2.0-style “我的” page.  These are
    // deliberately separate from the music account stores: a B 站 session is
    // only used for B 站 public/account data and is never treated as a music
    // playback source.
    struct WatchHistoryItem: Identifiable, Hashable, Sendable {
        let historyID: String
        let bvid: String?
        let title: String
        let coverURL: String?
        let author: String
        let durationText: String
        let viewedAt: Date?
        let video: Video?

        var id: String { historyID }
    }

    struct FavoriteFolder: Identifiable, Hashable, Sendable {
        let id: Int
        let title: String
        let mediaCount: Int
        let coverURL: String?
    }

    struct PrivateMessageThread: Identifiable, Hashable, Sendable {
        let id: String
        let userID: Int
        let userName: String
        let avatarURL: String?
        let lastMessage: String
        let unreadCount: Int
        let updatedAt: Date?
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
    /// WBI mixin key for signed endpoints (search), refreshed hourly.
    private var wbiMixinKey: (key: String, fetchedAt: Date)?
    private var cidCache: [String: Int] = [:]
    private let cookieStorage: HTTPCookieStorage
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
    // The first search used to fail intermittently because the old boolean
    // marked the bootstrap as complete before the network request finished.
    // Keep the in-flight task instead: callers share one bootstrap request,
    // and a failed request can be retried on the next API call.
    private var visitorBootstrapTask: Task<Void, Never>?
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
        // No practical timeout limit for Bilibili requests.
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration)
    }

    // MARK: - TV (HD) QR login, the flow PiliPlus uses

    private static let tvAppKey = "dfca71928277209b"
    private static let tvAppSec = "b5475a8825547a4fc26c7d518eaaa02e"
    private static let tvUserAgent =
        "Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android model/android_hd mobi_app/android_hd build/2001100 channel/master innerVer/2001100 osVer/15 network/2"

    private func tvPost(_ path: String, _ params: [String: String]) async throws -> [String: Any] {
        var all = params
        all["appkey"] = Self.tvAppKey
        all["ts"] = String(Int(Date().timeIntervalSince1970))
        let query = all.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
        let sign = Insecure.MD5.hash(data: Data((query + Self.tvAppSec).utf8))
            .map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: URL(string: "https://passport.bilibili.com\(path)?\(query)&sign=\(sign)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue(Self.tvUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = Self.object(data) else { throw APIError.invalidResponse }
        return root
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? value
    }

    func qrCode() async throws -> QRCodePayload {
        let root = try await tvPost("/x/passport-tv-login/qrcode/auth_code",
                                    ["local_id": "0", "platform": "android", "mobi_app": "android_hd"])
        guard Self.integer(root["code"]) == 0,
              let payload = root["data"] as? [String: Any],
              let url = Self.text(payload["url"]), let key = Self.text(payload["auth_code"]),
              !url.isEmpty, !key.isEmpty else {
            throw APIError.invalidResponse
        }
        return QRCodePayload(url: url, key: key)
    }

    func poll(key: String) async throws -> QRStatus {
        let root = try await tvPost("/x/passport-tv-login/qrcode/poll", ["auth_code": key, "local_id": "0"])
        let code = Self.integer(root["code"])
        switch code {
        case 86039:
            return .waiting
        case 86090:
            return .scanned
        case 86038:
            return .expired
        case 0:
            let payload = root["data"] as? [String: Any]
            let info = payload?["cookie_info"] as? [String: Any]
            let rows = info?["cookies"] as? [[String: Any]] ?? []
            let cookie = rows.compactMap { row -> String? in
                guard let name = Self.text(row["name"]), let value = Self.text(row["value"]) else { return nil }
                return "\(name)=\(value)"
            }.joined(separator: "; ")
                + ((((payload?["token_info"] as? [String: Any])?["access_token"]).flatMap(Self.text)
                    ?? Self.text(payload?["access_token"])).map { "; bili_access_key=\($0)" } ?? "")
            guard !cookie.isEmpty else {
                Task { @MainActor in
                    DiagnosticLogStore.shared.append(level: .error, category: "哔哩哔哩登录", message: "TV 登录成功但没有 cookie", detail: "keys=\((payload ?? [:]).keys.sorted().joined(separator: ","))")
                }
                throw APIError.unavailable
            }
            return .success(cookie: cookie)
        default:
            let seen = code.map(String.init) ?? "nil"
            let message = Self.text(root["message"]) ?? ""
            Task { @MainActor in
                DiagnosticLogStore.shared.append(level: .error, category: "哔哩哔哩登录", message: "扫码轮询返回未知状态", detail: "code=\(seen) \(message)")
            }
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
              let id = Self.text(payload["mid"]),
              let name = Self.text(payload["uname"]),
              !name.isEmpty else {
            throw APIError.unavailable
        }
        // `/nav` has returned Boolean, numeric, and string flags over time.
        // Some responses omit `isLogin` after a fresh QR scan while still
        // returning a real account id and name; accept that shape, but never
        // override an explicit false value.
        let loggedIn = Self.bool(payload["isLogin"]) ?? ((Int(id) ?? 0) > 0)
        guard loggedIn else { throw APIError.unavailable }
        let vip = payload["vip"] as? [String: Any]
        let vipType = Self.integer(vip?["type"] ?? vip?["vip_type"] ?? payload["vip_type"]) ?? 0
        let vipStatus = Self.integer(vip?["status"] ?? vip?["vip_status"] ?? payload["vip_status"]) ?? 0
        let dueDate = Self.dateFromMilliseconds(vip?["due_date"] ?? payload["vip_due_date"])
        let vipLabel = vip?["label"] as? [String: Any]
        let membershipLabel = Self.text(vipLabel?["text"] ?? vip?["label_text"])
        let isVIP = (vipStatus > 0 && vipType > 0) ||
            Self.bool(vip?["is_senior_member"] ?? payload["is_senior_member"]) == true ||
            Self.bool(vip?["is_annual_vip"] ?? payload["is_annual_vip"]) == true
        return Profile(
            id: id,
            name: name,
            avatarURL: Self.imageURL(Self.text(payload["face"])),
            isVIP: isVIP,
            vipType: vipType,
            vipDueDate: dueDate,
            membershipLabel: membershipLabel
        )
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

    /// Loads Bilibili's two public recommendation feeds. The app feed mirrors
    /// the endpoint used by PiliPlus; it is still requested directly from
    /// Bilibili and uses the same optional in-process Cookie as the web feed.
    func recommendedVideos(source: BilibiliRecommendationSource,
                           page: Int = 1,
                           cookie: String? = nil) async throws -> [Video] {
        switch source {
        case .web:
            return try await webRecommendedVideos(page: page, cookie: cookie)
        case .app:
            return try await appRecommendedVideos(page: page, cookie: cookie)
        }
    }

    private func webRecommendedVideos(page: Int,
                                      cookie: String?) async throws -> [Video] {
        var components = URLComponents(
            string: "https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd"
        )!
        let page = max(1, page)
        components.queryItems = [
            URLQueryItem(name: "fresh_type", value: "4"),
            URLQueryItem(name: "ps", value: "20"),
            URLQueryItem(name: "fresh_idx", value: "\(page)"),
            URLQueryItem(name: "fresh_idx_1h", value: "\(page)"),
            URLQueryItem(name: "brush", value: "\(page)"),
            URLQueryItem(name: "fetch_row", value: "\(max(1, (page - 1) * 20 + 1))"),
            URLQueryItem(name: "web_location", value: "1430654"),
            URLQueryItem(name: "feed_version", value: "V8"),
            URLQueryItem(name: "homepage_ver", value: "1"),
            URLQueryItem(name: "version", value: "1")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://www.bilibili.com/")
        let data = root["data"] as? [String: Any]
        let rows = (data?["item"] as? [[String: Any]]) ?? []
        return rows.filter { Self.text($0["goto"]) == "av" }.compactMap(Self.video)
    }

    private func appRecommendedVideos(page: Int,
                                      cookie: String?) async throws -> [Video] {
        let index = max(0, page - 1)
        var components = URLComponents(string: "https://app.bilibili.com/x/v2/feed/index")!
        components.queryItems = [
            URLQueryItem(name: "build", value: "8430300"),
            URLQueryItem(name: "c_locale", value: "zh_CN"),
            URLQueryItem(name: "channel", value: "master"),
            URLQueryItem(name: "column", value: "2"),
            URLQueryItem(name: "device", value: "phone"),
            URLQueryItem(name: "device_name", value: "android"),
            URLQueryItem(name: "device_type", value: "0"),
            URLQueryItem(name: "disable_rcmd", value: "0"),
            URLQueryItem(name: "flush", value: "8"),
            URLQueryItem(name: "fnval", value: "976"),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "force_host", value: "2"),
            URLQueryItem(name: "fourk", value: "1"),
            URLQueryItem(name: "guidance", value: "1"),
            URLQueryItem(name: "https_url_req", value: "1"),
            URLQueryItem(name: "idx", value: "\(index)"),
            URLQueryItem(name: "mobi_app", value: "android_i"),
            URLQueryItem(name: "network", value: "wifi"),
            URLQueryItem(name: "platform", value: "android"),
            URLQueryItem(name: "player_net", value: "1"),
            URLQueryItem(name: "pull", value: index == 0 ? "true" : "false"),
            URLQueryItem(name: "qn", value: "32"),
            URLQueryItem(name: "recsys_mode", value: "0"),
            URLQueryItem(name: "s_locale", value: "zh_CN"),
            URLQueryItem(name: "splash_id", value: ""),
            URLQueryItem(name: "voice_balance", value: "0")
        ]
        // Personalised feed: the TV/HD login access_key, signed with the same app key.
        if let accessKey = cookie.flatMap({ Self.cookieValue("bili_access_key", from: $0) }), !accessKey.isEmpty {
            var items = (components.queryItems ?? []).filter { $0.name != "mobi_app" }
            items += [URLQueryItem(name: "access_key", value: accessKey),
                      URLQueryItem(name: "appkey", value: Self.tvAppKey),
                      URLQueryItem(name: "mobi_app", value: "android_hd"),
                      URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970)))]
            let query = items.sorted { $0.name < $1.name }
                .map { "\($0.name)=\(Self.formEncode($0.value ?? ""))" }.joined(separator: "&")
            let sign = Insecure.MD5.hash(data: Data((query + Self.tvAppSec).utf8)).map { String(format: "%02x", $0) }.joined()
            components.percentEncodedQuery = query + "&sign=\(sign)"
        }
        let headers = [
            "app-key": "android_hd",
            "env": "prod",
            // A fixed session / fingerprint made the server hand back the same batch on every pull.
            "session_id": String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased(),
            "fp_local": Self.deviceFingerprint(),
            "fp_remote": Self.deviceFingerprint(),
            "bili-http-engine": "cronet",
            "x-bili-trace-id": "Moumusic-\(UUID().uuidString)"
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://www.bilibili.com/",
                                           headers: headers)
        let data = root["data"] as? [String: Any]
        let rows = data?["items"] as? [[String: Any]] ?? []
        return rows.filter {
            let card = Self.text($0["card_goto"] ?? $0["goto"])
            return card == "av" && Self.text($0["ad_info"]) == nil
        }.compactMap(Self.appVideo)
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
        let root = try await searchObject([
            URLQueryItem(name: "keyword", value: cleaned),
            URLQueryItem(name: "search_type", value: "live_room"),
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "order", value: "online"),
            URLQueryItem(name: "highlight", value: "0")
        ], cookie: cookie)
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
                        let codecScore = (Self.text(codec["codec_name"]) ?? "").lowercased() == "avc" ? 30 : 0
                        candidates.append((url: url, quality: currentQuality,
                                           score: hlsScore + formatScore + codecScore))
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
        try await fuzzy(keyword, isEmpty: { $0.videos.isEmpty }) {
            try await self.searchVideosExact(keyword: $0, page: page, cookie: cookie)
        }
    }

    func searchUsers(keyword: String, page: Int = 1, cookie: String? = nil) async throws -> [User] {
        try await fuzzy(keyword, isEmpty: { $0.isEmpty }) {
            try await self.searchUsersExact(keyword: $0, page: page, cookie: cookie)
        }
    }

    func searchCollections(keyword: String, page: Int = 1, cookie: String? = nil) async throws -> [Collection] {
        try await fuzzy(keyword, isEmpty: { $0.isEmpty }) {
            try await self.searchCollectionsExact(keyword: $0, page: page, cookie: cookie)
        }
    }

    /// Approximate search: when the exact keyword finds nothing, retry without spaces and with the
    /// keyword Bilibili itself suggests for it (typos, half-remembered names), first hit wins.
    private func fuzzy<T>(_ keyword: String, isEmpty: (T) -> Bool,
                          _ run: (String) async throws -> T) async throws -> T {
        let first = try await run(keyword)
        guard isEmpty(first) else { return first }
        var tried: Set<String> = [keyword]
        let squeezed = keyword.filter { !$0.isWhitespace }
        let chars = Array(squeezed)
        // A wrong last letters is the usual slip: shorter prefixes of the keyword ("linksphotos" ->
        // "linksphoto" finds the uploader), then what Bilibili suggests for the keyword / its prefixes.
        let prefixes: [String] = (1...4).compactMap { cut in
            chars.count - cut >= max(2, chars.count / 2) ? String(chars.dropLast(cut)) : nil
        }
        var queue: [String] = []
        if squeezed != keyword { queue.append(squeezed) }
        queue += prefixes.prefix(2)
        queue += await suggestKeywords(keyword).prefix(2)
        if let shortest = prefixes.first { queue += await suggestKeywords(shortest).prefix(2) }
        queue += prefixes.dropFirst(2)
        for candidate in queue.prefix(10) where !candidate.isEmpty && tried.insert(candidate).inserted {
            if let result = try? await run(candidate), !isEmpty(result) { return result }
        }
        return first
    }

    /// Whether the signed-in account follows this uploader.
    func isFollowing(mid: Int, cookie: String?) async -> Bool {
        guard mid > 0, cookie != nil else { return false }
        var components = URLComponents(string: "https://api.bilibili.com/x/relation")!
        components.queryItems = [URLQueryItem(name: "fid", value: "\(mid)")]
        guard let root = try? await requestObject(components.url!, cookie: cookie,
                                                  referer: "https://space.bilibili.com/\(mid)"),
              let attribute = Self.integer((root["data"] as? [String: Any])?["attribute"]) else { return false }
        // 2 = following, 6 = mutual follow.
        return attribute == 2 || attribute == 6
    }

    func setFollow(mid: Int, follow: Bool, cookie: String?) async throws {
        guard mid > 0, let cookie, let csrf = Self.cookieValue("bili_jct", from: cookie), !csrf.isEmpty else {
            throw APIError.unavailable
        }
        _ = try await postFormObject(URL(string: "https://api.bilibili.com/x/relation/modify")!, fields: [
            "fid": "\(mid)", "act": follow ? "1" : "2", "re_src": "11", "csrf": csrf
        ], cookie: cookie, referer: "https://space.bilibili.com/\(mid)")
    }

    func suggestKeywords(_ keyword: String) async -> [String] {
        var components = URLComponents(string: "https://s.search.bilibili.com/main/suggest")!
        components.queryItems = [
            URLQueryItem(name: "term", value: keyword),
            URLQueryItem(name: "main_ver", value: "v1"),
            URLQueryItem(name: "highlight", value: "")
        ]
        guard let root = try? await requestObject(components.url!, referer: "https://search.bilibili.com/"),
              let tags = (root["result"] as? [String: Any])?["tag"] as? [[String: Any]] else { return [] }
        return tags.compactMap { Self.text($0["value"]) }.filter { !$0.isEmpty }
    }

    private func searchVideosExact(keyword: String, page: Int = 1, cookie: String? = nil) async throws -> SearchPage {
        let root = try await searchObject([
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "search_type", value: "video"),
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "order", value: "totalrank"),
            URLQueryItem(name: "highlight", value: "0")
        ], cookie: cookie)
        let data = root["data"] as? [String: Any]
        let rows = data?["result"] as? [[String: Any]] ?? []
        return SearchPage(
            videos: rows.compactMap(Self.video),
            users: [],
            collections: [],
            total: Self.integer(data?["numResults"]) ?? rows.count
        )
    }

    /// Videos uploaded by one user (WBI-free archive list).
    func userVideos(user: User, page: Int = 1, cookie: String? = nil) async throws -> [Video] {
        var components = URLComponents(string: "https://api.bilibili.com/x/series/recArchivesByKeywords")!
        components.queryItems = [
            URLQueryItem(name: "mid", value: "\(user.mid)"),
            URLQueryItem(name: "keywords", value: ""),
            URLQueryItem(name: "ps", value: "30"),
            URLQueryItem(name: "pn", value: "\(max(1, page))")
        ]
        let root = try await requestObject(components.url!, cookie: cookie, referer: "https://space.bilibili.com/\(user.mid)")
        let rows = ((root["data"] as? [String: Any])?["archives"] as? [[String: Any]]) ?? []
        return rows.compactMap { raw in
            var normalized = raw
            normalized["owner"] = ["name": user.name, "mid": user.mid, "face": user.avatarURL ?? ""]
            if normalized["pic"] == nil { normalized["pic"] = raw["cover"] }
            if normalized["pubdate"] == nil { normalized["pubdate"] = raw["ctime"] }
            return Self.video(normalized)
        }
    }

    private func searchUsersExact(keyword: String, page: Int = 1, cookie: String? = nil) async throws -> [User] {
        let root = try await searchObject([
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "search_type", value: "bili_user"),
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "order", value: "fans")
        ], cookie: cookie)
        let data = root["data"] as? [String: Any]
        let rows = data?["result"] as? [[String: Any]] ?? []
        return rows.compactMap(Self.user)
    }

    private func searchCollectionsExact(keyword: String, page: Int = 1, cookie: String? = nil) async throws -> [Collection] {
        // "Collections" are Bilibili's series catalogues: anime (bangumi) and film / TV (ft). Ask both and
        // merge; only fail when neither answers.
        let ugc = await ugcCollections(keyword: keyword, cookie: cookie)
        var merged: [Collection] = []
        var lastError: Error?
        var answered = false
        for type in ["media_bangumi", "media_ft"] {
            do {
                let root = try await searchObject([
                    URLQueryItem(name: "keyword", value: keyword),
                    URLQueryItem(name: "search_type", value: type),
                    URLQueryItem(name: "page", value: "\(max(1, page))"),
                    URLQueryItem(name: "order", value: "totalrank")
                ], cookie: cookie)
                answered = true
                let rows = (root["data"] as? [String: Any])?["result"] as? [[String: Any]] ?? []
                for item in rows.compactMap(Self.collection) where !merged.contains(where: { $0.id == item.id }) {
                    merged.append(item)
                }
            } catch {
                lastError = error
            }
        }
        if !answered, let lastError, ugc.isEmpty { throw lastError }
        return ugc + merged
    }

    // MARK: Uploader collections (合集 / 系列)

    /// Bilibili has no collection search endpoint. Mirror what the site does: find the matching
    /// uploaders, list their collections, keep the ones that match the keyword (or all of them when the
    /// keyword is the uploader's name).
    private func ugcCollections(keyword: String, cookie: String?) async -> [Collection] {
        let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty,
              let users = try? await searchUsersExact(keyword: keyword, page: 1, cookie: cookie) else { return [] }
        var result: [Collection] = []
        for user in users.prefix(3) {
            let name = user.name.lowercased()
            let isTheUploader = !name.isEmpty && (name.contains(needle) || needle.contains(name))
            let lists = await userCollections(user: user, cookie: cookie)
            let picked = isTheUploader
                ? Array(lists.prefix(12))
                : lists.filter { $0.title.lowercased().contains(needle) }
            for item in picked where !result.contains(where: { $0.id == item.id }) { result.append(item) }
        }
        return result
    }

    func userCollections(user: User, cookie: String?) async -> [Collection] {
        var components = URLComponents(string: "https://api.bilibili.com/x/polymer/web-space/seasons_series_list")!
        components.queryItems = [
            URLQueryItem(name: "mid", value: "\(user.mid)"),
            URLQueryItem(name: "page_num", value: "1"),
            URLQueryItem(name: "page_size", value: "30")
        ]
        guard let root = try? await requestObject(components.url!, cookie: cookie,
                                                  referer: "https://space.bilibili.com/\(user.mid)"),
              let lists = (root["data"] as? [String: Any])?["items_lists"] as? [String: Any] else { return [] }
        var result: [Collection] = []
        for (key, prefix, idKey) in [("seasons_list", "season", "season_id"), ("series_list", "series", "series_id")] {
            for row in (lists[key] as? [[String: Any]]) ?? [] {
                guard let meta = row["meta"] as? [String: Any],
                      let id = Self.integer(meta[idKey]), id > 0,
                      let name = Self.text(meta["name"]), !name.isEmpty else { continue }
                result.append(Collection(
                    id: "\(prefix)-\(id)",
                    title: name,
                    coverURL: Self.imageURL(Self.text(meta["cover"])),
                    subtitle: "\(user.name) · \(prefix == "season" ? "合集" : "系列")",
                    itemCount: Self.integer(meta["total"]) ?? 0,
                    mid: user.mid,
                    isUGC: true
                ))
            }
        }
        return result
    }

    func collectionVideos(_ collection: Collection, owner: String, cookie: String?) async throws -> [Video] {
        let parts = collection.id.split(separator: "-", maxSplits: 1).map(String.init)
        guard collection.isUGC, parts.count == 2, let id = Int(parts[1]) else { return [] }
        var components: URLComponents
        if parts[0] == "season" {
            components = URLComponents(string: "https://api.bilibili.com/x/polymer/web-space/seasons_archives_list")!
            components.queryItems = [
                URLQueryItem(name: "mid", value: "\(collection.mid)"),
                URLQueryItem(name: "season_id", value: "\(id)"),
                URLQueryItem(name: "sort_reverse", value: "false"),
                URLQueryItem(name: "page_num", value: "1"),
                URLQueryItem(name: "page_size", value: "100")
            ]
        } else {
            components = URLComponents(string: "https://api.bilibili.com/x/series/archives")!
            components.queryItems = [
                URLQueryItem(name: "mid", value: "\(collection.mid)"),
                URLQueryItem(name: "series_id", value: "\(id)"),
                URLQueryItem(name: "only_normal", value: "true"),
                URLQueryItem(name: "sort", value: "desc"),
                URLQueryItem(name: "pn", value: "1"),
                URLQueryItem(name: "ps", value: "100")
            ]
        }
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://space.bilibili.com/\(collection.mid)")
        let rows = ((root["data"] as? [String: Any])?["archives"] as? [[String: Any]]) ?? []
        return rows.compactMap { raw in
            var normalized = raw
            normalized["owner"] = ["name": owner, "mid": collection.mid, "face": ""]
            if normalized["pubdate"] == nil { normalized["pubdate"] = raw["ctime"] }
            return Self.video(normalized)
        }
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
        let matching = tracks.filter { Self.subtitleBelongs($0.url, aid: base.aid, cid: cid) }
        return base.replacingSubtitles(Self.uniqueSubtitles(matching))
    }

    func comments(aid: Int, page: Int = 1, sort: CommentSort = .hot,
                  cookie: String? = nil) async throws -> CommentPage {
        var components = URLComponents(string: "https://api.bilibili.com/x/v2/reply")!
        // The classic `pn`/`sort` endpoint still returns full pages; the newer
        // cursor (`next`/`mode`) form answers with an empty list for guests.
        components.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "oid", value: "\(aid)"),
            URLQueryItem(name: "sort", value: sort == .hot ? "1" : "0"),
            URLQueryItem(name: "pn", value: "\(max(1, page))"),
            URLQueryItem(name: "ps", value: "20")
        ]
        let root = try await requestObject(components.url!, cookie: cookie)
        let data = root["data"] as? [String: Any]
        var rows = data?["replies"] as? [[String: Any]] ?? []
        if page <= 1, let top = (data?["top_replies"] as? [[String: Any]]), !top.isEmpty {
            rows = top + rows
        }
        let comments = rows.compactMap(Self.comment)
        let pageInfo = data?["page"] as? [String: Any]
        let total = Self.integer(pageInfo?["count"]) ?? comments.count
        let size = Self.integer(pageInfo?["size"]) ?? 20
        return CommentPage(
            comments: comments,
            total: total,
            hasMore: max(1, page) * max(size, 1) < total
        )
    }
    /// Loads the account timeline used by Cilicili's Dynamic page.
    func dynamicFeed(cookie: String? = nil) async throws -> [DynamicItem] {
        guard let cookie, !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.unavailable
        }
        var components = URLComponents(string: "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "all"),
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "features", value: "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote,decorationCard,onlyfansAssetsV2,forwardListHidden,ugcDelete"),
            URLQueryItem(name: "web_location", value: "333.1365")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://t.bilibili.com/")
        let data = root["data"] as? [String: Any]
        return (data?["items"] as? [[String: Any]] ?? []).compactMap(Self.dynamicItem)
    }

    /// Returns the signed-in user's B 站 watch history.  The endpoint is
    /// intentionally called only after a cookie-backed login; anonymous
    /// browsing continues to use the public recommendation APIs.
    func watchHistory(page: Int = 1, pageSize: Int = 30,
                      cookie: String? = nil) async throws -> [WatchHistoryItem] {
        guard let cookie, !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.unavailable
        }
        var components = URLComponents(string: "https://api.bilibili.com/x/v2/history")!
        components.queryItems = [
            URLQueryItem(name: "pn", value: "\(max(1, page))"),
            URLQueryItem(name: "ps", value: "\(min(max(1, pageSize), 100))")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://www.bilibili.com/account/history")
        return Self.dictionaryRows(root["data"]).compactMap(Self.watchHistoryItem)
    }

    /// Lists the folders visible in the user's B 站 favorites.
    func favoriteFolders(cookie: String? = nil) async throws -> [FavoriteFolder] {
        guard let cookie,
              let mid = Self.cookieValue("DedeUserID", from: cookie),
              !mid.isEmpty else { throw APIError.unavailable }
        var components = URLComponents(string: "https://api.bilibili.com/x/v3/fav/folder/created/list-all")!
        components.queryItems = [
            URLQueryItem(name: "up_mid", value: mid),
            URLQueryItem(name: "type", value: "2")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://space.bilibili.com/\(mid)/favlist")
        return Self.dictionaryRows(root["data"]).compactMap(Self.favoriteFolder)
    }

    /// Loads videos from one B 站 favorite folder.  Favorite responses use a
    /// different shape than search responses, so they are normalized into the
    /// same Video model before reaching the existing detail/player UI.
    func favoriteVideos(folderID: Int, page: Int = 1, pageSize: Int = 30,
                        cookie: String? = nil) async throws -> [Video] {
        guard folderID > 0, let cookie,
              !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.unavailable
        }
        var components = URLComponents(string: "https://api.bilibili.com/x/v3/fav/resource/list")!
        components.queryItems = [
            URLQueryItem(name: "media_id", value: "\(folderID)"),
            URLQueryItem(name: "pn", value: "\(max(1, page))"),
            URLQueryItem(name: "ps", value: "\(min(max(1, pageSize), 100))"),
            URLQueryItem(name: "platform", value: "web")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://www.bilibili.com/medialist/detail/ml\(folderID)")
        return Self.dictionaryRows(root["data"]).compactMap(Self.favoriteVideo)
    }

    /// Reads the lightweight session list used by the B 站 private-message
    /// inbox.  Message bodies are not fetched here; the list is enough for the
    /// account page and avoids storing private conversations locally.
    func privateMessages(cookie: String? = nil) async throws -> [PrivateMessageThread] {
        guard let cookie, !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.unavailable
        }
        var components = URLComponents(string: "https://api.vc.bilibili.com/session_svr/v1/session_svr/get_sessions")!
        components.queryItems = [
            URLQueryItem(name: "session_type", value: "1"),
            URLQueryItem(name: "fold", value: "0"),
            URLQueryItem(name: "sort_rule", value: "2"),
            URLQueryItem(name: "build", value: "0"),
            URLQueryItem(name: "mobi_app", value: "web")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://message.bilibili.com/")
        let threads = Self.dictionaryRows(root["data"]).compactMap(Self.privateMessageThread)
        // The session list carries only ids: look the names / avatars up in one call.
        let missing = threads.filter { $0.userID > 0 && ($0.userName == "B 站用户" || $0.avatarURL == nil) }.map(\.userID)
        guard !missing.isEmpty else { return threads }
        let profiles = await userProfiles(uids: Array(Set(missing)), cookie: cookie)
        return threads.map { thread in
            guard let profile = profiles[thread.userID] else { return thread }
            return PrivateMessageThread(
                id: thread.id, userID: thread.userID,
                userName: thread.userName == "B 站用户" ? profile.name : thread.userName,
                avatarURL: thread.avatarURL ?? profile.face,
                lastMessage: thread.lastMessage, unreadCount: thread.unreadCount, updatedAt: thread.updatedAt)
        }
    }

    /// Reads the XML danmaku feed used by the Cilicili player.
    func danmaku(cid: Int, cookie: String? = nil) async throws -> [DanmakuCue] {
        guard cid > 0 else { throw APIError.invalidResponse }
        await ensureVisitorCookies()
        // Two equivalent XML endpoints; either may answer raw-deflate bytes without
        // a Content-Encoding header, so inflate when the body is not XML text.
        var xmlData: Data?
        for endpoint in ["https://api.bilibili.com/x/v1/dm/list.so?oid=\(cid)", "https://comment.bilibili.com/\(cid).xml"] {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            applyHeaders(to: &request, referer: "https://www.bilibili.com/")
            request.setValue("application/xml,text/xml,*/*", forHTTPHeaderField: "Accept")
            let cookies = mergedRequestCookieHeader(cookie)
            if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
            guard let (data, response) = try? await session.data(for: request),
                  Self.isSuccess(response), !data.isEmpty else { continue }
            var body = data
            if body.first != UInt8(ascii: "<"),
               let inflated = try? (body as NSData).decompressed(using: .zlib) as Data {
                body = inflated
            }
            if body.contains(UInt8(ascii: "<")) { xmlData = body; break }
        }
        guard let data = xmlData else { throw APIError.requestFailed }
        let parsed = try BilibiliDanmakuXMLParser().parse(data)
        return parsed.prefix(6000).enumerated().map { index, item in
            DanmakuCue(id: "\(cid)-\(index)-\(item.start)-\(item.text)",
                       start: item.start, end: item.end, text: item.text,
                       color: item.color, mode: item.mode)
        }
    }

    func interactionState(aid: Int, cookie: String? = nil) async throws -> InteractionState {
        guard aid > 0 else { throw APIError.invalidResponse }
        let likeURL = URL(string: "https://api.bilibili.com/x/web-interface/archive/has/like?aid=\(aid)")!
        let coinURL = URL(string: "https://api.bilibili.com/x/web-interface/archive/coins?aid=\(aid)")!
        let favoriteURL = URL(string: "https://api.bilibili.com/x/v2/fav/video/favoured?aid=\(aid)")!
        let likeRoot = try await requestObject(likeURL, cookie: cookie)
        let coinRoot = try await requestObject(coinURL, cookie: cookie)
        let favoriteRoot = try await requestObject(favoriteURL, cookie: cookie)
        let likeData = likeRoot["data"] as? [String: Any]
        let coinData = coinRoot["data"] as? [String: Any]
        let favoriteData = favoriteRoot["data"] as? [String: Any]
        let likeValue = Self.integer(likeRoot["data"]) ?? Self.integer(likeData?["like"]) ?? 0
        return InteractionState(
            isLiked: likeValue == 1 || Self.bool(likeData?["like"]) == true,
            coinCount: Self.integer(coinData?["multiply"] ?? coinRoot["data"]) ?? 0,
            isFavorited: Self.bool(favoriteData?["favoured"] ?? favoriteRoot["data"]) ?? false
        )
    }

    /// `root`/`parent` (rpid) turn the post into a reply inside a comment thread.
    func postComment(aid: Int, message: String, root: Int? = nil, parent: Int? = nil,
                     cookie: String? = nil) async throws {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard aid > 0, !text.isEmpty, let cookie,
              let csrf = Self.cookieValue("bili_jct", from: cookie), !csrf.isEmpty else {
            throw APIError.unavailable
        }
        let endpoint = URL(string: "https://api.bilibili.com/x/v2/reply/add")!
        var fields = [
            "oid": "\(aid)", "type": "1", "message": text,
            "plat": "1", "csrf": csrf
        ]
        if let root, root > 0 {
            fields["root"] = "\(root)"
            fields["parent"] = "\(parent ?? root)"
        }
        _ = try await postFormObject(endpoint, fields: fields,
                                     cookie: cookie, referer: "https://www.bilibili.com/video/")
    }

    func likeComment(aid: Int, rpid: Int, liked: Bool, cookie: String? = nil) async throws {
        guard aid > 0, rpid > 0, let cookie,
              let csrf = Self.cookieValue("bili_jct", from: cookie), !csrf.isEmpty else {
            throw APIError.unavailable
        }
        let endpoint = URL(string: "https://api.bilibili.com/x/v2/reply/action")!
        _ = try await postFormObject(endpoint, fields: [
            "oid": "\(aid)", "type": "1", "rpid": "\(rpid)",
            "action": liked ? "1" : "0", "csrf": csrf
        ], cookie: cookie, referer: "https://www.bilibili.com/video/")
    }

    /// Replies inside one comment thread (`root` is the top-level comment's rpid).
    func replies(aid: Int, root: Int, page: Int = 1, cookie: String? = nil) async throws -> CommentPage {
        var components = URLComponents(string: "https://api.bilibili.com/x/v2/reply/reply")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "oid", value: "\(aid)"),
            URLQueryItem(name: "root", value: "\(root)"),
            URLQueryItem(name: "pn", value: "\(max(1, page))"),
            URLQueryItem(name: "ps", value: "20")
        ]
        let root = try await requestObject(components.url!, cookie: cookie)
        let data = root["data"] as? [String: Any]
        let rows = data?["replies"] as? [[String: Any]] ?? []
        let comments = rows.compactMap(Self.comment)
        let pageInfo = data?["page"] as? [String: Any]
        let total = Self.integer(pageInfo?["count"]) ?? comments.count
        let size = Self.integer(pageInfo?["size"]) ?? 20
        return CommentPage(comments: comments, total: total, hasMore: max(1, page) * max(size, 1) < total)
    }

    func setVideoLike(aid: Int, liked: Bool, cookie: String? = nil) async throws {
        guard aid > 0, let cookie,
              let csrf = Self.cookieValue("bili_jct", from: cookie), !csrf.isEmpty else {
            throw APIError.unavailable
        }
        let endpoint = URL(string: "https://api.bilibili.com/x/web-interface/archive/like")!
        _ = try await postFormObject(endpoint, fields: [
            "aid": "\(aid)", "like": liked ? "1" : "2", "csrf": csrf,
            "cross_domain": "true", "source": "web_normal", "ga": "1"
        ], cookie: cookie, referer: "https://www.bilibili.com/")
    }

    /// Reports watch progress so the video appears in the account's 历史记录 (like the official app).
    func reportHistory(aid: Int, cid: Int, progress: Int, cookie: String?) async {
        guard aid > 0, cid > 0, let cookie,
              let csrf = Self.cookieValue("bili_jct", from: cookie), !csrf.isEmpty else { return }
        let endpoint = URL(string: "https://api.bilibili.com/x/v2/history/report")!
        _ = try? await postFormObject(endpoint, fields: [
            "aid": "\(aid)", "cid": "\(cid)", "progress": "\(max(0, progress))", "csrf": csrf
        ], cookie: cookie, referer: "https://www.bilibili.com/video/av\(aid)")
    }

    func addVideoCoin(aid: Int, cookie: String? = nil) async throws {
        guard aid > 0, let cookie,
              let csrf = Self.cookieValue("bili_jct", from: cookie), !csrf.isEmpty else {
            throw APIError.unavailable
        }
        let endpoint = URL(string: "https://api.bilibili.com/x/web-interface/coin/add")!
        _ = try await postFormObject(endpoint, fields: [
            "aid": "\(aid)", "multiply": "1", "select_like": "0", "csrf": csrf,
            "cross_domain": "true", "source": "web_normal", "ga": "1"
        ], cookie: cookie, referer: "https://www.bilibili.com/")
    }

    func setVideoFavorite(aid: Int, favorited: Bool, cookie: String? = nil) async throws {
        guard aid > 0, let cookie,
              let csrf = Self.cookieValue("bili_jct", from: cookie), !csrf.isEmpty,
              let mid = Self.cookieValue("DedeUserID", from: cookie) else { throw APIError.unavailable }
        var folderComponents = URLComponents(string: "https://api.bilibili.com/x/v3/fav/folder/created/list-all")!
        folderComponents.queryItems = [
            URLQueryItem(name: "up_mid", value: mid),
            URLQueryItem(name: "type", value: "2"),
            URLQueryItem(name: "rid", value: "\(aid)")
        ]
        let folderRoot = try await requestObject(folderComponents.url!, cookie: cookie)
        let rows = ((folderRoot["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        let folderIDs = rows.compactMap { Self.integer($0["id"] ?? $0["media_id"]) }.filter { $0 > 0 }
        let addIDs = favorited ? folderIDs.prefix(1).map(String.init).joined(separator: ",") : ""
        let deleteIDs = favorited ? "" : folderIDs.map(String.init).joined(separator: ",")
        guard favorited || !deleteIDs.isEmpty else { return }
        let endpoint = URL(string: "https://api.bilibili.com/x/v3/fav/resource/deal")!
        _ = try await postFormObject(endpoint, fields: [
            "rid": "\(aid)", "type": "2", "add_media_ids": addIDs,
            "del_media_ids": deleteIDs, "csrf": csrf, "platform": "web", "gaia_source": "web_normal", "ga": "1"
        ], cookie: cookie, referer: "https://www.bilibili.com/")
    }
    /// Returns one progressive stream plus the qualities actually accepted
    /// by the current account/video.  The UI never invents an unavailable
    /// resolution.
    func playback(for video: Video, quality: Int? = nil, muxed: Bool = false, cookie: String? = nil) async throws -> Playback {
        guard let cid = video.cid else { throw APIError.invalidResponse }
        let preferred = UserDefaults.standard.integer(forKey: "moumusic.bili.preferredQuality")
        let requestedQuality = quality ?? (preferred > 0 ? preferred : 80)
        var components = URLComponents(string: "https://api.bilibili.com/x/player/playurl")!
        components.queryItems = [
            URLQueryItem(name: "bvid", value: video.bvid),
            URLQueryItem(name: "cid", value: "\(cid)"),
            URLQueryItem(name: "qn", value: "\(requestedQuality)"),
            // fnval=1 -> muxed MP4 (video + audio in one stream). DASH video
            // streams are silent because the audio is a separate track.
            // 4048 = DASH + HDR/4K/Dolby Vision/8K/Dolby audio/AV1 flags (played natively by
            // AVPlayer with separate video+audio); 1 = one muxed MP4 (downloads, fallback).
            URLQueryItem(name: "fnval", value: muxed ? "1" : "4048"),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "fourk", value: "1"),
            URLQueryItem(name: "platform", value: muxed ? "html5" : "pc"),
            URLQueryItem(name: "high_quality", value: "1")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://www.bilibili.com/video/\(video.bvid)")
        guard let data = root["data"] as? [String: Any] else { throw APIError.invalidResponse }
        // Never report the requested qn as the achieved quality.  Bilibili
        // may downgrade a non-member or a restricted video while returning
        // HTTP 200; the actual representation is authoritative.
        var actualQuality = Self.integer(data["quality"]) ?? 0
        var available = Self.qualities(data)
        if actualQuality <= 0,
           let dash = data["dash"] as? [String: Any],
           let firstVideo = (dash["video"] as? [[String: Any]])?.first {
            actualQuality = Self.integer(firstVideo["id"] ?? firstVideo["quality"] ?? firstVideo["qn"]) ?? 0
        }
        if actualQuality <= 0 {
            actualQuality = available.first?.code ?? 0
        }
        if available.isEmpty, actualQuality > 0 {
            available = [VideoQuality(code: actualQuality, title: "\(actualQuality)p")]
        } else if actualQuality > 0 && !available.contains(where: { $0.code == actualQuality }) {
            available.append(VideoQuality(code: actualQuality, title: "\(actualQuality)p"))
            available.sort { $0.code > $1.code }
        }

        if !muxed, let dash = data["dash"] as? [String: Any],
           let videos = dash["video"] as? [[String: Any]], !videos.isEmpty {
            let ids = Set(videos.compactMap { Self.integer($0["id"]) })
            let target = ids.contains(actualQuality) ? actualQuality
                : (ids.filter { $0 <= actualQuality }.max() ?? ids.max() ?? actualQuality)
            let candidates = videos.filter { Self.integer($0["id"]) == target }
            func codec(_ row: [String: Any]) -> Int { Self.integer(row["codecid"]) ?? 0 }
            // Most compatible first: AVC, then HEVC (hev1 is re-tagged on the fly, see
            // BiliHEVCLoader), AV1 only where the hardware decodes it.
            let av1OK = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
            func rank(_ row: [String: Any]) -> Int {
                switch codec(row) { case 7: return 0; case 12: return 1; case 13: return av1OK ? 2 : 9; default: return 3 }
            }
            let ordered = candidates.filter { rank($0) < 9 }.sorted { rank($0) < rank($1) }
            let chosen = ordered.first
            func tagged(_ rawURL: URL, _ row: [String: Any]) -> URL {
                let url = Self.officialCDN(rawURL)
                let codecs = (Self.text(row["codecs"]) ?? "").lowercased()
                guard codecs.hasPrefix("hev1"), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
                parts.fragment = "mou-hev1"
                return parts.url ?? url
            }
            func allURLs(_ row: [String: Any]) -> [URL] {
                var urls: [URL] = []
                for key in ["baseUrl", "base_url", "url"] {
                    if let value = Self.text(row[key]), let url = URL(string: value) { urls.append(tagged(url, row)); break }
                }
                for value in ((row["backupUrl"] ?? row["backup_url"]) as? [String]) ?? [] {
                    if let url = URL(string: value) { urls.append(tagged(url, row)) }
                }
                return urls.filter { !Self.isPCDN($0) } + urls.filter { Self.isPCDN($0) }
            }
            func firstURL(_ row: [String: Any]) -> URL? {
                allURLs(row).first
            }
            func range(_ value: Any?) -> ClosedRange<Int>? {
                guard let text = Self.text(value) else { return nil }
                let parts = text.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 2, parts[0] <= parts[1] else { return nil }
                return parts[0]...parts[1]
            }
            func dashTrack(_ row: [String: Any]) -> BiliDashTrack? {
                let base = (row["segment_base"] ?? row["SegmentBase"]) as? [String: Any]
                let urls = allURLs(row)
                guard !urls.isEmpty else { return nil }
                return BiliDashTrack(
                    urls: urls,
                    initRange: range(base?["initialization"] ?? base?["Initialization"]),
                    indexRange: range(base?["index_range"] ?? base?["indexRange"]),
                    codecs: Self.text(row["codecs"]) ?? "",
                    bandwidth: Self.integer(row["bandwidth"]) ?? 0,
                    width: Self.integer(row["width"]) ?? 0,
                    height: Self.integer(row["height"]) ?? 0,
                    frameRate: Self.text(row["frame_rate"] ?? row["frameRate"])
                )
            }
            if let chosen, let videoURL = firstURL(chosen) {
                var alternates = ordered.flatMap(allURLs)
                var seenURLs = Set<String>()
                alternates = alternates.filter { $0 != videoURL && seenURLs.insert($0.absoluteString).inserted }
                let dolby = ((dash["dolby"] as? [String: Any])?["audio"] as? [[String: Any]])?.first
                let flac = (dash["flac"] as? [String: Any])?["audio"] as? [String: Any]
                let aac = (dash["audio"] as? [[String: Any]])?
                    .max { (Self.integer($0["id"]) ?? 0) < (Self.integer($1["id"]) ?? 0) }
                let audioRow = dolby ?? flac ?? aac
                var playback = Playback(url: videoURL, quality: target, qualities: available,
                                        audioURL: audioRow.flatMap(firstURL), alternateURLs: alternates)
                if let videoTrack = dashTrack(chosen), videoTrack.initRange != nil, videoTrack.indexRange != nil {
                    let audioTrack = audioRow.flatMap(dashTrack)
                    // Audio without an index cannot go through HLS; then the whole thing falls back.
                    if audioRow == nil || (audioTrack?.initRange != nil && audioTrack?.indexRange != nil) {
                        playback.dash = BiliDashSource(video: videoTrack, audio: audioTrack)
                    }
                }
                return playback
            }
        }

        if let rows = data["durl"] as? [[String: Any]] {
            let orderedRows = rows.sorted { left, right in
                let leftQuality = Self.integer(left["id"] ?? left["quality"] ?? left["qn"]) ?? 0
                let rightQuality = Self.integer(right["id"] ?? right["quality"] ?? right["qn"]) ?? 0
                return (leftQuality == actualQuality ? 1 : 0, leftQuality)
                    > (rightQuality == actualQuality ? 1 : 0, rightQuality)
            }
            for row in orderedRows {
                for key in ["url", "baseUrl", "base_url"] {
                    if let value = Self.text(row[key]), let url = URL(string: value).map(Self.officialCDN) {
                        let rowQuality = Self.integer(row["id"] ?? row["quality"] ?? row["qn"]) ?? actualQuality
                        return Playback(url: url, quality: rowQuality, qualities: available)
                    }
                }
            }
        }
        if let dash = data["dash"] as? [String: Any],
           let rows = dash["video"] as? [[String: Any]] {
            let orderedRows = rows.sorted { left, right in
                let leftQuality = Self.integer(left["id"] ?? left["quality"] ?? left["qn"]) ?? 0
                let rightQuality = Self.integer(right["id"] ?? right["quality"] ?? right["qn"]) ?? 0
                return (leftQuality == actualQuality ? 1 : 0, leftQuality)
                    > (rightQuality == actualQuality ? 1 : 0, rightQuality)
            }
            for row in orderedRows {
                for key in ["baseUrl", "base_url", "url"] {
                    if let value = Self.text(row[key]), let url = URL(string: value).map(Self.officialCDN) {
                        let rowQuality = Self.integer(row["id"] ?? row["quality"] ?? row["qn"]) ?? actualQuality
                        return Playback(url: url, quality: rowQuality, qualities: available)
                    }
                }
            }
        }
        throw APIError.unavailable
    }

    func playableURL(for video: Video, cookie: String? = nil) async throws -> URL {
        try await playback(for: video, muxed: true, cookie: cookie).url
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
    /// The first part's cid from the tiny pagelist endpoint (cached): listening needs nothing else from the
    /// video page, so it skips the video-detail and subtitle requests.
    func firstCID(bvid: String, cookie: String? = nil) async throws -> Int {
        if let cached = cidCache[bvid] { return cached }
        var components = URLComponents(string: "https://api.bilibili.com/x/player/pagelist")!
        components.queryItems = [URLQueryItem(name: "bvid", value: bvid)]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://www.bilibili.com/video/\(bvid)")
        guard let first = (root["data"] as? [[String: Any]])?.first,
              let cid = Self.integer(first["cid"]), cid > 0 else { throw APIError.invalidResponse }
        cidCache[bvid] = cid
        return cid
    }

    func audioPlayback(bvid: String, cid: Int, quality: Int? = nil,
                       cookie: String? = nil) async throws -> AudioPlayback {
        let candidates = try await audioCandidates(bvid: bvid, cid: cid, quality: quality, cookie: cookie)
        let selected = quality.flatMap { requested in
            candidates.first(where: { $0.quality.code == requested })
        } ?? candidates.first
        guard let selected else { throw APIError.unavailable }
        return AudioPlayback(url: selected.url, quality: selected.quality,
                             qualities: candidates.map(\.quality), dash: selected.dash)
    }

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
            qualities: candidates.map(\.quality),
            dash: selected.dash
        )
    }

    private struct AudioCandidate: Sendable {
        let url: URL
        let quality: BilibiliAudioQuality
        var dash: BiliDashTrack? = nil
    }

    private static func audioDashTrack(_ row: [String: Any]) -> BiliDashTrack? {
        func range(_ value: Any?) -> ClosedRange<Int>? {
            guard let text = Self.text(value) else { return nil }
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2, parts[0] <= parts[1] else { return nil }
            return parts[0]...parts[1]
        }
        let base = (row["segment_base"] ?? row["SegmentBase"]) as? [String: Any]
        var urls: [URL] = []
        for key in ["baseUrl", "base_url", "url"] {
            if let value = Self.text(row[key]), let url = URL(string: value) { urls.append(Self.officialCDN(url)); break }
        }
        for value in ((row["backupUrl"] ?? row["backup_url"]) as? [String]) ?? [] {
            if let url = URL(string: value) { urls.append(Self.officialCDN(url)) }
        }
        urls = urls.filter { !Self.isPCDN($0) } + urls.filter { Self.isPCDN($0) }
        guard !urls.isEmpty,
              let initRange = range(base?["initialization"] ?? base?["Initialization"]),
              let indexRange = range(base?["index_range"] ?? base?["indexRange"]) else { return nil }
        return BiliDashTrack(urls: urls, initRange: initRange, indexRange: indexRange,
                             codecs: Self.text(row["codecs"]) ?? "mp4a.40.2",
                             bandwidth: Self.integer(row["bandwidth"]) ?? 0,
                             width: 0, height: 0, frameRate: nil)
    }

    private func audioCandidates(for video: Video, quality: Int?, cookie: String?) async throws -> [AudioCandidate] {
        guard let cid = video.cid else { throw APIError.invalidResponse }
        return try await audioCandidates(bvid: video.bvid, cid: cid, quality: quality, cookie: cookie)
    }

    private func audioCandidates(bvid: String, cid: Int, quality: Int?, cookie: String?) async throws -> [AudioCandidate] {
        var components = URLComponents(string: "https://api.bilibili.com/x/player/playurl")!
        components.queryItems = [
            URLQueryItem(name: "bvid", value: bvid),
            URLQueryItem(name: "cid", value: "\(cid)"),
            URLQueryItem(name: "qn", value: "\(quality ?? 120)"),
            URLQueryItem(name: "fnval", value: "4048"),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "fourk", value: "1")
        ]
        let root = try await requestObject(components.url!, cookie: cookie,
                                           referer: "https://www.bilibili.com/video/\(bvid)")
        guard let data = root["data"] as? [String: Any],
              let dash = data["dash"] as? [String: Any],
              let rows = dash["audio"] as? [[String: Any]],
              !rows.isEmpty else {
            throw APIError.unavailable
        }

        var candidates: [AudioCandidate] = []
        var seen = Set<Int>()
        for (index, row) in rows.enumerated() {
            let bandwidth = Self.integer(row["bandwidth"])
            let bandwidthKbps = Self.integer(row["bandwidth_kbps"])
            let bitrate = bandwidth ?? bandwidthKbps
            let fallbackCode = bitrate.map { max(1, $0) } ?? (index + 1)
            let code = Self.integer(row["id"] ?? row["quality"] ?? row["code"]) ?? fallbackCode
            guard seen.insert(code).inserted else { continue }

            let rawURL = Self.text(row["baseUrl"] ?? row["base_url"] ?? row["url"])
                ?? (row["backupUrl"] as? [Any])?.compactMap { Self.text($0) }.first
            guard let rawURL, let url = URL(string: rawURL) else { continue }

            let isHiRes = Self.bool(row["is_hi_res"] ?? row["hi_res"] ?? row["hires"]) == true || code == 30251
            let isDolby = Self.bool(row["is_dolby"] ?? row["dolby"] ?? row["atmos"]) == true ||
                code == 30250 || code == 30255
            let requiresLogin = Self.bool(row["need_login"] ?? row["needLogin"]) == true
            let requiresVIP = Self.bool(row["need_vip"] ?? row["needVip"] ?? row["need_member"]) == true
            let title = Self.audioQualityTitle(code: code, bitrate: bitrate, row: row)
            candidates.append(AudioCandidate(
                url: url,
                quality: BilibiliAudioQuality(
                    code: code,
                    title: title,
                    bitrate: bitrate,
                    requiresLogin: requiresLogin,
                    requiresVIP: requiresVIP,
                    isHiRes: isHiRes,
                    isDolby: isDolby
                ),
                dash: Self.audioDashTrack(row)
            ))
        }

        guard !candidates.isEmpty else { throw APIError.unavailable }
        return candidates.sorted {
            let left = (Self.audioQualityRank($0.quality.code), $0.quality.bitrate ?? 0, $0.quality.code)
            let right = (Self.audioQualityRank($1.quality.code), $1.quality.bitrate ?? 0, $1.quality.code)
            return left > right
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
        let rows = (subtitleData?["subtitles"] as? [[String: Any]])
            ?? (subtitleData?["list"] as? [[String: Any]])
            ?? (data?["subtitle"] as? [[String: Any]])
            ?? []
        return rows.compactMap(Self.subtitle).filter { Self.subtitleBelongs($0.url, aid: aid, cid: cid) }
    }

    /// AI subtitles are stored under `ai_subtitle/prod/<aid><cid><hash>`. For guests (and some
    /// accounts) the player API hands out another video's file; accept only the matching ones.
    static func subtitleBelongs(_ url: URL, aid: Int, cid: Int) -> Bool {
        guard url.path.contains("/ai_subtitle/") else { return true }
        return url.lastPathComponent.hasPrefix("\(aid)\(cid)")
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

    private func postFormObject(_ url: URL,
                                fields: [String: String],
                                cookie: String,
                                referer: String) async throws -> [String: Any] {
        await ensureVisitorCookies()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request, referer: referer)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let cookies = mergedRequestCookieHeader(cookie)
        if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        collectCookies(from: response)
        guard Self.isSuccess(response), let root = Self.object(data) else {
            throw APIError.requestFailed
        }
        guard Self.integer(root["code"]) == 0 else { throw APIError.unavailable }
        return root
    }
    private func requestObject(_ url: URL, cookie: String? = nil,
                               referer: String = "https://www.bilibili.com/",
                               headers: [String: String] = [:]) async throws -> [String: Any] {
        var attempt = 0
        while true {
            await ensureVisitorCookies()
            var request = URLRequest(url: url)
            applyHeaders(to: &request, referer: referer)
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            let cookies = mergedRequestCookieHeader(cookie)
            if !cookies.isEmpty {
                request.setValue(cookies, forHTTPHeaderField: "Cookie")
            }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                let root = Self.object(data)
                let code = root.flatMap { Self.integer($0["code"]) } ?? 0
                // Search and a few other endpoints answer 412 / -412 / -799 when the visitor
                // fingerprint is stale: refresh it and ask again instead of failing the search.
                let retryable = [412, 429, 502, 503].contains(status) || [-412, -799, -352, -509, -504, -1200].contains(code)
                if retryable, attempt < 3 {
                    attempt += 1
                    invalidateVisitorCookies()
                    try? await Task.sleep(for: .milliseconds(300 * attempt))
                    continue
                }
                guard Self.isSuccess(response), let root else { throw APIError.requestFailed }
                guard Self.integer(root["code"]) == 0 else { throw APIError.unavailable }
                return root
            } catch let error as URLError where attempt < 3 && error.code != .cancelled {
                attempt += 1
                try? await Task.sleep(for: .milliseconds(300 * attempt))
            }
        }
    }

    // MARK: WBI-signed search

    private static let wbiMixinTable = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39,
        12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63,
        57, 62, 11, 36, 20, 34, 44, 52
    ]

    private func wbiKey() async -> String? {
        if let cached = wbiMixinKey, Date().timeIntervalSince(cached.fetchedAt) < 3600 { return cached.key }
        await ensureVisitorCookies()
        var request = URLRequest(url: URL(string: "https://api.bilibili.com/x/web-interface/nav")!)
        applyHeaders(to: &request, referer: "https://www.bilibili.com/")
        let cookies = mergedRequestCookieHeader(nil)
        if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        // Signed-out visitors get code -101 here but still receive the wbi_img keys.
        guard let (data, _) = try? await session.data(for: request),
              let root = Self.object(data),
              let image = (root["data"] as? [String: Any])?["wbi_img"] as? [String: Any],
              let imgURL = image["img_url"] as? String, let subURL = image["sub_url"] as? String else { return nil }
        func stem(_ value: String) -> String {
            (value as NSString).lastPathComponent.components(separatedBy: ".").first ?? ""
        }
        let source = Array(stem(imgURL) + stem(subURL))
        guard source.count >= 64 else { return nil }
        let key = String(Self.wbiMixinTable.prefix(32).map { source[$0] })
        wbiMixinKey = (key, Date())
        return key
    }

    private func wbiSignedURL(_ base: String, _ items: [URLQueryItem]) async -> URL? {
        guard let key = await wbiKey() else { return nil }
        var pairs = items.map { ($0.name, $0.value ?? "") }
        pairs.append(("wts", String(Int(Date().timeIntervalSince1970))))
        pairs.sort { $0.0 < $1.0 }
        let unsafe = Set("!'()*")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        func encode(_ value: String) -> String {
            let cleaned = String(value.filter { !unsafe.contains($0) })
            return cleaned.addingPercentEncoding(withAllowedCharacters: allowed) ?? cleaned
        }
        let query = pairs.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        let sign = Insecure.MD5.hash(data: Data((query + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "\(base)?\(query)&w_rid=\(sign)")
    }

    /// Search endpoints reject unsigned requests more and more often (-412): sign them with WBI first,
    /// and fall back to the plain endpoint if the keys cannot be fetched or the signed call fails.
    private func searchObject(_ items: [URLQueryItem], cookie: String?) async throws -> [String: Any] {
        let referer = "https://search.bilibili.com/"
        func hasResults(_ root: [String: Any]) -> Bool {
            !(((root["data"] as? [String: Any])?["result"] as? [[String: Any]]) ?? []).isEmpty
        }
        var plainError: Error?
        var plain: [String: Any]?
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/search/type")!
        components.queryItems = items
        do { plain = try await requestObject(components.url!, cookie: cookie, referer: referer) }
        catch { plainError = error }
        if let plain, hasResults(plain) { return plain }
        // The plain endpoint failed (-412) or came back empty: try the WBI-signed one and keep whichever
        // actually has results.
        if let signed = await wbiSignedURL("https://api.bilibili.com/x/web-interface/wbi/search/type", items),
           let root = try? await requestObject(signed, cookie: cookie, referer: referer), hasResults(root) {
            return root
        }
        if let plain { return plain }
        throw plainError ?? APIError.requestFailed
    }

    private static func deviceFingerprint() -> String {
        let key = "moumusic.bili.fingerprint"
        if let stored = UserDefaults.standard.string(forKey: key), stored.count == 64 { return stored }
        let value = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let fingerprint = String(value.prefix(64))
        UserDefaults.standard.set(fingerprint, forKey: key)
        return fingerprint
    }

    private func invalidateVisitorCookies() {
        for cookie in cookieStorage.cookies ?? [] where visitorCookieNames.contains(cookie.name) {
            cookieStorage.deleteCookie(cookie)
        }
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

    // Reads the dimension object (width, height, rotate) and applies the rotation.
    private static func displayDimensions(_ raw: [String: Any]?) -> (width: Int, height: Int) {
        guard let raw, let width = integer(raw["width"]), let height = integer(raw["height"]),
              width > 0, height > 0 else { return (0, 0) }
        return integer(raw["rotate"]) == 1 ? (height, width) : (width, height)
    }

    private static func video(_ raw: [String: Any]) -> Video? {
        let bvid = text(raw["bvid"]) ?? ""
        guard !bvid.isEmpty else { return nil }
        let owner = raw["owner"] as? [String: Any]
        let stat = raw["stat"] as? [String: Any]
        let firstPage = (raw["pages"] as? [[String: Any]])?.first
        let durationText = text(raw["duration"] ?? firstPage?["duration"]) ?? ""
        let subtitleRows = ((raw["subtitle"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        let dimensions = displayDimensions(raw["dimension"] as? [String: Any] ?? firstPage?["dimension"] as? [String: Any])
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
            playCount: count(raw["play"] ?? stat?["view"] ?? raw["cover_left_text_1"]) ?? 0,
            commentCount: count(raw["review"] ?? stat?["reply"] ?? raw["cover_left_text_2"]) ?? 0,
            publishedAt: integer(raw["pubdate"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            subtitles: subtitleRows.compactMap(Self.subtitle),
            videoWidth: dimensions.width,
            videoHeight: dimensions.height,
            pages: ((raw["pages"] as? [[String: Any]]) ?? []).compactMap { row in
                guard let cid = integer(row["cid"]), cid > 0 else { return nil }
                return VideoPage(cid: cid, page: integer(row["page"]) ?? 1,
                                 part: stripHTML(text(row["part"]) ?? ""),
                                 duration: TimeInterval(integer(row["duration"]) ?? 0))
            }
        )
    }

    /// The mobile feed returns an `aid` in `param` and puts the rest of the
    /// metadata in `args`/`player_args`, unlike the web feed. Normalize it to
    /// the same Video model so the existing detail, subtitle and player flows
    /// work for both recommendation clients.
    private static func appVideo(_ raw: [String: Any]) -> Video? {
        guard let aid = integer(raw["aid"] ?? raw["param"]), aid > 0 else { return nil }
        let args = raw["args"] as? [String: Any]
        let playerArgs = raw["player_args"] as? [String: Any]
        var normalized = raw
        normalized["bvid"] = bvid(for: aid)
        normalized["aid"] = aid
        normalized["cid"] = playerArgs?["cid"]
        normalized["pic"] = raw["cover"]
        normalized["author"] = args?["up_name"]
        normalized["mid"] = args?["up_id"]
        normalized["face"] = args?["up_face"] ?? raw["face"]
        normalized["description"] = raw["desc"] ?? ""
        let duration = integer(playerArgs?["duration"])
            ?? Int(parseDuration(text(raw["cover_right_text"]) ?? ""))
        normalized["duration"] = formatDuration(duration)
        normalized["play"] = raw["cover_left_text_1"]
        normalized["review"] = raw["cover_left_text_2"]
        return video(normalized)
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
        let aiGenerated = aiStatus > 0 || aiType > 0 || type == 1 || language.lowercased().hasPrefix("ai-")
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
            let rawTitle = text(raw["new_description"] ?? raw["display_desc"] ?? raw["description"])
            let title = rawTitle ?? videoQualityTitle(code)
            let requiresLogin = bool(raw["need_login"] ?? raw["needLogin"]) == true
            let requiresVIP = bool(raw["need_vip"] ?? raw["needVip"] ?? raw["need_member"]) == true
            let isHDR = bool(raw["is_hdr"] ?? raw["hdr"]) == true ||
                title.localizedCaseInsensitiveContains("hdr") || code == 125
            let isDolby = bool(raw["is_dolby"] ?? raw["dolby"]) == true ||
                title.localizedCaseInsensitiveContains("dolby") || title.contains("杜比") || code == 126
            return VideoQuality(code: code, title: title, requiresLogin: requiresLogin,
                               requiresVIP: requiresVIP, isHDR: isHDR, isDolby: isDolby)
        }
        let dashFormats = ((data["dash"] as? [String: Any])?["video"] as? [[String: Any]] ?? [])
            .compactMap { raw -> VideoQuality? in
                guard let code = integer(raw["id"] ?? raw["quality"] ?? raw["qn"]), code > 0 else { return nil }
                let rawTitle = text(raw["display_desc"] ?? raw["description"] ?? raw["format"])
                let title = rawTitle ?? videoQualityTitle(code)
                return VideoQuality(
                    code: code,
                    title: title,
                    requiresLogin: bool(raw["need_login"] ?? raw["needLogin"]) == true,
                    requiresVIP: bool(raw["need_vip"] ?? raw["needVip"] ?? raw["need_member"]) == true,
                    isHDR: bool(raw["is_hdr"] ?? raw["hdr"]) == true || code == 125,
                    isDolby: bool(raw["is_dolby"] ?? raw["dolby"]) == true || code == 126
                )
            }

        if !formats.isEmpty || !dashFormats.isEmpty {
            return Array(Dictionary(grouping: formats + dashFormats, by: \.code).values.compactMap(\.first))
                .sorted { $0.code > $1.code }
        }

        let codes = data["accept_quality"] as? [Any] ?? []
        let descriptions = data["accept_description"] as? [Any] ?? []
        return codes.enumerated().compactMap { index, value in
            guard let code = integer(value), code > 0 else { return nil }
            let title = index < descriptions.count ? (text(descriptions[index]) ?? videoQualityTitle(code)) : videoQualityTitle(code)
            return VideoQuality(code: code, title: title, isHDR: code == 125, isDolby: code == 126)
        }
        .sorted { $0.code > $1.code }
    }

    private static func videoQualityTitle(_ code: Int) -> String {
        switch code {
        case 127: return "8K"
        case 126: return "杜比视界"
        case 125: return "HDR"
        case 120: return "4K"
        case 116: return "1080P 60帧"
        case 112: return "1080P+"
        case 80: return "1080P"
        case 74: return "720P 60帧"
        case 64: return "720P"
        case 32: return "480P"
        case 16: return "360P"
        default: return "\(code)p"
        }
    }

    private static func audioQualityTitle(code: Int, bitrate: Int?, row: [String: Any]) -> String {
        if let title = text(row["display_desc"] ?? row["description"] ?? row["format"]) {
            let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { return normalized }
        }
        switch code {
        case 30251: return "Hi-Res"
        case 30250: return "杜比全景声"
        case 30255: return "杜比音效"
        case 30280: return "192 kbps"
        case 30232: return "132 kbps"
        case 30216: return "64 kbps"
        default:
            if let bitrate, bitrate > 0 {
                return "\(max(1, Int((Double(bitrate) / 1000.0).rounded()))) kbps"
            }
            return "Audio \(code)"
        }
    }

    private static func audioQualityRank(_ code: Int) -> Int {
        switch code {
        case 30251: return 600 // Hi-Res
        case 30250: return 590 // Dolby Atmos
        case 30255: return 580 // Dolby audio
        case 30280: return 300
        case 30232: return 200
        case 30216: return 100
        default: return 0
        }
    }

    private static func dateFromMilliseconds(_ value: Any?) -> Date? {
        let raw: Double?
        if let value = value as? NSNumber {
            raw = value.doubleValue
        } else if let value = value as? String {
            raw = Double(value)
        } else {
            raw = nil
        }
        guard let raw, raw > 0 else { return nil }
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    private static func uniqueSubtitles(_ subtitles: [Subtitle]) -> [Subtitle] {
        var seen = Set<String>()
        return subtitles.filter { seen.insert("\($0.language.lowercased())|\($0.isAIGenerated)|\($0.isTranslated)").inserted }
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

    private static func dynamicItem(_ raw: [String: Any]) -> DynamicItem? {
        let modules = raw["modules"] as? [String: Any]
        let authorModule = modules?["module_author"] as? [String: Any]
        let dynamicModule = modules?["module_dynamic"] as? [String: Any]
        let major = dynamicModule?["major"] as? [String: Any]
        let archive = major?["archive"] as? [String: Any]
        let bvid = text(archive?["bvid"] ?? raw["bvid"])
        let video: Video? = bvid.flatMap { value in
            var normalized = archive ?? [:]
            normalized["bvid"] = value
            normalized["aid"] = archive?["aid"] ?? raw["rid"]
            normalized["pic"] = archive?["cover"]
            normalized["author"] = authorModule?["name"]
            normalized["mid"] = authorModule?["mid"]
            normalized["face"] = authorModule?["face"]
            normalized["description"] = archive?["desc"] ?? ""
            normalized["duration"] = archive?["duration_text"] ?? ""
            return Self.video(normalized)
        }
        let id = text(raw["id_str"] ?? raw["id"] ?? raw["dyn_id_str"]) ?? UUID().uuidString
        let textValue = stripHTML(text(dynamicModule?["desc"] ?? raw["content"] ?? raw["text"]) ?? "")
        let author = stripHTML(text(authorModule?["name"] ?? raw["uname"]) ?? "B 站用户")
        let cover = imageURL(text(archive?["cover"] ?? raw["cover"]))
        guard !textValue.isEmpty || video != nil else { return nil }
        let stats = modules?["module_stat"] as? [String: Any]
        return DynamicItem(
            id: id,
            author: author,
            avatarURL: imageURL(text(authorModule?["face"] ?? raw["face"])),
            text: textValue,
            coverURL: cover,
            publishedAt: dateFromMilliseconds(authorModule?["pub_ts"] ?? raw["pub_ts"]),
            likeCount: integer(stats?["like"] ?? raw["like"]) ?? 0,
            commentCount: integer(stats?["comment"] ?? raw["comment"]) ?? 0,
            video: video
        )
    }

    private static func dictionaryRows(_ value: Any?) -> [[String: Any]] {
        if let rows = value as? [[String: Any]] { return rows }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? [String: Any] }
        }
        guard let payload = value as? [String: Any] else { return [] }
        for key in ["list", "items", "medias", "session_list", "result", "folders"] {
            if let rows = payload[key] as? [[String: Any]] { return rows }
            if let values = payload[key] as? [Any] {
                let rows = values.compactMap { $0 as? [String: Any] }
                if !rows.isEmpty { return rows }
            }
        }
        return []
    }

    private static func watchHistoryItem(_ raw: [String: Any]) -> WatchHistoryItem? {
        let nested = raw["history"] as? [String: Any]
        let bvid = text(raw["bvid"] ?? nested?["bvid"])
        let title = stripHTML(text(raw["title"] ?? nested?["title"]) ?? "")
        guard !title.isEmpty || bvid != nil else { return nil }
        let owner = raw["owner"] as? [String: Any] ?? nested?["owner"] as? [String: Any]
        let author = stripHTML(text(raw["author"] ?? raw["uname"] ?? owner?["name"]
                                    ?? nested?["author"]) ?? "B 站用户")
        let durationValue = integer(raw["duration"] ?? nested?["duration"])
        let durationText = text(raw["duration_text"] ?? nested?["duration_text"])
            ?? durationValue.map(formatDuration)
            ?? text(raw["duration"] ?? nested?["duration"])
            ?? ""
        var normalized = raw
        if let bvid { normalized["bvid"] = bvid }
        if let aid = integer(raw["aid"] ?? nested?["aid"]) { normalized["aid"] = aid }
        normalized["title"] = title
        normalized["pic"] = raw["pic"] ?? raw["cover"] ?? nested?["pic"] ?? nested?["cover"]
        normalized["author"] = author
        normalized["duration"] = durationText
        let video = bvid.flatMap { _ in Self.video(normalized) }
        let historyID = text(raw["kid"] ?? raw["history_id"] ?? raw["id"])
            ?? bvid
            ?? UUID().uuidString
        return WatchHistoryItem(
            historyID: historyID,
            bvid: bvid,
            title: title.isEmpty ? "B 站视频" : title,
            coverURL: imageURL(text(raw["pic"] ?? raw["cover"] ?? nested?["pic"] ?? nested?["cover"])),
            author: author,
            durationText: durationText,
            viewedAt: dateFromMilliseconds(raw["view_at"] ?? raw["watched_at"] ?? raw["viewed_at"]),
            video: video
        )
    }

    private static func favoriteFolder(_ raw: [String: Any]) -> FavoriteFolder? {
        let id = integer(raw["id"] ?? raw["media_id"] ?? raw["fid"]) ?? 0
        guard id > 0 else { return nil }
        return FavoriteFolder(
            id: id,
            title: stripHTML(text(raw["title"] ?? raw["name"]) ?? "收藏夹"),
            mediaCount: integer(raw["media_count"] ?? raw["count"] ?? raw["cnt_info"]) ?? 0,
            coverURL: imageURL(text(raw["cover"] ?? raw["cover_url"] ?? raw["pic"]))
        )
    }

    private static func favoriteVideo(_ raw: [String: Any]) -> Video? {
        let aid = integer(raw["aid"] ?? raw["id"] ?? raw["rid"])
        var normalized = raw
        if normalized["bvid"] == nil, let aid, aid > 0 {
            normalized["bvid"] = bvid(for: aid)
        }
        if normalized["aid"] == nil, let aid { normalized["aid"] = aid }
        let upper = raw["upper"] as? [String: Any]
        normalized["pic"] = raw["pic"] ?? raw["cover"]
        normalized["author"] = raw["author"] ?? raw["upper_name"] ?? upper?["name"]
        normalized["mid"] = raw["mid"] ?? upper?["mid"]
        normalized["face"] = raw["face"] ?? upper?["face"]
        normalized["description"] = raw["intro"] ?? raw["description"] ?? ""
        if let seconds = integer(raw["duration"]) {
            normalized["duration"] = formatDuration(seconds)
        }
        let counts = raw["cnt_info"] as? [String: Any]
        normalized["play"] = raw["play"] ?? counts?["play"]
        normalized["review"] = raw["review"] ?? counts?["reply"]
        return video(normalized)
    }

    private static func privateMessageThread(_ raw: [String: Any]) -> PrivateMessageThread? {
        let account = raw["account_info"] as? [String: Any]
            ?? raw["talker_info"] as? [String: Any]
            ?? raw["user_info"] as? [String: Any]
        let userID = integer(raw["talker_id"] ?? raw["talkerid"] ?? raw["mid"] ?? account?["mid"]) ?? 0
        let userName = stripHTML(text(account?["uname"] ?? account?["name"] ?? raw["uname"])
                                  ?? "B 站用户")
        let last = raw["last_msg"] as? [String: Any]
        let message = stripHTML(text(last?["content"] ?? last?["msg"] ?? last?["text"]
                                     ?? raw["content"] ?? raw["message"]) ?? "新消息")
        let threadID = text(raw["session_id"] ?? raw["id"])
            ?? (userID > 0 ? "\(userID)" : UUID().uuidString)
        return PrivateMessageThread(
            id: threadID,
            userID: userID,
            userName: userName,
            avatarURL: imageURL(text(account?["face"] ?? account?["avatar"] ?? raw["face"])),
            lastMessage: message,
            unreadCount: integer(raw["unread_count"] ?? raw["unread"] ?? raw["is_unread"]) ?? 0,
            updatedAt: dateFromMilliseconds(raw["session_ts"] ?? raw["updated_at"] ?? raw["timestamp"])
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
            replyCount: integer(raw["rcount"]) ?? 0,
            liked: integer(raw["action"]) == 1,
            previewReplies: (raw["replies"] as? [[String: Any]] ?? []).compactMap(comment)
        )
    }

    private func cookieHeader() -> String {
        let cookies = cookieStorage.cookies?.filter { sessionCookieNames.contains($0.name) } ?? []
        return cookies.sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private func collectCookies(from response: URLResponse) {
        guard let http = response as? HTTPURLResponse,
              let url = http.url else { return }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            cookieStorage.setCookie(cookie)
        }
    }

    /// Higher qualities are often served from PCDN / MCDN nodes (`*.mcdn.bilivideo.cn:4483`,
    /// `*.szbdyd.com`, bare IPs) that AVPlayer cannot open ("无法打开"; 480P happened to be on
    /// upos). Like PiliPlus' CDN setting, point those `upgcxcode` paths at an official upos host.
    /// Keeps signed stream URLs as issued: rewriting the host to another upos mirror breaks the
    /// signature on some nodes (HTTP 403). PCDN nodes are avoided by ordering instead.
    static func officialCDN(_ url: URL) -> URL { url }

    /// PCDN / MCDN nodes (`*.mcdn.bilivideo.cn`, `*.szbdyd.com`, bare IPs, custom ports) are the
    /// least reliable; prefer the upos / akamai URLs when a row offers several.
    static func isPCDN(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("mcdn") || host.contains("szbdyd") || url.port != nil
            || host.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func cookieValue(_ name: String, from header: String) -> String? {
        header.split(separator: ";").compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            return (pair[0].trimmingCharacters(in: .whitespaces), pair[1])
        }.first(where: { $0.0 == name })?.1
    }
    private static func cookieHeader(fromLoginURL rawURL: String?) -> String {
        let allowed = Set(["DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct", "sid"])
        var values: [String: String] = [:]
        guard let rawURL, !rawURL.isEmpty else { return "" }

        // The QR poll response has used both a flat login URL and a URL
        // nested in `gourl` over time.  The nested form can be percent
        // encoded more than once, so parse every decoded representation
        // instead of looking only at the first URLComponents query.
        func scan(_ text: String) {
            if let components = URLComponents(string: text) {
                for item in components.queryItems ?? [] where allowed.contains(item.name) {
                    if let value = item.value, !value.isEmpty { values[item.name] = value }
                }
            }

            for item in text.split(whereSeparator: {
                $0 == "?" || $0 == "&" || $0 == "#" || $0 == ";" || $0 == "\n" || $0 == "\r"
            }) {
                let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let name = pair[0].removingPercentEncoding ?? pair[0]
                let value = pair[1].removingPercentEncoding ?? pair[1]
                if allowed.contains(name), !value.isEmpty { values[name] = value }
            }
        }

        var representations = [rawURL]
        var decoded = rawURL
        for _ in 0..<3 {
            guard let next = decoded.removingPercentEncoding, next != decoded else { break }
            representations.append(next)
            decoded = next
        }
        representations.forEach(scan)
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
        guard !hasVisitorCookies else { return }
        if let visitorBootstrapTask {
            await visitorBootstrapTask.value
            return
        }

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self = self else { return }
            await self.bootstrapVisitorCookies()
        }
        visitorBootstrapTask = task
        await task.value
        visitorBootstrapTask = nil
    }

    private func bootstrapVisitorCookies() async {
        guard !hasVisitorCookies else { return }
        guard let endpoint = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") else { return }

        // Bilibili can briefly reject the fingerprint endpoint while the app
        // is waking. A short second attempt prevents the very first search
        // from being sacrificed to that transient response.
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(250))
            }
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 3600
            applyHeaders(to: &request, referer: "https://www.bilibili.com/")
            guard let (data, response) = try? await session.data(for: request),
                  Self.isSuccess(response),
                  let root = Self.object(data),
                  Self.integer(root["code"]) == 0,
                  let payload = root["data"] as? [String: Any] else { continue }

            collectCookies(from: response)
            if let buvid3 = Self.text(payload["b_3"]) { storeVisitorCookie(name: "buvid3", value: buvid3) }
            if let buvid4 = Self.text(payload["b_4"]) { storeVisitorCookie(name: "buvid4", value: buvid4) }
            if hasVisitorCookies { return }
        }
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

    private static func count(_ value: Any?) -> Int? {
        if let value = integer(value) { return value }
        guard let raw = text(value)?.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let multiplier: Double
        let number: Substring
        if raw.hasSuffix("亿") {
            multiplier = 100_000_000
            number = raw.dropLast()
        } else if raw.hasSuffix("万") {
            multiplier = 10_000
            number = raw.dropLast()
        } else if raw.lowercased().hasSuffix("m") {
            multiplier = 1_000_000
            number = raw.dropLast()
        } else if raw.lowercased().hasSuffix("k") {
            multiplier = 1_000
            number = raw.dropLast()
        } else {
            multiplier = 1
            number = Substring(raw)
        }
        guard let value = Double(String(number)) else { return nil }
        return Int(value * multiplier)
    }

    private static func queryInteger(_ url: URL, name: String) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == name })?.value.flatMap { Int($0) }
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
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

    private static func formatDuration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    private static let bvidAlphabet = Array(
        "FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf"
    )

    /// Converts the mobile feed's numeric aid into the BV id expected by the
    /// existing detail endpoint. This is the public reversible Bilibili id
    /// transform also used by PiliPlus; it does not contact another service.
    private static func bvid(for aid: Int) -> String {
        var characters = Array("BV1000000000")
        var value = ((Int64(1) << 51) | Int64(aid)) ^ 23_442_827_791_579
        var index = characters.count - 1
        while value > 0, index >= 0 {
            characters[index] = bvidAlphabet[Int(value % 58)]
            value /= 58
            index -= 1
        }
        characters.swapAt(3, 9)
        characters.swapAt(4, 7)
        return String(characters)
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

// MARK: - Messages: names, conversation, notices

extension BilibiliAPI {
    struct ChatMessage: Identifiable, Hashable, Sendable {
        let id: String
        let senderID: Int
        let text: String
        let date: Date?
    }

    struct FeedNotice: Identifiable, Hashable, Sendable {
        let id: String
        let userName: String
        let avatarURL: String?
        let action: String
        let content: String
        let date: Date?
    }

    enum NoticeKind: String, CaseIterable, Identifiable, Sendable {
        case reply = "回复我的"
        case at = "@我"
        case like = "收到的赞"

        var id: String { rawValue }
        var path: String {
            switch self {
            case .reply: return "reply"
            case .at: return "at"
            case .like: return "like"
            }
        }
    }

    func userProfiles(uids: [Int], cookie: String?) async -> [Int: (name: String, face: String?)] {
        guard !uids.isEmpty else { return [:] }
        var components = URLComponents(string: "https://api.vc.bilibili.com/account/v1/user/infos")!
        components.queryItems = [URLQueryItem(name: "uids", value: uids.map(String.init).joined(separator: ","))]
        guard let root = try? await requestObject(components.url!, cookie: cookie,
                                                  referer: "https://message.bilibili.com/") else { return [:] }
        var result: [Int: (name: String, face: String?)] = [:]
        for row in Self.dictionaryRows(root["data"]) {
            guard let mid = Self.integer(row["mid"] ?? row["uid"]),
                  let name = Self.text(row["name"] ?? row["uname"]), !name.isEmpty else { continue }
            result[mid] = (name, Self.imageURL(Self.text(row["face"])))
        }
        return result
    }

    /// Latest messages of one private conversation, oldest first.
    func conversation(talker: Int, cookie: String?) async throws -> [ChatMessage] {
        guard talker > 0 else { throw APIError.invalidResponse }
        var components = URLComponents(string: "https://api.vc.bilibili.com/svr_sync/v1/svr_sync/fetch_session_msgs")!
        components.queryItems = [
            URLQueryItem(name: "talker_id", value: String(talker)),
            URLQueryItem(name: "session_type", value: "1"),
            URLQueryItem(name: "size", value: "60"),
            URLQueryItem(name: "build", value: "0"),
            URLQueryItem(name: "mobi_app", value: "web")
        ]
        let root = try await requestObject(components.url!, cookie: cookie, referer: "https://message.bilibili.com/")
        let data = root["data"] as? [String: Any]
        let rows = (data?["messages"] as? [[String: Any]]) ?? []
        return rows.compactMap { row -> ChatMessage? in
            let raw = Self.text(row["content"]) ?? ""
            let text = Self.readableMessage(raw, type: Self.integer(row["msg_type"]) ?? 1)
            guard !text.isEmpty else { return nil }
            let seconds = Double(Self.integer(row["timestamp"]) ?? 0)
            return ChatMessage(
                id: Self.text(row["msg_key"] ?? row["msg_seqno"]) ?? UUID().uuidString,
                senderID: Self.integer(row["sender_uid"]) ?? 0,
                text: text,
                date: seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil)
        }.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// 回复我的 / @我 / 收到的赞 (the account "消息" feeds).
    func notices(kind: NoticeKind, cookie: String?) async throws -> [FeedNotice] {
        guard let cookie, !cookie.isEmpty else { throw APIError.unavailable }
        var components = URLComponents(string: "https://api.bilibili.com/x/msgfeed/\(kind.path)")!
        components.queryItems = [
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "build", value: "0"),
            URLQueryItem(name: "mobi_app", value: "web")
        ]
        let root = try await requestObject(components.url!, cookie: cookie, referer: "https://message.bilibili.com/")
        let data = root["data"] as? [String: Any]
        var rows = (data?["items"] as? [[String: Any]]) ?? []
        if rows.isEmpty {
            rows = ((data?["total"] as? [String: Any])?["items"] as? [[String: Any]])
                ?? ((data?["latest"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        }
        return rows.compactMap { row -> FeedNotice? in
            let item = row["item"] as? [String: Any]
            var name = "B 站用户"
            var avatar: String?
            let action: String
            let content: String
            switch kind {
            case .like:
                let users = (row["users"] as? [[String: Any]]) ?? []
                name = Self.text(users.first?["nickname"]) ?? name
                let count = Self.integer(row["counts"]) ?? users.count
                if count > 1 { name += " 等 \(count) 人" }
                avatar = Self.imageURL(Self.text(users.first?["avatar"]))
                action = "赞了我的" + Self.businessName(Self.text(item?["business"]))
                content = Self.stripHTML(Self.text(item?["title"]) ?? "")
            case .reply, .at:
                let user = row["user"] as? [String: Any]
                name = Self.text(user?["nickname"]) ?? name
                avatar = Self.imageURL(Self.text(user?["avatar"]))
                action = kind == .reply ? "回复了我" : "@了我"
                content = Self.stripHTML(Self.text(item?["source_content"] ?? item?["title"]) ?? "")
            }
            let seconds = Double(Self.integer(row["reply_time"] ?? row["at_time"] ?? row["like_time"]) ?? 0)
            return FeedNotice(
                id: Self.text(row["id"]) ?? UUID().uuidString,
                userName: name, avatarURL: avatar, action: action, content: content,
                date: seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil)
        }
    }

    private static func businessName(_ business: String?) -> String {
        switch business {
        case "reply": return "评论"
        case "archive": return "视频"
        case "dynamic": return "动态"
        default: return "内容"
        }
    }

    /// Message bodies are JSON (`{"content":"hi"}`, image, share card); show readable text.
    static func readableMessage(_ raw: String, type: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == 2 { return "[图片]" }
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return trimmed }
        if let content = object["content"] as? String, !content.isEmpty { return content }
        if let title = object["title"] as? String, !title.isEmpty { return "[分享] \(title)" }
        if object["url"] != nil, object["height"] != nil || object["width"] != nil { return "[图片]" }
        if let reply = object["reply_content"] as? String { return reply }
        return "[消息]"
    }
}

// MARK: - PiliPlus-style extras: related videos, watch later, live chat server, SponsorBlock

extension BilibiliAPI {
    func relatedVideos(bvid: String, cookie: String? = nil) async throws -> [Video] {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/archive/related")!
        components.queryItems = [URLQueryItem(name: "bvid", value: bvid)]
        let root = try await requestObject(components.url!, cookie: cookie, referer: "https://www.bilibili.com/video/\(bvid)")
        return Self.dictionaryRows(root["data"]).compactMap(Self.video)
    }

    func addToWatchLater(aid: Int, cookie: String?) async throws {
        guard aid > 0, let cookie, let csrf = Self.cookieValue("bili_jct", from: cookie), !csrf.isEmpty else {
            throw APIError.unavailable
        }
        _ = try await postFormObject(URL(string: "https://api.bilibili.com/x/v2/history/toview/add")!,
                                     fields: ["aid": "\(aid)", "csrf": csrf],
                                     cookie: cookie, referer: "https://www.bilibili.com/")
    }

    /// Token + host of the live chat websocket.
    func liveDanmakuConfig(roomID: Int, cookie: String?) async -> (token: String, host: String, port: Int, buvid: String?)? {
        let buvid = cookieStorage.cookies?.first { $0.name == "buvid3" }?.value
        var components = URLComponents(string: "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo")!
        components.queryItems = [URLQueryItem(name: "id", value: "\(roomID)"), URLQueryItem(name: "type", value: "0")]
        if let root = try? await requestObject(components.url!, cookie: cookie, referer: "https://live.bilibili.com/\(roomID)"),
           let data = root["data"] as? [String: Any], let token = Self.text(data["token"]), !token.isEmpty {
            let host = (data["host_list"] as? [[String: Any]])?.first
            return (token, Self.text(host?["host"]) ?? "broadcastlv.chat.bilibili.com", Self.integer(host?["wss_port"]) ?? 443, buvid)
        }
        var legacy = URLComponents(string: "https://api.live.bilibili.com/room/v1/Danmu/getConf")!
        legacy.queryItems = [URLQueryItem(name: "room_id", value: "\(roomID)"), URLQueryItem(name: "platform", value: "pc"),
                             URLQueryItem(name: "player", value: "web")]
        if let root = try? await requestObject(legacy.url!, cookie: cookie, referer: "https://live.bilibili.com/\(roomID)"),
           let data = root["data"] as? [String: Any], let token = Self.text(data["token"]), !token.isEmpty {
            let host = (data["host_server_list"] as? [[String: Any]])?.first
            return (token, Self.text(host?["host"]) ?? "broadcastlv.chat.bilibili.com", Self.integer(host?["wss_port"]) ?? 443, buvid)
        }
        return nil
    }

    /// SponsorBlock-style skip segments (community database, as in PiliPlus' 空降助手).
    func sponsorSegments(bvid: String) async -> [(start: Double, end: Double)] {
        var components = URLComponents(string: "https://bsbsb.top/api/skipSegments")!
        components.queryItems = [URLQueryItem(name: "videoID", value: bvid)]
            + ["sponsor", "selfpromo", "interaction"].map { URLQueryItem(name: "category", value: $0) }
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard (row["actionType"] as? String ?? "skip") == "skip",
                  let segment = row["segment"] as? [Any], segment.count == 2,
                  let start = (segment[0] as? NSNumber)?.doubleValue,
                  let end = (segment[1] as? NSNumber)?.doubleValue, end > start else { return nil }
            return (start, end)
        }
    }
}

// MARK: - Hot searches and sending danmaku

extension BilibiliAPI {
    func hotSearchKeywords() async -> [String] {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/search/square")!
        components.queryItems = [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "platform", value: "web")]
        guard let root = try? await requestObject(components.url!, referer: "https://search.bilibili.com/"),
              let data = root["data"] as? [String: Any],
              let list = (data["trending"] as? [String: Any])?["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { Self.text($0["keyword"]) }.filter { !$0.isEmpty }
    }

    /// Sends one scrolling danmaku at the given playback position.
    func postDanmaku(aid: Int, cid: Int, text: String, progressMs: Int, color: UInt32 = 0xFFFFFF,
                     mode: Int = 1, fontSize: Int = 25, cookie: String?) async throws {
        guard cid > 0, let cookie, let csrf = Self.cookieValue("bili_jct", from: cookie), !csrf.isEmpty else {
            throw APIError.unavailable
        }
        _ = try await postFormObject(URL(string: "https://api.bilibili.com/x/v2/dm/post")!, fields: [
            "type": "1", "oid": "\(cid)", "msg": text, "aid": "\(aid)",
            "progress": "\(max(0, progressMs))", "color": "\(color)", "fontsize": "\(fontSize)",
            "pool": "0", "mode": "\(mode)", "rnd": "\(Int(Date().timeIntervalSince1970 * 1_000_000))",
            "plat": "1", "csrf": csrf
        ], cookie: cookie, referer: "https://www.bilibili.com/")
    }
}
