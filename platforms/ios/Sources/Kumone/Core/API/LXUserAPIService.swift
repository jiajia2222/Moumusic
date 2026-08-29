#if os(iOS)
import CommonCrypto
import Foundation
import JavaScriptCore
import Security

/// iOS counterpart of LX Mobile's QuickJS bridge.  The provider script stays
/// user supplied; this class only implements the LX 2.0 host protocol.
@MainActor
final class LXUserAPIService {
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

    static let shared = LXUserAPIService()

    private let session: URLSession
    private var context: JSContext?
    private var key = ""
    private var loadedID: String?
    private var tasks: [String: URLSessionDataTask] = [:]
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private(set) var capabilities: [String: [String]] = [:]

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func loadSelectedSource() {
        load(LXSourceStore.shared.selectedSource)
    }

    func load(_ source: LXSourceStore.Source?) {
        context = nil
        loadedID = source?.id
        capabilities = [:]
        guard let source,
              let preloadURL = Bundle.module.url(forResource: "LXUserAPIPreload", withExtension: "js"),
              let preload = try? String(contentsOf: preloadURL, encoding: .utf8) else { return }

        let js = JSContext()
        js?.exceptionHandler = { _, exception in
            if let exception { print("[LX] JavaScript error: \(exception)") }
        }
        context = js
        key = UUID().uuidString
        installHostFunctions(in: js!)
        js?.evaluateScript(preload)
        let setup = js?.objectForKeyedSubscript("lx_setup")
        setup?.call(withArguments: [key, source.id, source.name, source.description,
                                    source.version, source.author, source.homepage, source.script])
        _ = js?.evaluateScript(source.script)
        if js?.exception != nil {
            print("[LX] failed to load source \(source.name)")
        }
    }

    func resolveMusicURL(for track: Track, quality: String) async throws -> ResolvedURL {
        guard context != nil else { throw LXError.noSource }
        let requestedQuality = Self.lxQuality(for: quality)
        for platform in sourceCandidates(for: track) {
            guard capabilities[platform]?.contains("musicUrl") == true else { continue }
            let info = musicInfo(for: track, platform: platform)
            if let response = try? await request(source: platform, action: "musicUrl",
                                                 info: ["type": requestedQuality, "musicInfo": info]),
               let data = response["data"] as? [String: Any],
               let rawURL = data["url"] as? String,
               let url = URL(string: rawURL.replacingOccurrences(of: "http://", with: "https://")) {
                return ResolvedURL(url: url, quality: (data["type"] as? String) ?? requestedQuality)
            }
        }
        throw LXError.resolveFailed
    }

    func resolveLyrics(for track: Track) async throws -> ResolvedLyrics {
        guard context != nil else { throw LXError.noSource }
        for platform in sourceCandidates(for: track) {
            guard capabilities[platform]?.contains("lyric") == true else { continue }
            let response = try await request(source: platform, action: "lyric",
                                             info: ["type": "lyric", "musicInfo": musicInfo(for: track, platform: platform)])
            guard let data = response["data"] as? [String: Any],
                  let lyric = data["lyric"] as? String else { continue }
            return ResolvedLyrics(lyric: lyric, tlyric: data["tlyric"] as? String,
                                  rlyric: data["rlyric"] as? String, lxlyric: data["lxlyric"] as? String)
        }
        throw LXError.resolveFailed
    }

    enum LXError: LocalizedError {
        case noSource
        case resolveFailed
        case javascript(String)

        var errorDescription: String? {
            switch self {
            case .noSource: return "??????????? LX ??"
            case .resolveFailed: return "LX ???????????"
            case .javascript(let message): return message
            }
        }
    }

    private func installHostFunctions(in js: JSContext) {
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
            if let info = payload["info"] as? [String: Any],
               let sources = info["sources"] as? [String: Any] {
                capabilities = sources.reduce(into: [:]) { result, pair in
                    guard let value = pair.value as? [String: Any] else { return }
                    let actions = value["actions"] as? [String] ?? []
                    result[pair.key] = actions
                }
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
                pending.removeValue(forKey: requestKey)?.resume(throwing: LXError.resolveFailed)
            }
        default: break
        }
    }

    private func sendScriptRequest(requestKey: String, url: URL, options: [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"] as? String ?? "GET").uppercased()
        if let headers = options["headers"] as? [String: Any] {
            headers.forEach { request.setValue(String(describing: $0.value), forHTTPHeaderField: $0.key) }
        }
        if let body = options["body"] {
            if let string = body as? String { request.httpBody = Data(string.utf8) }
            else if JSONSerialization.isValidJSONObject(body) { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        } else if let form = options["form"] as? [String: Any] {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.map { "\($0.key)=\(String(describing: $0.value).urlQueryEscaped)" }.joined(separator: "&").utf8)
        }
        if let timeout = options["timeout"] as? Double, timeout > 0 { request.timeoutInterval = min(timeout / 1000, 60) }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.tasks.removeValue(forKey: requestKey)
                let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
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
        }
    }

    private func callJS(action: String, data: Any? = nil) {
        guard let context, let function = context.objectForKeyedSubscript("__lx_native__") else { return }
        let encoded: String?
        if let data, let json = try? JSONSerialization.data(withJSONObject: data), let string = String(data: json, encoding: .utf8) {
            encoded = string
        } else if let data as Int {
            encoded = String(data)
        } else {
            encoded = nil
        }
        _ = function.call(withArguments: encoded == nil ? [key, action] : [key, action, encoded!])
    }

    private func sourceCandidates(for track: Track) -> [String] {
        var values: [String] = []
        if let source = track.source, !source.isEmpty { values.append(source) }
        values.append(contentsOf: ["wy", "kw", "kg", "tx", "mg"])
        return values.filter { capabilities[$0] != nil }
    }

    private func musicInfo(for track: Track, platform: String) -> [String: Any] {
        var info: [String: Any] = [
            "id": String(track.id), "songId": track.sourceMetadata["songId"] ?? String(track.id),
            "songmid": track.sourceMetadata["songmid"] ?? String(track.id),
            "name": track.name, "singer": track.artistNames, "source": platform,
            "interval": String(format: "%02d:%02d", Int(track.duration) / 60, Int(track.duration) % 60),
            "albumName": track.album.name, "albumId": track.sourceMetadata["albumId"] ?? String(track.album.id),
        ]
        for key in ["hash", "strMediaMid", "copyrightId", "albumMid"] {
            if let value = track.sourceMetadata[key], !value.isEmpty { info[key] = value }
        }
        info["meta"] = ["songId": info["songId"] ?? String(track.id),
                         "albumName": track.album.name,
                         "picUrl": track.album.picUrl ?? NSNull(),
                         "qualitys": ["128k", "320k", "flac", "flac24bit"]]
        return info
    }

    private static func lxQuality(for quality: String) -> String {
        switch quality {
        case "standard": return "128k"
        case "higher", "exhigh": return "320k"
        case "lossless": return "flac"
        case "hires": return "flac24bit"
        default: return "320k"
        }
    }
}

private extension String {
    var urlQueryEscaped: String { addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self }
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
    let options: CCOptions = mode == "AES" ? kCCOptionECBMode : kCCOptionPKCS7Padding
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
