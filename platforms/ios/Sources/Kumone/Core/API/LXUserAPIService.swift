#if os(iOS)
import CommonCrypto
import Combine
import Foundation
import JavaScriptCore
import Security

/// iOS counterpart of LX Mobile's QuickJS bridge.  The provider script stays
/// user supplied; this class only implements the LX 2.0 host protocol.
@MainActor
final class LXUserAPIService: ObservableObject {
    struct ResolvedURL {
        let url: URL
        let quality: String
    }

    struct ResolvedLyrics {
        let lyric: String
        let tlyric: String?
        let rlyric: String?
        let lxlyric: String?
        let yrc: String?
    }

    struct SourceCheckResult: Equatable {
        enum Status: Equatable {
            case available
            case unavailable
        }

        let status: Status
        let message: String
        let detail: String?

        var isAvailable: Bool { status == .available }
    }

    static let shared = LXUserAPIService()

    private let session: URLSession
    private var context: JSContext?
    private var key = ""
    private var loadedID: String?
    private var tasks: [String: URLSessionDataTask] = [:]
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var sourceInitializationTask: Task<Void, Never>?
    private var pendingInitializationID: String?
    @Published private(set) var capabilities: [String: [String]] = [:]
    @Published private(set) var qualityCapabilities: [String: [String]] = [:]
    @Published private(set) var statusMessage = "未加载音源"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func loadSelectedSource() {
        load(LXSourceStore.shared.selectedSource)
    }

    /// Load a provider only when a request actually needs one.  A user's
    /// imported JavaScript must not be evaluated while the app scene is
    /// launching.
    func ensureSelectedSourceLoaded() {
        let selectedID = LXSourceStore.shared.selectedID
        guard loadedID != selectedID else { return }
        loadSelectedSource()
    }

    func load(_ source: LXSourceStore.Source?) {
        sourceInitializationTask?.cancel()
        sourceInitializationTask = nil
        pendingInitializationID = source?.id
        context = nil
        loadedID = source?.id
        capabilities = [:]
        qualityCapabilities = [:]
        statusMessage = source == nil ? "未选择音源" : "正在加载音源"
        guard let source,
              let preloadURL = Bundle.module.url(forResource: "LXUserAPIPreload", withExtension: "js"),
              let preload = try? String(contentsOf: preloadURL, encoding: .utf8) else {
            pendingInitializationID = nil
            statusMessage = "LX 预加载桥接文件不存在"
            return
        }

        let js = JSContext()
        js?.exceptionHandler = { _, exception in
            if let exception { print("[LX] JavaScript error: \(exception)") }
        }
        context = js
        key = UUID().uuidString
        installHostFunctions(in: js!)
        js?.evaluateScript(preload)
        if let exception = js?.exception {
            context = nil
            pendingInitializationID = nil
            statusMessage = "LX 桥接加载失败：\(exception.toString())"
            return
        }
        let setup = js?.objectForKeyedSubscript("lx_setup")
        setup?.call(withArguments: [key, source.id, source.name, source.description,
                                    source.version, source.author, source.homepage, source.script])
        if let exception = js?.exception {
            context = nil
            pendingInitializationID = nil
            statusMessage = "LX 音源初始化失败：\(exception.toString())"
            return
        }
        _ = js?.evaluateScript(source.script)
        if let exception = js?.exception {
            context = nil
            pendingInitializationID = nil
            statusMessage = "LX 音源脚本错误：\(exception.toString())"
            print("[LX] failed to load source \(source.name): \(exception)")
        }
        if context != nil {
            scheduleInitializationFallback(for: source.id)
        }
    }

    func resolveMusicURL(for track: Track, quality: String) async throws -> ResolvedURL {
        ensureSelectedSourceLoaded()
        await waitForSourceReady()
        guard context != nil else { throw LXError.noSource }
        guard capabilities.values.contains(where: { $0.contains("musicUrl") }) else {
            throw LXError.sourceUnavailable(statusMessage)
        }
        let primarySource = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var failures: [String] = []

        for platform in sourceCandidates(for: track, action: "musicUrl") {
            let platformName = LXCatalogPlatform(rawValue: platform)?.displayName ?? platform
            let requestTrack: Track
            if platform == primarySource {
                requestTrack = track
            } else {
                // IDs are platform-specific. A Kuwo RID cannot be sent to a
                // Kugou/QQ/NetEase source, so look up a matching result first.
                guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else {
                    failures.append("\(platformName)：找不到对应歌曲")
                    continue
                }
                requestTrack = matched
            }

            let supportedQualitys = supportedQualityNames(for: requestTrack, platform: platform)
            let requestedQuality = Self.lxQuality(for: quality,
                                                  supported: supportedQualitys.isEmpty ? ["128k"] : supportedQualitys)
            do {
                let response = try await request(source: platform, action: "musicUrl",
                                                 info: ["type": requestedQuality,
                                                        "musicInfo": musicInfo(for: requestTrack,
                                                                                platform: platform,
                                                                                qualities: supportedQualitys)])
                guard let data = response["data"] as? [String: Any],
                      let rawURL = data["url"] as? String,
                      let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    failures.append("\(platformName)：没有返回有效播放地址")
                    continue
                }
                let actualQuality = Self.resolvedQuality(
                    returned: (data["type"] as? String)
                        ?? (data["quality"] as? String)
                        ?? (data["format"] as? String),
                    requested: requestedQuality,
                    available: supportedQualitys.isEmpty ? ["128k"] : supportedQualitys
                )
                return ResolvedURL(url: url, quality: actualQuality)
            } catch {
                failures.append("\(platformName)：\(error.localizedDescription)")
            }
        }
        throw LXError.resolveFailed(failures.isEmpty
            ? ["当前音源没有可用的 musicUrl 平台"]
            : failures)
    }

    /// Performs a real, read-only musicUrl request against the selected LX
    /// source. The test metadata is bundled locally so health checks never
    /// call a built-in music-platform catalogue endpoint.
    func checkSelectedSource() async -> SourceCheckResult {
        ensureSelectedSourceLoaded()
        await waitForSourceReady()
        guard LXSourceStore.shared.selectedSource != nil else {
            return SourceCheckResult(status: .unavailable,
                                     message: "未选择音源",
                                     detail: "请先导入并启用一个 LX User API 音源。")
        }
        guard context != nil else {
            return SourceCheckResult(status: .unavailable,
                                     message: "音源脚本加载失败",
                                     detail: statusMessage)
        }

        let platformOrder = ["wy", "kw", "kg", "tx", "mg"]
        let supportedPlatforms = platformOrder.filter {
            capabilities[$0]?.contains("musicUrl") == true
        }
        guard !supportedPlatforms.isEmpty else {
            let detail = capabilities.isEmpty
                ? "脚本没有返回平台能力。"
                : "脚本已加载，但没有提供 musicUrl 接口。"
            return SourceCheckResult(status: .unavailable,
                                     message: "没有可用的播放接口",
                                     detail: detail)
        }

        var failures: [String] = []
        for platform in supportedPlatforms {
            let platformName = LXCatalogPlatform(rawValue: platform)?.displayName ?? platform
            let track: Track
            if let current = PlayerService.shared.currentTrack, current.source == platform {
                track = current
            } else {
                let catalogPlatform = LXCatalogPlatform(rawValue: platform)
                let result: [Track]?
                if let catalogPlatform {
                    result = try? await LXCatalogService.search("周杰伦 晴天", platform: catalogPlatform,
                                                               page: 1, limit: 1)
                } else {
                    result = nil
                }
                track = result?.first ?? sourceCheckTrack(for: platform)
            }

            let supportedQualitys = supportedQualityNames(for: track, platform: platform)
            let requestedQuality = Self.lxQuality(
                for: SettingsManager.shared.audioQuality.rawValue,
                supported: supportedQualitys.isEmpty ? ["128k"] : supportedQualitys
            )
            let info = musicInfo(for: track, platform: platform, qualities: supportedQualitys)
            do {
                let response = try await request(source: platform, action: "musicUrl",
                                                 info: ["type": requestedQuality, "musicInfo": info])
                guard let data = response["data"] as? [String: Any],
                      let rawURL = data["url"] as? String,
                      let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    failures.append("\(platformName)：没有返回有效播放地址")
                    continue
                }

                let actualQuality = Self.resolvedQuality(
                    returned: (data["type"] as? String)
                        ?? (data["quality"] as? String)
                        ?? (data["format"] as? String),
                    requested: requestedQuality,
                    available: supportedQualitys.isEmpty ? ["128k"] : supportedQualitys
                )
                let detail = "已通过 \(platformName) 的 musicUrl 接口，音质：\(actualQuality)"
                let result = SourceCheckResult(status: .available,
                                               message: "音源可用",
                                               detail: detail)
                statusMessage = "\(result.message)：\(detail)"
                return result
            } catch {
                failures.append("\(platformName)：\(error.localizedDescription)")
            }
        }

        let detail = failures.isEmpty ? "音源没有返回可播放地址。" : failures.joined(separator: "；")
        let result = SourceCheckResult(status: .unavailable,
                                       message: "音源不可用",
                                       detail: detail)
        statusMessage = "\(result.message)：\(detail)"
        return result
    }

    func resolveLyrics(for track: Track) async throws -> ResolvedLyrics {
        ensureSelectedSourceLoaded()
        await waitForSourceReady()
        guard context != nil else { throw LXError.noSource }
        let primarySource = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        for platform in sourceCandidates(for: track, action: "lyric") {
            guard capabilities[platform]?.contains("lyric") == true else { continue }
            let requestTrack: Track
            if platform == primarySource {
                requestTrack = track
            } else {
                guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else { continue }
                requestTrack = matched
            }
            for attempt in 0..<2 {
                guard let response = try? await request(source: platform, action: "lyric",
                                                        info: ["type": "lyric", "musicInfo": musicInfo(for: requestTrack, platform: platform)]),
                      let lyrics = await lyricPayload(from: response) else {
                    if attempt == 0 { try? await Task.sleep(for: .milliseconds(350)) }
                    continue
                }
                return lyrics
            }
        }
        throw LXError.resolveFailed([])
    }

    /// LX source scripts do not all return the same lyric shape. In the wild
    /// `data` may be a string, an object with `lyric`/`lrc`, or an object that
    /// points to a separate LRC URL. Accept all of those forms so Kuwo,
    /// Kugou, QQ and Migu sources are not incorrectly reported as lyric-less.
    private func lyricPayload(from response: [String: Any]) async -> ResolvedLyrics? {
        let raw = response["data"]
        let object = raw as? [String: Any]
        var lyric = raw as? String
        var tlyric: String?
        var rlyric: String?
        var lxlyric: String?
        var yrc: String?

        if let object {
            func text(_ keys: [String]) -> String? {
                for key in keys {
                    if let value = object[key] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
                    if let nested = object[key] as? [String: Any],
                       let value = nested["lyric"] as? String { return value }
                }
                return nil
            }
            lyric = text(["lyric", "lrc", "lyricText", "content", "text"])
            tlyric = text(["tlyric", "translation", "translatedLyric"])
            rlyric = text(["rlyric", "romalrc", "romaji"])
            lxlyric = text(["lxlyric"])
            yrc = text(["yrc", "verbatim", "wordLyric"])

            if lyric == nil,
               let urlString = text(["lrcUrl", "lyricUrl", "url"]),
               let url = URL(string: urlString),
               let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
                lyric = String(data: data, encoding: .utf8)
            }
        }

        guard let lyric = lyric ?? yrc,
              !lyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ResolvedLyrics(lyric: lyric, tlyric: tlyric, rlyric: rlyric,
                              lxlyric: lxlyric, yrc: yrc)
    }

    enum LXError: LocalizedError {
        case noSource
        case resolveFailed([String])
        case sourceUnavailable(String)
        case requestTimedOut
        case javascript(String)

        var errorDescription: String? {
            switch self {
            case .noSource: return "请先在“设置 → LX 音源”中导入并启用音源"
            case .resolveFailed(let failures):
                guard !failures.isEmpty else { return "LX 音源没有返回可播放地址" }
                return failures.prefix(2).joined(separator: "；")
            case .sourceUnavailable(let status):
                return status.isEmpty ? "LX 音源尚未返回可用播放接口" : status
            case .javascript(let message): return message
            case .requestTimedOut: return "LX 音源请求超时，请检查音源服务器和网络后重试"
            }
        }
    }

    private func installHostFunctions(in js: JSContext) {
        let consoleLog: @convention(block) (String) -> Void = { message in
            print("[LX] \(message)")
        }
        let console = JSValue(newObjectIn: js)
        console?.setObject(consoleLog, forKeyedSubscript: "log" as NSString)
        console?.setObject(consoleLog, forKeyedSubscript: "info" as NSString)
        console?.setObject(consoleLog, forKeyedSubscript: "warn" as NSString)
        console?.setObject(consoleLog, forKeyedSubscript: "error" as NSString)
        js.setObject(console, forKeyedSubscript: "console" as NSString)

        let nativeCall: @convention(block) (String, String, String) -> Void = { [weak self] key, action, data in
            Task { @MainActor in
                guard let self, self.key == key else { return }
                self.handleNativeCall(action: action, data: data)
            }
        }
        js.setObject(nativeCall, forKeyedSubscript: "__lx_native_call__" as NSString)

        let str2b64: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let b642buf: @convention(block) (String) -> String = { value in
            let bytes = Data(base64Encoded: value) ?? Data()
            return "[" + bytes.map(String.init).joined(separator: ",") + "]"
        }
        let md5: @convention(block) (String) -> String = { value in
            md5Hex(value.removingPercentEncoding ?? value)
        }
        let aes: @convention(block) (String, String, String, String) -> String = { input, key, iv, mode in
            aesEncrypt(input: input, key: key, iv: iv, mode: mode)
        }
        let rsa: @convention(block) (String, String, String) -> String = { input, publicKey, padding in
            rsaEncrypt(input: input, publicKey: publicKey, padding: padding)
        }
        js.setObject(str2b64, forKeyedSubscript: "__lx_native_call__utils_str2b64" as NSString)
        js.setObject(b642buf, forKeyedSubscript: "__lx_native_call__utils_b642buf" as NSString)
        js.setObject(md5, forKeyedSubscript: "__lx_native_call__utils_str2md5" as NSString)
        js.setObject(aes, forKeyedSubscript: "__lx_native_call__utils_aes_encrypt" as NSString)
        js.setObject(rsa, forKeyedSubscript: "__lx_native_call__utils_rsa_encrypt" as NSString)

        let timeout: @convention(block) (Int, Int) -> Void = { [weak self] id, delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, delay))) {
                Task { @MainActor in self?.callJS(action: "__set_timeout__", data: id) }
            }
        }
        js.setObject(timeout, forKeyedSubscript: "__lx_native_call__set_timeout" as NSString)
    }

    private func handleNativeCall(action: String, data: String) {
        guard let payloadData = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payloadData) else { return }
        if action == "cancelRequest", let requestKey = object as? String {
            tasks.removeValue(forKey: requestKey)?.cancel()
            return
        }
        guard let payload = object as? [String: Any] else { return }
        switch action {
        case "init":
            sourceInitializationTask?.cancel()
            sourceInitializationTask = nil
            pendingInitializationID = nil
            guard payload["status"] as? Bool != false else {
                statusMessage = (payload["errorMessage"] as? String).map { "LX 音源初始化失败：\($0)" }
                    ?? "LX 音源初始化失败"
                return
            }
            if let info = payload["info"] as? [String: Any],
               let sources = info["sources"] as? [String: Any] {
                capabilities = sources.reduce(into: [:]) { result, pair in
                    guard let value = pair.value as? [String: Any] else { return }
                    let actions = value["actions"] as? [String] ?? []
                    result[pair.key] = actions
                }
                qualityCapabilities = sources.reduce(into: [:]) { result, pair in
                    guard let value = pair.value as? [String: Any] else { return }
                    result[pair.key] = value["qualitys"] as? [String] ?? []
                }
                let active = capabilities
                    .filter { !$0.value.isEmpty }
                    .map { "\($0.key): \($0.value.joined(separator: ", "))" }
                    .sorted()
                statusMessage = active.isEmpty
                    ? "音源已加载，但没有可用接口"
                    : "音源已加载（\(active.joined(separator: "；"))）"
            }
        case "request":
            if let requestKey = payload["requestKey"] as? String,
               let url = payload["url"] as? String,
               let requestURL = URL(string: url) {
                sendScriptRequest(requestKey: requestKey, url: requestURL,
                                  options: payload["options"] as? [String: Any] ?? [:])
            }
        case "cancelRequest":
            break
        case "response":
            guard let requestKey = payload["requestKey"] as? String else { return }
            if payload["status"] as? Bool == true, let result = payload["result"] as? [String: Any] {
                pending.removeValue(forKey: requestKey)?.resume(returning: result)
            } else {
                let message = payload["errorMessage"] as? String ?? "LX 音源没有返回有效响应"
                pending.removeValue(forKey: requestKey)?.resume(throwing: LXError.javascript(message))
            }
        default: break
        }
    }

    private func sendScriptRequest(requestKey: String, url: URL, options: [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"] as? String ?? "GET").uppercased()
        // Match LX Mobile's request helper. A number of source backends reject
        // URLSession's default identity or return HTML without these headers.
        request.setValue("Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let headers = options["headers"] as? [String: Any] {
            headers.forEach { request.setValue(String(describing: $0.value), forHTTPHeaderField: $0.key) }
        }
        let method = request.httpMethod ?? "GET"
        if let body = options["body"], !(body is NSNull) {
            if let string = body as? String {
                request.httpBody = Data(string.utf8)
            } else if JSONSerialization.isValidJSONObject(body) {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            if request.value(forHTTPHeaderField: "Content-Type") == nil,
               method == "POST" || method == "PUT" || method == "PATCH" {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        } else if let form = options["form"] as? [String: Any] {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.map { "\($0.key.lxFormEncoded)=\(String(describing: $0.value).lxFormEncoded)" }.joined(separator: "&").utf8)
        } else if let formData = options["formData"] as? String {
            // Some older LX sources pass an already encoded formData string.
            // Preserve it instead of silently dropping the POST body.
            request.httpBody = Data(formData.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        if let timeout = options["timeout"] as? Double, timeout > 0 { request.timeoutInterval = min(timeout / 1000, 60) }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.tasks.removeValue(forKey: requestKey)
                let rawBody = data ?? Data()
                let body: Any
                if options["binary"] as? Bool == true {
                    // Binary responses are not parsed. The current LX source
                    // bridge only uses textual/JSON responses, but preserving
                    // this branch keeps the User API contract intact.
                    body = String(data: rawBody, encoding: .utf8) ?? ""
                } else if let jsonBody = try? JSONSerialization.jsonObject(with: rawBody) {
                    // LX User API scripts expect response.body to behave like
                    // LX Mobile's request helper: JSON bodies are objects,
                    // while non-JSON bodies remain strings.
                    body = jsonBody
                } else {
                    body = String(data: rawBody, encoding: .utf8) ?? ""
                }
                let http = response as? HTTPURLResponse
                var result: [String: Any] = [
                    "requestKey": requestKey,
                    "response": ["statusCode": http?.statusCode ?? 0,
                                  "statusMessage": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 0),
                                  "headers": (http?.allHeaderFields ?? [:]).reduce(into: [:]) { $0[String(describing: $1.key)] = String(describing: $1.value) },
                                  "body": body,
                                  "url": http?.url?.absoluteString ?? url.absoluteString,
                                  "ok": (200..<300).contains(http?.statusCode ?? 0)],
                ]
                if let error { result["error"] = error.localizedDescription }
                self.callJS(action: "response", data: result)
            }
        }
        tasks[requestKey] = task
        task.resume()
    }

    private func request(source: String, action: String, info: [String: Any]) async throws -> [String: Any] {
        guard context != nil else { throw LXError.noSource }
        let requestKey = "request__\(UUID().uuidString)"
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestKey] = continuation
            callJS(action: "request", data: ["requestKey": requestKey,
                                                "data": ["source": source, "action": action, "info": info]])
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self,
                       let pendingRequest = self.pending.removeValue(forKey: requestKey) else { return }
                self.tasks.removeValue(forKey: requestKey)?.cancel()
                pendingRequest.resume(throwing: LXError.requestTimedOut)
            }
        }
    }

    /// `init` is delivered through a main-actor callback. A number of user API
    /// sources initialise through a short network request, so do not reject
    /// the first playback request before that response has had a chance to
    /// arrive.  We still stop after a bounded interval and report the source
    /// state instead of inventing capabilities.
    private func waitForSourceReady() async {
        guard LXSourceStore.shared.selectedSource != nil else { return }
        for _ in 0..<120 {
            if !capabilities.isEmpty || context == nil || pendingInitializationID == nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Never leave the manager in a permanent loading state.  Crucially this
    /// timeout must not manufacture a platform/quality capability table: that
    /// made unsupported routes appear selectable and broke genuine playback.
    private func scheduleInitializationFallback(for sourceID: String) {
        sourceInitializationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled,
                  let self,
                  self.pendingInitializationID == sourceID,
                  self.loadedID == sourceID else { return }
            self.pendingInitializationID = nil
            self.statusMessage = "音源未在 6 秒内返回平台能力，请重新加载或更换音源"
        }
    }

    private func callJS(action: String, data: Any? = nil) {
        guard let context, let function = context.objectForKeyedSubscript("__lx_native__") else { return }
        let encoded: String?
        if let data, let json = try? JSONSerialization.data(withJSONObject: data), let string = String(data: json, encoding: .utf8) {
            encoded = string
        } else {
            encoded = nil
        }
        _ = function.call(withArguments: encoded == nil ? [key, action] : [key, action, encoded!])
    }

    private func sourceCandidates(for track: Track, action: String = "musicUrl") -> [String] {
        let primary = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var values = [primary]
        if SettingsManager.shared.enableSourcePlatformFallback {
            values.append(contentsOf: ["wy", "kw", "kg", "tx", "mg"])
        }
        var seen = Set<String>()
        return values.filter { platform in
            capabilities[platform]?.contains(action) == true && seen.insert(platform).inserted
        }
    }

    private func canonicalPlatform(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        switch value {
        case "wy", "163", "netease", "neteasecloudmusic", "netease-cloud-music", "cloudmusic":
            return "wy"
        case "kw", "kuwo": return "kw"
        case "kg", "kugou": return "kg"
        case "tx", "qq", "qqmusic", "qq-music": return "tx"
        case "mg", "migu": return "mg"
        default: return value
        }
    }

    /// This is only request metadata for the source's health check. It is not
    /// a playback catalogue and it never leaves the device except as part of
    /// the user-selected source's own `musicUrl` request.
    private func sourceCheckTrack(for platform: String) -> Track {
        Track(
            id: 186_016,
            name: "晴天",
            artists: [ArtistRef(id: 1, name: "周杰伦")],
            album: AlbumRef(id: 0, name: "音源连通性测试", picUrl: nil),
            durationMS: 269_000,
            source: platform,
            sourceMetadata: [
                "id": "186016",
                "songmid": "186016",
                "songId": "186016",
                "copyrightId": "186016",
            ]
        )
    }

    func availableQualityNames(for track: Track) async -> [String] {
        ensureSelectedSourceLoaded()
        await waitForSourceReady()
        guard LXSourceStore.shared.selectedSource != nil else { return [] }
        let primary = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        // The picker describes the requested track's platform. Do not union
        // fallback platforms, otherwise it offers FLAC/Hi-Res that the active
        // source cannot actually serve.
        return supportedQualityNames(for: track, platform: primary)
    }

    /// Return the qualities that can safely be requested for this track.
    ///
    /// LX source `qualitys` describes the source adapter's capabilities, while
    /// catalogue file sizes describe the individual song.  Use both when the
    /// catalogue knows the song.  When it does not, use the source declaration
    /// for normal/lossless requests, but keep Hi-Res hidden because a source
    /// declaration alone cannot prove a 24-bit file exists.
    private func supportedQualityNames(for track: Track, platform: String) -> [String] {
        let order = ["128k", "320k", "flac", "flac24bit"]
        let declared = qualityCapabilities[platform, default: []]
            .map { Self.normalizedQuality($0) }
            .filter { order.contains($0) }
        let sourceNames = declared.isEmpty ? ["128k"] : order.filter(declared.contains)
        let concrete = Self.qualityNames(for: track)

        if !concrete.isEmpty {
            return order.filter { sourceNames.contains($0) && concrete.contains($0) }
        }

        // The LX protocol does not return a song's bit depth in `musicUrl`.
        // Do not advertise Hi-Res merely because a source script lists it.
        return sourceNames.filter { $0 != "flac24bit" }
    }

    private func musicInfo(for track: Track, platform: String,
                           qualities requestedQualities: [String]? = nil) -> [String: Any] {
        // LX's User API receives the legacy MusicInfo object, not Kumone's
        // internal Track. This mirrors LX Mobile's toOldMusicInfo() exactly.
        let songmid = track.sourceMetadata["songmid"]
            ?? track.sourceMetadata["songId"]
            ?? String(track.id)
        let albumID = track.sourceMetadata["albumId"] ?? String(track.album.id)
        let qualities = requestedQualities?.isEmpty == false
            ? requestedQualities!
            : (Self.qualityNames(for: track).isEmpty ? ["128k"] : Self.qualityNames(for: track))
        let qualityInfo = qualities.map { quality in
            ["type": quality,
             "size": track.sourceMetadata["lx.quality.\(quality).size"] ?? ""] as [String: Any]
        }
        let qualityMap = Dictionary(uniqueKeysWithValues: qualities.map {
            ($0, ["size": track.sourceMetadata["lx.quality.\($0).size"] ?? ""] as [String: Any])
        })
        var info: [String: Any] = [
            "name": track.name,
            "singer": track.artistNames,
            "source": platform,
            "songmid": songmid,
            "interval": String(format: "%02d:%02d", Int(track.duration) / 60, Int(track.duration) % 60),
            "albumName": track.album.name,
            "img": track.album.picUrl ?? "",
            "typeUrl": [:] as [String: String],
            "albumId": albumID,
            "types": qualityInfo,
            "_types": qualityMap,
        ]
        switch platform {
        case "kg":
            info["hash"] = track.sourceMetadata["hash"] ?? ""
        case "tx":
            info["songId"] = Int(track.sourceMetadata["id"] ?? "") ?? track.id
            info["strMediaMid"] = track.sourceMetadata["strMediaMid"] ?? ""
            info["albumMid"] = track.sourceMetadata["albumMid"] ?? ""
        case "mg":
            info["copyrightId"] = track.sourceMetadata["copyrightId"] ?? songmid
            for key in ["lrcUrl", "mrcUrl", "trcUrl"] {
                if let value = track.sourceMetadata[key], !value.isEmpty { info[key] = value }
            }
        default:
            break
        }
        return info
    }

    private static func qualityNames(for track: Track) -> [String] {
        let order = ["128k", "320k", "flac", "flac24bit"]
        let concrete = order.filter { quality in
            guard let value = track.sourceMetadata["lx.quality.\(quality).size"] else { return false }
            return hasPositiveFileSize(value)
        }
        return concrete
    }

    private static func hasPositiveFileSize(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let match = normalized.range(of: #"^[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
              let number = Double(String(normalized[match])), number > 0 else { return false }
        return true
    }

    private static func lxQuality(for quality: String, supported: [String]) -> String {
        let requested: String
        switch quality {
        case "standard": requested = "128k"
        case "higher", "exhigh": requested = "320k"
        case "lossless": requested = "flac"
        case "hires": requested = "flac24bit"
        default: requested = "320k"
        }
        guard !supported.isEmpty else { return "128k" }
        let order = ["128k", "320k", "flac", "flac24bit"]
        guard let requestedIndex = order.firstIndex(of: requested) else { return supported[0] }
        return order[...requestedIndex].reversed().first(where: supported.contains)
            ?? supported.first
            ?? "128k"
    }

    private static func normalizedQuality(_ value: String) -> String {
        let value = value.lowercased().replacingOccurrences(of: " ", with: "")
        switch value {
        case "128", "128k", "mp3": return "128k"
        case "320", "320k": return "320k"
        case "flac", "lossless", "ape": return "flac"
        case "flac24", "flac24bit", "hires", "highres": return "flac24bit"
        default: return value
        }
    }

    private static func resolvedQuality(returned: String?, requested: String,
                                        available: [String]) -> String {
        guard let returned else { return requested }
        let normalized = normalizedQuality(returned)
        let order = ["128k", "320k", "flac", "flac24bit"]
        guard let requestedIndex = order.firstIndex(of: normalizedQuality(requested)),
              let returnedIndex = order.firstIndex(of: normalized),
              returnedIndex <= requestedIndex,
              available.contains(normalized) else { return requested }
        return normalized
    }
}

private extension String {
    var lxFormEncoded: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

private func md5Hex(_ value: String) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    let data = Data(value.utf8)
    data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func aesEncrypt(input: String, key: String, iv: String, mode: String) -> String {
    guard let inputData = Data(base64Encoded: input), let keyData = Data(base64Encoded: key) else { return "" }
    let ivData = Data(base64Encoded: iv) ?? Data(repeating: 0, count: kCCBlockSizeAES128)
    let options: CCOptions = mode == "AES"
        ? CCOptions(kCCOptionECBMode)
        : CCOptions(kCCOptionPKCS7Padding)
    var output = [UInt8](repeating: 0, count: inputData.count + kCCBlockSizeAES128)
    var moved = 0
    let status = inputData.withUnsafeBytes { inputBuffer in
        keyData.withUnsafeBytes { keyBuffer in
            ivData.withUnsafeBytes { ivBuffer in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                        keyBuffer.baseAddress, keyData.count, mode == "AES" ? nil : ivBuffer.baseAddress,
                        inputBuffer.baseAddress, inputData.count, &output, output.count, &moved)
            }
        }
    }
    guard status == kCCSuccess else { return "" }
    return Data(output.prefix(moved)).base64EncodedString()
}

private func rsaEncrypt(input: String, publicKey: String, padding: String) -> String {
    guard let inputData = Data(base64Encoded: input), let keyData = Data(base64Encoded: publicKey) else { return "" }
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                       kSecAttrKeyClass: kSecAttrKeyClassPublic]
    guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil) else { return "" }
    let algorithm: SecKeyAlgorithm = padding == "RSA/ECB/NoPadding" ? .rsaEncryptionRaw : .rsaEncryptionOAEPSHA1
    guard let encrypted = SecKeyCreateEncryptedData(key, algorithm, inputData as CFData, nil) as Data? else { return "" }
    return encrypted.base64EncodedString()
}
#endif
