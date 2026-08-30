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
        enableCompatibilityProbeIfNeeded()
        guard context != nil else { throw LXError.noSource }
        let primarySource = track.source?.isEmpty == false ? track.source! : "wy"
        for platform in sourceCandidates(for: track) {
            guard capabilities[platform]?.contains("musicUrl") == true else { continue }
            let requestTrack: Track
            if platform == primarySource {
                requestTrack = track
            } else {
                // Platform fallback must use a newly searched result with IDs
                // belonging to that platform, never the original track's ID.
                guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else {
                    continue
                }
                requestTrack = matched
            }
            let requestedQuality = Self.lxQuality(for: quality,
                                                  supported: qualityCapabilities[platform] ?? [])
            let info = musicInfo(for: requestTrack, platform: platform)
            if let response = try? await request(source: platform, action: "musicUrl",
                                                 info: ["type": requestedQuality, "musicInfo": info]),
               let data = response["data"] as? [String: Any],
               let rawURL = data["url"] as? String,
               let url = URL(string: rawURL) {
                return ResolvedURL(url: url, quality: (data["type"] as? String) ?? requestedQuality)
            }
        }
        throw LXError.resolveFailed
    }

    /// Performs a real, read-only musicUrl request against the selected LX
    /// source. This deliberately checks a catalogue result and validates the
    /// returned URL instead of treating script initialization alone as proof
    /// that playback works.
    func checkSelectedSource() async -> SourceCheckResult {
        ensureSelectedSourceLoaded()
        await waitForSourceReady()
        enableCompatibilityProbeIfNeeded()
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
            let track: Track?
            if let current = PlayerService.shared.currentTrack, current.source == platform {
                track = current
            } else {
                let results = try? await LXCatalogService.search(
                    "周杰伦 晴天",
                    platform: LXCatalogPlatform(rawValue: platform)!,
                    page: 1,
                    limit: 1
                )
                track = results?.first
            }
            guard let track else {
                failures.append("\(platformName)：找不到测试歌曲")
                continue
            }

            let requestedQuality = Self.lxQuality(for: SettingsManager.shared.audioQuality.rawValue,
                                                   supported: qualityCapabilities[platform] ?? [])
            let info = musicInfo(for: track, platform: platform)
            guard let response = try? await request(source: platform, action: "musicUrl",
                                                    info: ["type": requestedQuality, "musicInfo": info]),
                  let data = response["data"] as? [String: Any],
                  let rawURL = data["url"] as? String,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                failures.append("\(platformName)：没有返回有效播放地址")
                continue
            }

            let actualQuality = (data["type"] as? String) ?? requestedQuality
            let detail = "已通过 \(platformName) 的 musicUrl 接口，音质：\(actualQuality)"
            let result = SourceCheckResult(status: .available,
                                           message: "音源可用",
                                           detail: detail)
            statusMessage = "\(result.message)：\(detail)"
            return result
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
        for platform in sourceCandidates(for: track) {
            guard capabilities[platform]?.contains("lyric") == true else { continue }
            guard let response = try? await request(source: platform, action: "lyric",
                                                    info: ["type": "lyric", "musicInfo": musicInfo(for: track, platform: platform)]),
                  let data = response["data"] as? [String: Any],
                  let lyric = data["lyric"] as? String,
                  !lyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return ResolvedLyrics(lyric: lyric, tlyric: data["tlyric"] as? String,
                                  rlyric: data["rlyric"] as? String, lxlyric: data["lxlyric"] as? String)
        }
        throw LXError.resolveFailed
    }

    enum LXError: LocalizedError {
        case noSource
        case resolveFailed
        case requestTimedOut
        case javascript(String)

        var errorDescription: String? {
            switch self {
            case .noSource: return "请先在“我的 → LX 音源”中导入并启用音源"
            case .resolveFailed: return "LX 音源没有返回可播放地址"
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
            enableCompatibilityProbeIfNeeded()
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
        if options["headers"] == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if let headers = options["headers"] as? [String: Any] {
            headers.forEach { request.setValue(String(describing: $0.value), forHTTPHeaderField: $0.key) }
        }
        if let body = options["body"], !(body is NSNull) {
            if let string = body as? String { request.httpBody = Data(string.utf8) }
            else if JSONSerialization.isValidJSONObject(body) { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        } else if let form = options["form"] as? [String: Any] {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.map { "\($0.key.lxFormEncoded)=\(String(describing: $0.value).lxFormEncoded)" }.joined(separator: "&").utf8)
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
                                  "body": body],
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
                try? await Task.sleep(for: .seconds(12))
                guard let self,
                      let pendingRequest = self.pending.removeValue(forKey: requestKey) else { return }
                pendingRequest.resume(throwing: LXError.requestTimedOut)
            }
        }
    }

    /// `init` is delivered through a main-actor callback. Resolution can start
    /// in the same run-loop turn as source loading, so wait briefly for the
    /// imported script's capability table before treating it as empty.
    private func waitForSourceReady() async {
        guard LXSourceStore.shared.selectedSource != nil else { return }
        for _ in 0..<24 {
            if !capabilities.isEmpty || context == nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Some legacy LX scripts register a request handler but never send an
    /// `inited` capability table (or their remote init endpoint is slow).
    /// Do not leave the UI in a permanent loading state: enable a conservative
    /// probe mode so playback and the test action can ask the script directly.
    /// A source is only reported as usable after it returns a real music URL.
    private func scheduleInitializationFallback(for sourceID: String) {
        sourceInitializationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled,
                  let self,
                  self.pendingInitializationID == sourceID,
                  self.loadedID == sourceID else { return }
            self.enableCompatibilityProbeIfNeeded()
            self.pendingInitializationID = nil
        }
    }

    private func enableCompatibilityProbeIfNeeded() {
        guard context != nil else { return }
        let hasMusicURL = capabilities.values.contains { $0.contains("musicUrl") }
        guard !hasMusicURL,
              let source = LXSourceStore.shared.selectedSource,
              source.id == loadedID,
              source.script.range(of: "musicUrl", options: .caseInsensitive) != nil else {
            return
        }

        let platforms = ["wy", "kw", "kg", "tx", "mg"]
        let qualities = ["128k", "320k", "flac", "flac24bit"]
        capabilities = Dictionary(uniqueKeysWithValues: platforms.map { ($0, ["musicUrl"]) })
        qualityCapabilities = Dictionary(uniqueKeysWithValues: platforms.map { ($0, qualities) })
        statusMessage = "音源未返回能力清单，已启用兼容探测"
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

    private func sourceCandidates(for track: Track) -> [String] {
        var values: [String] = []
        if let source = track.source, !source.isEmpty { values.append(source) }
        if SettingsManager.shared.enableSourcePlatformFallback {
            values.append(contentsOf: ["wy", "kw", "kg", "tx", "mg"])
        }
        var seen = Set<String>()
        return values.filter { capabilities[$0] != nil && seen.insert($0).inserted }
    }

    func availableQualityNames(for track: Track) async -> [String] {
        ensureSelectedSourceLoaded()
        await waitForSourceReady()
        enableCompatibilityProbeIfNeeded()
        var names: [String] = []
        for platform in sourceCandidates(for: track) {
            names.append(contentsOf: qualityCapabilities[platform] ?? [])
        }
        let order = ["128k", "320k", "flac", "flac24bit"]
        return order.filter { names.contains($0) }
    }

    private func musicInfo(for track: Track, platform: String) -> [String: Any] {
        // LX's User API receives the legacy MusicInfo object, not Kumone's
        // internal Track. This mirrors LX Mobile's toOldMusicInfo() exactly.
        let songmid = track.sourceMetadata["songmid"]
            ?? track.sourceMetadata["songId"]
            ?? String(track.id)
        let albumID = track.sourceMetadata["albumId"] ?? String(track.album.id)
        let qualities = ["128k", "320k", "flac", "flac24bit"]
        let qualityInfo = qualities.map { ["type": $0, "size": ""] as [String: Any] }
        let qualityMap = Dictionary(uniqueKeysWithValues: qualities.map {
            ($0, ["size": ""] as [String: Any])
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

    private static func lxQuality(for quality: String, supported: [String]) -> String {
        let requested: String
        switch quality {
        case "standard": requested = "128k"
        case "higher", "exhigh": requested = "320k"
        case "lossless": requested = "flac"
        case "hires": requested = "flac24bit"
        default: requested = "320k"
        }
        guard !supported.isEmpty else { return requested }
        let order = ["128k", "320k", "flac", "flac24bit"]
        guard let requestedIndex = order.firstIndex(of: requested) else { return supported[0] }
        return order[...requestedIndex].reversed().first(where: supported.contains)
            ?? supported.first
            ?? "128k"
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
