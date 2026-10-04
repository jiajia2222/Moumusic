import Foundation

/// Migu Music's public listen route (no login needed).
///
/// The listen-url endpoint hands out the 128k (PQ) file; the other tiers are the same recording stored in
/// another folder / format on Migu's CDN, so a higher tier is that URL with the folder and extension swapped
/// (this is how the documented `Domdkw/miguMusic-api-enhanced` client explains its quality conversion). The
/// endpoint's reply is lightly obfuscated (a byte-shift with a fixed key), which is undone here. Written from
/// scratch for this app; every converted URL is checked to really exist before it is offered or played, and the
/// player then measures the file itself.
actor MiguAPI {
    static let shared = MiguAPI()

    struct ResolvedAudio: Sendable {
        let url: URL
        /// Canonical tier name (`AudioQuality.lxType`).
        let quality: String
    }

    enum MiguError: Error { case unavailable, unsupported }

    private enum Tone: String, CaseIterable {
        case pq = "PQ", hq = "HQ", sq = "SQ", zq24 = "ZQ24", zq32 = "ZQ32", z3d = "Z3D"

        init?(lxType: String) {
            switch lxType.lowercased() {
            case "128k", "standard", "128": self = .pq
            case "320k", "exhigh", "higher", "320": self = .hq
            case "flac", "lossless": self = .sq
            case "flac24bit", "hires", "flac24": self = .zq24
            case "jymaster", "master": self = .zq32
            case "atmos", "surround": self = .z3d
            default: return nil
            }
        }

        var folder: String {
            switch self {
            case .pq: return "标清高清/MP3_128_16_Stero"
            case .hq: return "标清高清/MP3_320_16_Stero"
            case .sq: return "歌曲下载/flac"
            case .zq24: return "歌曲下载/flac_24bit"
            case .zq32: return "歌曲下载/wav_32bit"
            case .z3d: return "歌曲下载/wav_3d"
            }
        }

        var fileExtension: String {
            switch self {
            case .pq, .hq: return "mp3"
            case .sq, .zq24: return "flac"
            case .zq32, .z3d: return "wav"
            }
        }

        var quality: String {
            switch self {
            case .pq: return "128k"
            case .hq: return "320k"
            case .sq: return "flac"
            case .zq24: return "flac24bit"
            case .zq32: return "jymaster"
            case .z3d: return "atmos"
            }
        }
    }

    private static let key = Array("Jk8qzuePiJ1qE3mDYhLQ3T73DtDoAhLP".utf8)
    private let session: URLSession
    private var baseCache: [String: (url: String, at: Date)] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    // MARK: Public

    func musicURL(copyrightId: String, contentId: String? = nil, quality: String) async throws -> ResolvedAudio {
        guard let tone = Tone(lxType: quality) else { throw MiguError.unsupported }
        let base = try await baseURL(copyrightId: copyrightId, contentId: contentId)
        if tone == .pq {
            guard let url = Self.secure(base) else { throw MiguError.unavailable }
            return ResolvedAudio(url: url, quality: tone.quality)
        }
        guard let candidate = Self.convert(base, to: tone) else { throw MiguError.unavailable }
        guard let working = await verified(candidate) else { throw MiguError.unavailable }
        return ResolvedAudio(url: working, quality: tone.quality)
    }

    /// Every tier of this song that really has a file, checked at the same time.
    func availableQualities(copyrightId: String, contentId: String? = nil) async -> [String] {
        guard !copyrightId.isEmpty else { return [] }
        return await withTaskGroup(of: String?.self) { group in
            for tone in Tone.allCases {
                group.addTask {
                    (try? await self.musicURL(copyrightId: copyrightId, contentId: contentId, quality: tone.quality))?.quality
                }
            }
            var found: [String] = []
            for await value in group { if let value { found.append(value) } }
            return found
        }
    }

    // MARK: Base (128k) URL

    private func baseURL(copyrightId: String, contentId: String?) async throws -> String {
        let cacheKey = copyrightId + "|" + (contentId ?? "")
        if let cached = baseCache[cacheKey], Date().timeIntervalSince(cached.at) < 600 { return cached.url }
        if let running = inFlight[cacheKey] { return try await running.value }
        let task = Task { try await self.fetchBase(copyrightId: copyrightId, contentId: contentId) }
        inFlight[cacheKey] = task
        defer { inFlight[cacheKey] = nil }
        let url = try await task.value
        baseCache[cacheKey] = (url, Date())
        return url
    }

    private func fetchBase(copyrightId: String, contentId: String?) async throws -> String {
        var components = URLComponents(string: "https://c.musicapp.migu.cn/strategy/listen-url/h5/v2.4")!
        var items = [
            URLQueryItem(name: "copyrightId", value: copyrightId),
            URLQueryItem(name: "resourceType", value: "2"),
            URLQueryItem(name: "netType", value: "01"),
            URLQueryItem(name: "toneFlag", value: "PQ"),
            URLQueryItem(name: "scene", value: ""),
        ]
        if let contentId, !contentId.isEmpty {
            items.append(URLQueryItem(name: "contentId", value: contentId))
            items.append(URLQueryItem(name: "lowerQualityContentId", value: contentId))
        }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("h5page", forHTTPHeaderField: "birth")
        request.setValue("014X031", forHTTPHeaderField: "channel")
        request.setValue("https://y.migu.cn/", forHTTPHeaderField: "Referer")
        request.setValue("30.6698676660,104.1229614820", forHTTPHeaderField: "location-data")
        request.setValue("", forHTTPHeaderField: "location-info")
        let (data, _) = try await session.data(for: request)
        guard let object = Self.decodeReply(data),
              let payload = object["data"] as? [String: Any],
              let url = payload["url"] as? String, !url.isEmpty else {
            // No URL: not available in this region / for this song (the reply then carries a dialog instead).
            throw MiguError.unavailable
        }
        return url
    }

    /// The reply is either plain JSON or `AB CD 01 <shift>` followed by bytes shifted against a fixed key.
    private static func decodeReply(_ data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        if bytes.count >= 4, bytes[0] == 171, bytes[1] == 205 {
            let shift = Int(bytes[3])
            var decoded = [UInt8]()
            decoded.reserveCapacity(bytes.count - 4)
            for (index, byte) in bytes[4...].enumerated() {
                decoded.append(UInt8(truncatingIfNeeded: Int(byte) + shift - Int(key[index % key.count])))
            }
            return (try? JSONSerialization.jsonObject(with: Data(decoded))) as? [String: Any]
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Tier URLs

    private static func encode(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/_-.~"))) ?? path
    }

    private static func secure(_ raw: String) -> URL? {
        URL(string: raw.replacingOccurrences(of: "http://", with: "https://"))
    }

    /// Same file under another folder / extension. The query (a short-lived token) is dropped.
    private static func convert(_ base: String, to tone: Tone) -> String? {
        var text = base.components(separatedBy: "?")[0]
        let source = Tone.pq
        if text.contains(encode(source.folder)) {
            text = text.replacingOccurrences(of: encode(source.folder), with: encode(tone.folder))
        } else if text.contains(source.folder) {
            text = text.replacingOccurrences(of: source.folder, with: encode(tone.folder))
        } else {
            return nil
        }
        if text.hasSuffix(".mp3"), tone.fileExtension != "mp3" {
            text = String(text.dropLast(4)) + "." + tone.fileExtension
        }
        return text
    }

    /// A converted URL is only trusted when the CDN really serves it (https first, then plain http).
    private func verified(_ candidate: String) async -> URL? {
        var attempts = [candidate.replacingOccurrences(of: "http://", with: "https://")]
        if candidate.hasPrefix("http://") { attempts.append(candidate) }
        for text in attempts {
            guard let url = URL(string: text) else { continue }
            var request = URLRequest(url: url)
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            request.setValue("https://y.migu.cn/", forHTTPHeaderField: "Referer")
            // Headers are enough: stream and drop the body (a server that ignores Range would send the whole file).
            guard let (_, response) = try? await session.bytes(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 206 else { continue }
            return url
        }
        return nil
    }
}
