import Foundation

/// QQ's QR flow must expose redirect responses so the app can collect the
/// account cookies and exchange the OAuth code for a Music session.
private final class QQNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// QQ Music account metadata used for optional recommendation synchronisation.
///
/// The account session is used for profile synchronisation and, when the
/// provider returns a full authorized URL, for QQ Music account playback.
actor QQMusicAPI {
    static let shared = QQMusicAPI()

    struct QRCodePayload: Sendable {
        let imageData: Data
        let qrsig: String
    }

    enum QRStatus: Sendable {
        case waiting
        case scanned
        case success(cookie: String)
        case expired
    }

    struct Profile {
        let id: String
        let name: String
        let avatarURL: String?
        /// A provider-issued session replacement, if the response rotated it.
        let refreshedCookie: String?
    }

    struct ResolvedAudio: Sendable {
        let url: URL
        let quality: String
    }

    enum APIError: LocalizedError {
        case invalidResponse
        case unavailable
        case qrCodeUnavailable
        case oauthFailed

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "QQ 音乐登录状态无法识别，请重新获取二维码"
            case .unavailable: return "QQ 音乐登录已失效或 Cookie 已过期"
            case .qrCodeUnavailable: return "QQ 当前拒绝了二维码请求，请稍后重试"
            case .oauthFailed: return "QQ 扫码成功，但音乐登录凭证获取失败，请重新扫码"
            }
        }
    }

    private let endpoint = URL(string: "https://c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg")!
    private let session: URLSession
    private let redirectSession: URLSession
    private let cookieStorage: HTTPCookieStorage
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"

    struct AccountPlaylist: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let count: Int
        let coverURL: String?
    }

    /// Whether the signed-in QQ account holds a Music membership (best effort; nil = unknown).
    func vipStatus(cookie: String) async -> Bool? {
        let fields = Self.cookieFields(cookie)
        let rawUin = fields["uin"] ?? fields["p_uin"] ?? fields["wxuin"] ?? ""
        let uin = String(rawUin.drop { !$0.isNumber })
        guard !uin.isEmpty else { return nil }
        let credential = fields["qqmusic_key"] ?? fields["qm_keyst"] ?? fields["p_skey"] ?? fields["skey"] ?? ""
        let payload: [String: Any] = [
            "comm": ["g_tk": Self.hash5381(credential), "uin": uin, "format": "json", "ct": 24, "cv": 0],
            "req": ["module": "userInfo.VipQueryServer", "method": "SRFVipQuery_V2", "param": ["uin_list": [uin]]]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var request = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = body
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let req = root["req"] as? [String: Any] else { return nil }
        let result = req["data"] ?? req
        let preview = String(data: (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
        Task { @MainActor in
            DiagnosticLogStore.shared.append(level: .info, category: "QQ 音乐", message: "会员状态", detail: String(preview.prefix(360)))
        }
        guard (Self.integer(in: req, keys: ["code"]) ?? 0) == 0 else { return nil }
        return Self.containsVIPFlag(result)
    }

    private static func containsVIPFlag(_ value: Any) -> Bool {
        let names: Set<String> = ["isvip", "is_vip", "vip", "svip", "isgreen", "green", "greenvip", "is_green_vip",
                                  "isgreenvip", "musicvip", "issvip", "is_svip", "vipflag", "vip_flag"]
        if let dictionary = value as? [String: Any] {
            for (key, item) in dictionary {
                if names.contains(key.lowercased()) {
                    if let number = item as? NSNumber, number.intValue > 0 { return true }
                    if let text = item as? String, let number = Int(text), number > 0 { return true }
                }
                if containsVIPFlag(item) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains { containsVIPFlag($0) }
        }
        return false
    }

    /// Playlists created by the signed-in QQ account (`fcg_user_created_diss`).
    func userPlaylists(cookie: String) async throws -> [AccountPlaylist] {
        var fields: [String: String] = [:]
        for part in cookie.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        let rawUin = fields["uin"] ?? fields["p_uin"] ?? fields["wxuin"] ?? ""
        let uin = rawUin.drop { !$0.isNumber }
        guard !uin.isEmpty else { throw APIError.invalidResponse }
        let credential = fields["qqmusic_key"] ?? fields["p_skey"] ?? fields["skey"] ?? ""
        // Overflow-safe: a plain Int `+=` traps on long keys and crashed the playlist page.
        let gtk = Self.hash5381(credential)

        var components = URLComponents(string: "https://c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss")!
        components.queryItems = [
            URLQueryItem(name: "cv", value: "4747474"), URLQueryItem(name: "ct", value: "24"),
            URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "inCharset", value: "utf-8"),
            URLQueryItem(name: "outCharset", value: "utf-8"), URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq.json"), URLQueryItem(name: "needNewCode", value: "1"),
            URLQueryItem(name: "uin", value: String(uin)), URLQueryItem(name: "hostuin", value: String(uin)),
            URLQueryItem(name: "sin", value: "0"), URLQueryItem(name: "size", value: "200"),
            URLQueryItem(name: "g_tk", value: String(gtk)), URLQueryItem(name: "g_tk_new_20200303", value: String(gtk)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        let list = ((root["data"] as? [String: Any])?["disslist"] as? [[String: Any]]) ?? []
        let code = String(describing: root["code"] ?? "?")
        Task { @MainActor in
            DiagnosticLogStore.shared.append(level: .info, category: "QQ 音乐", message: "账号歌单列表", detail: "code=\(code) rows=\(list.count)")
        }
        return list.compactMap { item in
            let id = (item["tid"] as? Int).map(String.init) ?? (item["tid"] as? String) ?? ""
            let name = (item["diss_name"] as? String) ?? ""
            guard !id.isEmpty, !name.isEmpty, id != "0" else { return nil }
            return AccountPlaylist(
                id: id, name: name,
                count: (item["song_cnt"] as? Int) ?? 0,
                coverURL: (item["diss_cover"] as? String).flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "http://", with: "https://") })
        }
    }

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        // A bare `HTTPCookieStorage()` silently drops every cookie on iOS; use a
        // real (group-container) storage so the ptlogin session can be kept.
        cookieStorage = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "moumusic.qqlogin")
        cookieStorage.cookieAcceptPolicy = .always
        configuration.httpCookieStorage = cookieStorage
        // Keep cookie ownership in this actor.  URLSession's automatic jar
        // handling can retain both a host-scoped qrsig and the replacement
        // .qq.com value, which makes ptqrlogin/check_sig see two signatures
        // and report a valid scan as an expired/invalid login.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)

        let redirectConfiguration = URLSessionConfiguration.ephemeral
        redirectConfiguration.httpCookieStorage = cookieStorage
        redirectConfiguration.httpShouldSetCookies = false
        redirectConfiguration.httpCookieAcceptPolicy = .never
        redirectConfiguration.timeoutIntervalForRequest = 20
        redirectConfiguration.timeoutIntervalForResource = 45
        redirectSession = URLSession(
            configuration: redirectConfiguration,
            delegate: QQNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    /// QQ Music's old `/portal/login.html` page was removed.  The supported
    /// QR route is QQ's ptlogin flow: request the image, poll ptqrlogin, then
    /// follow the returned authorization URL so the Music cookies are stored.
    func qrCode() async throws -> QRCodePayload {
        // A qrsig is single-use. Remove the previous value before requesting
        // a new image; otherwise cookie storage can send two signatures and
        // QQ may report a freshly scanned code as expired.
        for stale in cookieStorage.cookies ?? [] { cookieStorage.deleteCookie(stale) }
        deleteCookies(named: "qrsig")
        // The login page hands out pt_login_sig; ptqrlogin must echo it back as
        // login_sig, otherwise a scanned code is reported as already expired.
        if let xlogin = URL(string: "https://xui.ptlogin2.qq.com/cgi-bin/xlogin?appid=716027609&daid=383&style=33&login_text=%E7%99%BB%E5%BD%95&hide_title_bar=1&hide_border=1&target=self&s_url=https%3A%2F%2Fgraph.qq.com%2Foauth2.0%2Flogin_jump&pt_3rd_aid=100497308&theme=2&verify_theme=") {
            var loginPage = URLRequest(url: xlogin)
            loginPage.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let (_, pageResponse) = try? await redirectSession.data(for: loginPage) {
                collectCookies(from: pageResponse)
                if let sig = Self.cookieValue("pt_login_sig", from: pageResponse) {
                    setCookieValue(sig, for: "pt_login_sig")
                }
            }
        }
        var components = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrshow")!
        components.queryItems = [
            URLQueryItem(name: "appid", value: "716027609"),
            URLQueryItem(name: "e", value: "2"),
            URLQueryItem(name: "l", value: "M"),
            URLQueryItem(name: "s", value: "3"),
            URLQueryItem(name: "d", value: "72"),
            URLQueryItem(name: "v", value: "4"),
            URLQueryItem(name: "t", value: String(format: "%.6f", Double.random(in: 0...1))),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await redirectSession.data(for: request)
        // The ephemeral session normally stores Set-Cookie automatically, but
        // ptlogin may return the cookie on a response whose host differs from
        // the next polling host. Keep the response headers as the source of
        // truth so the later OAuth exchange receives the same session.
        collectCookies(from: response)
        if (response as? HTTPURLResponse)?.statusCode == 403 {
            throw APIError.qrCodeUnavailable
        }
        guard Self.isSuccess(response), let qrsig = Self.cookieValue("qrsig", from: response), !qrsig.isEmpty else {
            throw APIError.invalidResponse
        }
        // `ptqrlogin` returns the signature as a response cookie, but the
        // QR image request can be served by a different ptlogin host. Keep
        // the value in the shared cookie jar so the later `check_sig` OAuth
        // step sends the same qrsig instead of only the polling request.
        setCookieValue(qrsig, for: "qrsig")
        // QQ occasionally returns an HTML anti-bot page with HTTP 200. Never
        // pass that body to SwiftUI as a QR image, otherwise the sheet remains
        // blank with an endless spinner.
        guard Self.looksLikeImage(data) else { throw APIError.qrCodeUnavailable }
        return QRCodePayload(imageData: data, qrsig: qrsig)
    }

    func poll(qrsig: String) async throws -> QRStatus {
        // Keep the signature in the shared jar as well as on this request.
        // A reused polling task can otherwise reach check_sig without the
        // qrsig cookie and QQ reports a false login failure.
        setCookieValue(qrsig, for: "qrsig")
        var components = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrlogin")!
        components.queryItems = [
            URLQueryItem(name: "u1", value: "https://graph.qq.com/oauth2.0/login_jump"),
            URLQueryItem(name: "ptqrtoken", value: String(Self.hash33(qrsig))),
            URLQueryItem(name: "ptredirect", value: "0"),
            URLQueryItem(name: "h", value: "1"),
            URLQueryItem(name: "t", value: "1"),
            URLQueryItem(name: "g", value: "1"),
            URLQueryItem(name: "from_ui", value: "1"),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "action", value: "0-0-\(Int(Date().timeIntervalSince1970 * 1000))"),
            URLQueryItem(name: "js_ver", value: "22080914"),
            URLQueryItem(name: "js_type", value: "1"),
            URLQueryItem(name: "login_sig", value: cookieValue("pt_login_sig") ?? ""),
            URLQueryItem(name: "pt_uistyle", value: "40"),
            URLQueryItem(name: "aid", value: "716027609"),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
            // QQ's current ptlogin client sends this value when it requests
            // the third-party login jump.  Omitting it can still return a
            // valid-looking `0` callback, but the following check_sig chain
            // then ends without the skey/p_skey cookies needed by Music.
            URLQueryItem(name: "o1vId", value: "49283d5cbb01a744d46314da4608d929")
        ]
        var request = URLRequest(url: components.url!)
        var pollCookie = "qrsig=\(qrsig)"
        if let sig = cookieValue("pt_login_sig") { pollCookie += "; pt_login_sig=\(sig)" }
        request.setValue(pollCookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await redirectSession.data(for: request)
        collectCookies(from: response)
        guard Self.isSuccess(response), let body = String(data: data, encoding: .utf8) else {
            throw APIError.invalidResponse
        }

        guard let parsed = Self.parsePTUI(body) else { throw APIError.invalidResponse }
        let status = parsed.code
        if status != "66" {
            let preview = String(body.prefix(160))
            Task { @MainActor in
                DiagnosticLogStore.shared.append(level: .info, category: "QQ 音乐登录", message: "扫码状态 \(status)", detail: preview)
            }
        }
        switch status {
        case "66": return .waiting
        case "67": return .scanned
        // QQ uses 65 for the normal timeout and 68 when the QR token is
        // invalidated/replaced (for example after a second refresh). Both
        // states must clear the polling generation and create a new image;
        // treating 68 as waiting leaves the sheet stuck on an old QR code.
        case "65", "68": return .expired
        case "0":
            guard let jumpURL = parsed.url else {
                Self.oauthLog("ptui 缺少跳转地址", String(body.prefix(240)))
                throw APIError.oauthFailed
            }
            do {
                try await completeOAuth(redirectURL: jumpURL)
            } catch {
                Self.oauthLog("completeOAuth 抛出错误", "\(error) | \(error.localizedDescription)")
                throw error
            }
            let cookie = cookieHeader()
            guard !cookie.isEmpty else { throw APIError.unavailable }
            return .success(cookie: cookie)
        default:
            return .waiting
        }
    }

    /// Finish QQ's QR authorization and exchange the OAuth code for a Music
    /// session key. QQ's `login_jump` response is a redirect chain: every
    /// response can add another `skey`/`p_skey` cookie, so parsing only the
    /// first URL and calling a hard-coded `check_sig` endpoint loses the
    /// session that the Music API needs.
    private func completeOAuth(redirectURL: URL) async throws {
        var currentURL = redirectURL

        // The redirect delegate intentionally exposes each response. Do not
        // replace this with URLSession's automatic redirect handling: the
        // intermediate Set-Cookie headers are part of the QQ login session.
        for _ in 0..<6 {
            var request = URLRequest(url: currentURL)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
            // check_sig needs every ptlogin cookie from the poll response
            // (supertoken, pt_oauth_token, ...), not only the account keys.
            request.setValue(fullCookieHeader(), forHTTPHeaderField: "Cookie")
            let (_, response) = try await redirectSession.data(for: request)
            collectCookies(from: response)
            if let h = response as? HTTPURLResponse {
                Self.oauthLog("check_sig 跳转", "host=\(currentURL.host ?? "-") http=\(h.statusCode) setcookie=\((h.allHeaderFields["Set-Cookie"] as? String ?? "").split(separator: ",").compactMap { $0.split(separator: "=").first.map { String($0).trimmingCharacters(in: .whitespaces) } }.filter { !$0.contains(" ") }.joined(separator: "/")) sent=\(fullCookieHeader().split(separator: ";").count) next=\(h.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0)?.host } ?? "-")")
            }

            guard let http = response as? HTTPURLResponse,
                  (300...399).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  !location.isEmpty else { break }

            if let absolute = URL(string: location), absolute.scheme != nil {
                currentURL = absolute
            } else if let resolved = URL(string: location, relativeTo: currentURL) {
                currentURL = resolved
            } else {
                break
            }
        }

        let credential = cookieValue("qqmusic_key")
            ?? cookieValue("p_skey")
            ?? cookieValue("skey")
            ?? ""
        Self.oauthLog("check_sig 完成", "credential=\(credential.isEmpty ? "无" : "有") cookies=\(cookieHeader(includeQRSig: true).split(separator: ";").compactMap { $0.split(separator: "=").first.map { String($0).trimmingCharacters(in: .whitespaces) } }.joined(separator: ","))")
        guard !credential.isEmpty else { throw APIError.oauthFailed }

        // The web player's own authorize call uses the get_user_info scope; the
        // broader "all" scope is kept as a fallback because graph.qq.com
        // answers error=100035 for parameter sets it does not accept.
        let variants: [(scope: String, openapi: String)] = [
            ("get_user_info,get_app_friends", "1010_1030"),
            ("get_user_info,get_app_friends", "80901010_1030"),
            ("all", "80901010_1030")
        ]
        var foundCode: String?
        for variant in variants {
            let fields: [String: String] = [
                "response_type": "code",
                "client_id": "100497308",
                "redirect_uri": "https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/",
                "scope": variant.scope,
                "state": "state",
                "switch": "",
                "from_ptlogin": "1",
                "src": "1",
                "update_auth": "1",
                "openapi": variant.openapi,
                "g_tk": String(Self.hash5381(credential)),
                "auth_time": String(Int(Date().timeIntervalSince1970 * 1000)),
                "ui": "DFEC5395-9E69-4D3E-96A6-300BB770874D"
            ]

            var authRequest = URLRequest(url: URL(string: "https://graph.qq.com/oauth2.0/authorize")!)
            authRequest.httpMethod = "POST"
            authRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            authRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            authRequest.setValue("https://graph.qq.com/oauth2.0/show?which=Login&display=pc&client_id=100497308", forHTTPHeaderField: "Referer")
            authRequest.setValue("https://graph.qq.com", forHTTPHeaderField: "Origin")
            authRequest.setValue(fullCookieHeader(), forHTTPHeaderField: "Cookie")
            authRequest.httpBody = Self.formEncode(fields).data(using: .utf8)
            let (authData, authResponse) = try await redirectSession.data(for: authRequest)
            collectCookies(from: authResponse)

            let authStatus = (authResponse as? HTTPURLResponse)?.statusCode ?? -1
            let authLocation = ((authResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? "").components(separatedBy: "code=").first ?? ""
            if let authHTTP = authResponse as? HTTPURLResponse,
               let code = Self.extractCode(from: authData, response: authHTTP), !code.isEmpty {
                foundCode = code
                Self.oauthLog("authorize 成功", "scope=\(variant.scope) openapi=\(variant.openapi)")
                break
            }
            Self.oauthLog("authorize 未取得 code", "scope=\(variant.scope) openapi=\(variant.openapi) http=\(authStatus) location=\(authLocation) body=\(String(data: authData.prefix(160), encoding: .utf8) ?? "")")
        }
        guard let code = foundCode else { throw APIError.oauthFailed }
        let loginPayload: [String: Any] = [
            // Match the current QQ Music web-client envelope. The older
            // tmeLoginType form can return HTTP 200 without issuing a
            // musickey/uin, which leaves the app showing “凭证获取失败”.
            "comm": ["g_tk": 5381, "platform": "yqq", "ct": 24, "cv": 0],
            "req": [
                "module": "QQConnectLogin.LoginServer",
                "method": "QQLogin",
                "param": ["code": code]
            ]
        ]
        var loginRequest = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        loginRequest.httpMethod = "POST"
        loginRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        loginRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        loginRequest.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        loginRequest.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        loginRequest.httpBody = try JSONSerialization.data(withJSONObject: loginPayload)
        let (loginData, loginResponse) = try await session.data(for: loginRequest)
        collectCookies(from: loginResponse)

        guard Self.isSuccess(loginResponse) else {
            Self.oauthLog("musicu 登录 HTTP 失败", "http=\((loginResponse as? HTTPURLResponse)?.statusCode ?? -1)")
            throw APIError.oauthFailed
        }
        guard let root = try? JSONSerialization.jsonObject(with: loginData) as? [String: Any] else {
            Self.oauthLog("musicu 响应不是 JSON", "")
            throw APIError.oauthFailed
        }
        do {
            let req = root["req"] as? [String: Any]
            let dataKeys = ((req?["data"] as? [String: Any]) ?? [:]).keys.sorted().joined(separator: ",")
            Self.oauthLog("musicu 登录响应", "top=\(root.keys.sorted().joined(separator: ",")) req.code=\(String(describing: req?["code"] ?? "-")) data=\(dataKeys)")
        }

        let responseContainers: [[String: Any]] = [
            (root["req"] as? [String: Any])?["data"] as? [String: Any],
            (root["req_0"] as? [String: Any])?["data"] as? [String: Any],
            root["data"] as? [String: Any]
        ].compactMap { $0 }

        if let codeValue = Self.firstInteger(in: root, containers: ["req", "req_0"], keys: ["code", "ret"]),
           codeValue != 0 {
            throw APIError.oauthFailed
        }

        for data in responseContainers {
            if let musicKey = Self.text(data["musickey"]), !musicKey.isEmpty {
                setCookieValue(musicKey, for: "musickey")
                setCookieValue(musicKey, for: "qm_keyst")
                setCookieValue(musicKey, for: "qqmusic_key")
            }
            if let musicID = Self.text(data["musicid"]), !musicID.isEmpty {
                setCookieValue(musicID, for: "uin")
            }
        }

        // The response shape has changed between QQ Music web clients.  Some
        // builds put `musickey` below an extra `data/result` wrapper instead
        // of req.data.  Walk the already decoded response as a fallback so a
        // successful QR scan is not reported as “credential acquisition
        // failed” only because the wrapper changed.
        var nestedMusicKey: String?
        var nestedMusicID: String?
        func collectCredentials(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    switch key.lowercased() {
                    case "musickey", "qm_keyst", "qqmusic_key", "music_key":
                        if nestedMusicKey == nil, let value = Self.text(child), !value.isEmpty {
                            nestedMusicKey = value
                        }
                    case "musicid", "uin", "loginuin", "qqmusic_uin":
                        if nestedMusicID == nil,
                           let value = Self.text(child),
                           Self.isUsableAccountID(value) {
                            nestedMusicID = value
                        }
                    default:
                        break
                    }
                    collectCredentials(child)
                }
            } else if let array = value as? [Any] {
                array.forEach(collectCredentials)
            }
        }
        collectCredentials(root)
        if let nestedMusicKey, !nestedMusicKey.isEmpty {
            setCookieValue(nestedMusicKey, for: "musickey")
            setCookieValue(nestedMusicKey, for: "qm_keyst")
            setCookieValue(nestedMusicKey, for: "qqmusic_key")
        }
        if let nestedMusicID, !nestedMusicID.isEmpty {
            setCookieValue(nestedMusicID, for: "uin")
        }

        guard Self.hasMusicCredential(Self.cookieFields(cookieHeader())) else {
            throw APIError.oauthFailed
        }
    }

    /// Resolve an authorized QQ Music URL through the account session. A
    /// missing/paid URL is reported to the caller so automatic playback can
    /// fall back to enabled LX sources instead of playing a preview segment.
    func musicURL(songMid: String, mediaMid: String?, quality: String,
                  cookie: String) async throws -> ResolvedAudio {
        let fields = Self.cookieFields(cookie)
        let uin = fields["qqmusic_uin"] ?? fields["uin"] ?? "0"
        let guid = String(Int.random(in: 100_000_000...2_000_000_000))
        let fileID = mediaMid?.isEmpty == false ? mediaMid! : songMid
        let file = Self.filename(for: quality, mediaMid: fileID)
        let requestBody: [String: Any] = [
            "comm": [
                "cv": 4747474,
                "ct": 24,
                "format": "json",
                "inCharset": "utf-8",
                "outCharset": "utf-8",
                "notice": 0,
                "platform": "yqq.json",
                "needNewCode": 1,
                "uin": Int(uin) ?? 0
            ],
            "req_1": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": [
                    "filename": [file],
                    "guid": guid,
                    "songmid": [songMid],
                    "songtype": [0],
                    "uin": uin,
                    "loginflag": 1,
                    "platform": "20"
                ]
            ]
        ]
        let endpoint = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        let container = (root["req_1"] as? [String: Any])
            ?? (root["req_0"] as? [String: Any])
        let payload = container?["data"] as? [String: Any]
        let info = (payload?["midurlinfo"] as? [[String: Any]])?.first
        guard let path = Self.text(info?["purl"]), !path.isEmpty else {
            throw APIError.unavailable
        }
        let rawURL: String
        if let absolute = URL(string: path), absolute.scheme != nil {
            rawURL = path
        } else if let host = (payload?["sip"] as? [String])?.first, !host.isEmpty {
            rawURL = host + path
        } else {
            throw APIError.unavailable
        }
        guard let url = URL(string: rawURL.replacingOccurrences(of: "http://", with: "https://")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw APIError.unavailable
        }
        // The requested filename is only a request. If QQ omits the returned
        // filename, there is no evidence that the server honoured it.
        let returnedQuality = Self.text(info?["filename"])
            .map { Self.quality(forFilename: $0) } ?? "unknown"
        return ResolvedAudio(url: url, quality: returnedQuality)
    }

    func profile(cookie: String) async throws -> Profile {
        let cookieFields = Self.cookieFields(cookie)
        guard Self.hasMusicCredential(cookieFields) else {
            throw APIError.unavailable
        }

        let accountID = Self.accountID(from: cookieFields)
        guard !accountID.isEmpty else {
            throw APIError.unavailable
        }

        // The old endpoint accepts the request only with the same identity
        // parameters used by QQ Music's web client.  A bare request often
        // returns {code: 1000, data: {}} even for a valid session.
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "cid", value: "205360838"),
            URLQueryItem(name: "userid", value: accountID),
            URLQueryItem(name: "reqfrom", value: "1"),
            // The profile endpoint follows the web client's fixed public
            // g_tk value. Hashing a rotated credential here makes a valid
            // session look like an empty profile on some QQ accounts.
            URLQueryItem(name: "g_tk", value: "5381"),
            URLQueryItem(name: "loginUin", value: accountID),
            URLQueryItem(name: "hostUin", value: "0"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq.json"),
            URLQueryItem(name: "needNewCode", value: "0")
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        collectCookies(from: response)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
               let object = Self.jsonObject(from: data) else {
            throw APIError.invalidResponse
        }

        // code 1000 is returned when this legacy profile endpoint is
        // unavailable.  It does not invalidate a cookie that already has a
        // QQ Music credential; Beans uses the same fallback behaviour.
        if let code = Self.integer(in: object, keys: ["code"]), code != 0 && code != 1000 {
            throw APIError.unavailable
        }

        let dataObject = object["data"] as? [String: Any] ?? object
        let info = ((dataObject["mymusic"] as? [String: Any])?["info"] as? [String: Any])
            ?? (dataObject["info"] as? [String: Any])
            ?? dataObject["user"] as? [String: Any]
            ?? dataObject["profile"] as? [String: Any]
            ?? dataObject
        let id = Self.text(in: info, keys: ["uin", "uid", "user_id", "loginUin"]) ?? accountID
        let name = Self.text(in: info, keys: ["nick", "nickname", "name", "nickName"])
            ?? "QQ 音乐用户 \(Self.normalizedAccountID(accountID))"
        let avatar = Self.text(in: info, keys: ["logo", "avatar", "avatarUrl", "avatar_url"])
        return Profile(id: id, name: name, avatarURL: avatar,
                       refreshedCookie: Self.mergedCookie(
                        original: cookie,
                        response: response as? HTTPURLResponse
                       ))
    }

    private static func jsonObject(from data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        return try? JSONSerialization.jsonObject(
            with: Data(text[start...end].utf8)
        ) as? [String: Any]
    }

    private static func text(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func integer(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = object[key] as? String, let number = Int(value) { return number }
        }
        return nil
    }

    private static func isSuccess(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
    }

    private static func cookieValue(_ name: String, from response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        for (key, value) in http.allHeaderFields {
            guard String(describing: key).lowercased() == "set-cookie" else { continue }
            let text = String(describing: value)
            for item in text.split(separator: ",") {
                let pair = item.split(separator: ";", maxSplits: 1).first ?? ""
                let fields = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces) == name {
                    return fields[1]
                }
            }
        }
        return nil
    }

    private static func firstInteger(
        in object: [String: Any],
        containers: [String],
        keys: [String]
    ) -> Int? {
        for container in containers {
            if let nested = object[container] as? [String: Any],
               let value = integer(in: nested, keys: keys) {
                return value
            }
        }
        return integer(in: object, keys: keys)
    }

    private static func accountID(from fields: [String: String]) -> String {
        for key in ["uin", "p_uin", "pt2gguin", "qqmusic_uin", "loginUin"] {
            guard let value = fields[key], isUsableAccountID(value) else { continue }
            return normalizedAccountID(value)
        }
        return ""
    }

    private static func normalizedAccountID(_ value: String) -> String {
        value.hasPrefix("o") ? String(value.dropFirst()) : value
    }

    private static func isUsableAccountID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = normalizedAccountID(trimmed)
        return normalized != "0"
            && normalized.lowercased() != "null"
            && normalized.lowercased() != "undefined"
    }

    private static func credentialKey(in fields: [String: String]) -> String {
        for key in ["qqmusic_key", "qm_keyst", "musickey", "music_key", "p_skey", "skey",
                    "psrf_access_token", "psrf_qq_access_token"] {
            if let value = fields[key], !value.isEmpty { return value }
        }
        return ""
    }

    private static func hasMusicCredential(_ fields: [String: String]) -> Bool {
        ["qqmusic_key", "qm_keyst", "musickey", "music_key", "p_skey", "skey", "wxskey", "wx_skey",
         "psrf_access_token", "psrf_qq_access_token"]
            .contains { key in
                guard let value = fields[key] else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    private static func text(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func parsePTUI(_ body: String) -> (code: String, url: URL?)? {
        let fields = callbackFields(body)
        guard fields.count >= 3, let code = fields.first else { return nil }
        let candidate = fields.dropFirst().first(where: { $0.hasPrefix("http") })
        return (code, candidate.flatMap(URL.init(string:)))
    }

    private static func extractCode(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }

    /// `graph.qq.com` normally returns the OAuth code in a 302 Location
    /// header. Some edge nodes answer with a 200 HTML page containing the
    /// same redirect URL instead. Accept both forms, but never treat an
    /// arbitrary response body as a credential.
    private static func extractCode(from data: Data, response: HTTPURLResponse) -> String? {
        if let location = response.value(forHTTPHeaderField: "Location"),
           let code = extractCode(from: location),
           !code.isEmpty {
            return code
        }

        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else { return nil }
        let candidates = [body, body.replacingOccurrences(of: "&amp;", with: "&")]
        for candidate in candidates {
            if let match = candidate.range(of: #"(?:[?&])code=([^&#\"'\s<>]+)"#, options: .regularExpression) {
                let fragment = String(candidate[match])
                let value = fragment
                    .split(separator: "=", maxSplits: 1)
                    .dropFirst()
                    .first.map(String.init) ?? ""
                if let decoded = value.removingPercentEncoding, !decoded.isEmpty {
                    return decoded
                }
            }
        }
        return nil
    }

    private static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
    }

    private static func looksLikeImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        return bytes.count >= 12 && Array(bytes[0...3]) == [0x52, 0x49, 0x46, 0x46]
            && Array(bytes[8...11]) == [0x57, 0x45, 0x42, 0x50]
    }

    private static func callbackFields(_ body: String) -> [String] {
        guard let start = body.firstIndex(of: "("),
              let end = body.lastIndex(of: ")"), start < end else { return [] }
        let payload = body[body.index(after: start)..<end]
        return payload.split(separator: ",", omittingEmptySubsequences: false).map { value in
            var item = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if item.hasPrefix("'") && item.hasSuffix("'") && item.count >= 2 {
                item.removeFirst()
                item.removeLast()
            } else if item.hasPrefix("\"") && item.hasSuffix("\"") && item.count >= 2 {
                item.removeFirst()
                item.removeLast()
            }
            return item
                .replacingOccurrences(of: "\\'", with: "'")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
    }

    private static func hash33(_ value: String) -> Int {
        var result: Double = 0
        for unit in value.utf16 {
            result += Double(toInt32Shift(result)) + Double(unit)
        }
        return Int(toInt32(result) & 0x7FFF_FFFF)
    }

    private static func oauthLog(_ message: String, _ detail: String) {
        Task { @MainActor in
            DiagnosticLogStore.shared.append(level: .warning, category: "QQ 音乐登录", message: message, detail: detail)
        }
    }

    private static func hash5381(_ value: String) -> Int {
        var result: Double = 5381
        for unit in value.utf16 {
            result += Double(toInt32Shift(result)) + Double(unit)
        }
        return Int(toInt32(result) & 0x7FFF_FFFF)
    }

    private static func toInt32Shift(_ value: Double) -> Int32 {
        Int32(bitPattern: toUInt32(value) &* 32)
    }

    private static func toInt32(_ value: Double) -> Int32 {
        Int32(bitPattern: toUInt32(value))
    }

    private static func toUInt32(_ value: Double) -> UInt32 {
        var remainder = value.truncatingRemainder(dividingBy: 4_294_967_296)
        if remainder < 0 { remainder += 4_294_967_296 }
        return UInt32(remainder)
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

    private func cookieValue(_ name: String) -> String? {
        let candidates = cookieStorage.cookies?.filter { $0.name == name } ?? []
        return candidates.sorted { lhs, rhs in
            // Prefer the broad QQ-domain value because the flow crosses from
            // ptlogin2.qq.com to graph.qq.com and y.qq.com.
            let lhsBroad = Self.isBroadQQDomain(lhs.domain)
            let rhsBroad = Self.isBroadQQDomain(rhs.domain)
            if lhsBroad != rhsBroad { return lhsBroad }
            if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }
            return lhs.domain.count < rhs.domain.count
        }.first?.value
    }

    private func setCookieValue(_ value: String, for name: String) {
        deleteCookies(named: name)
        guard let cookie = HTTPCookie(properties: [
            .domain: ".qq.com",
            .path: "/",
            .name: name,
            .value: value
        ]) else { return }
        cookieStorage.setCookie(cookie)
    }

    private func fullCookieHeader() -> String {
        var byName: [String: HTTPCookie] = [:]
        for cookie in cookieStorage.cookies ?? [] {
            if let current = byName[cookie.name], !Self.preferCookie(cookie, over: current) { continue }
            byName[cookie.name] = cookie
        }
        return byName.values.map { "\($0.name)=\($0.value)" }.sorted().joined(separator: "; ")
    }

    private func cookieHeader(includeQRSig: Bool = false) -> String {
        let allowed = Set([
            // Keep the same identity/credential set as the QQ web client.
            // In particular, `skey` is the credential returned by some
            // check_sig variants; dropping it here makes graph.qq.com reject
            // an otherwise successful QR scan.
            "uin", "wxuin", "p_uin", "wxopenid", "skey", "p_skey",
            "pt2gguin", "pt4_token", "qqmusic_uin", "qqmusic_key", "qm_keyst",
            "music_key", "wxskey", "wx_skey", "musickey", "musicid", "loginUin",
            "pskey", "pt_login_sig", "pt4_aid", "ptnick", "nick", "nickname",
            "psrf_access_token", "psrf_qq_access_token", "psrf_qqopenid"
        ])
        var selected: [String: HTTPCookie] = [:]
        for cookie in cookieStorage.cookies ?? [] where allowed.contains(cookie.name) {
            guard let current = selected[cookie.name] else {
                selected[cookie.name] = cookie
                continue
            }
            if Self.preferCookie(cookie, over: current) {
                selected[cookie.name] = cookie
            }
        }
        var pairs = selected.values.map { "\($0.name)=\($0.value)" }
        if includeQRSig, let qrsig = cookieValue("qrsig"), !qrsig.isEmpty {
            pairs.insert("qrsig=\(qrsig)", at: 0)
        }
        return pairs
            .sorted()
            .joined(separator: "; ")
    }

    private func deleteCookies(named name: String) {
        for cookie in cookieStorage.cookies ?? [] where cookie.name == name {
            cookieStorage.deleteCookie(cookie)
        }
    }

    private static func isBroadQQDomain(_ domain: String) -> Bool {
        domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "qq.com"
    }

    private static func preferCookie(_ candidate: HTTPCookie, over current: HTTPCookie) -> Bool {
        let candidateBroad = isBroadQQDomain(candidate.domain)
        let currentBroad = isBroadQQDomain(current.domain)
        if candidateBroad != currentBroad { return candidateBroad }
        if candidate.path.count != current.path.count { return candidate.path.count > current.path.count }
        return candidate.domain.count < current.domain.count
    }

    private static func mergedCookie(original: String, response: HTTPURLResponse?) -> String? {
        guard let response,
              let header = response.allHeaderFields.first(where: {
                  String(describing: $0.key).lowercased() == "set-cookie"
              })?.value else { return nil }
        var values = cookieFields(original)
        let text = String(describing: header)
        for part in text.split(separator: ",") {
            let pair = part.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            let fields = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if fields.count == 2 { values[fields[0].trimmingCharacters(in: .whitespaces)] = fields[1] }
        }
        return values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private static func cookieFields(_ cookie: String) -> [String: String] {
        cookie.split(separator: ";").reduce(into: [String: String]()) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1]
        }
    }

    private static func filename(for quality: String, mediaMid: String) -> String {
        switch quality.lowercased() {
        case "master", "atmos", "dolby", "surround", "hires", "flac", "lossless":
            return "F000\(mediaMid).flac"
        case "exhigh", "higher", "320k", "320":
            return "M800\(mediaMid).mp3"
        default:
            return "M500\(mediaMid).mp3"
        }
    }

    private static func quality(forFilename filename: String) -> String {
        let value = filename.uppercased()
        if value.hasPrefix("F000") { return "flac" }
        if value.hasPrefix("M800") { return "320k" }
        if value.hasPrefix("C600") { return "192k" }
        if value.hasPrefix("M500") { return "128k" }
        return "unknown"
    }
}
