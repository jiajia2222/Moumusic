import Foundation

/// One DASH representation (video or audio) as listed by Bilibili's playurl API.
struct BiliDashTrack: Sendable {
    let urls: [URL]
    let initRange: ClosedRange<Int>?
    let indexRange: ClosedRange<Int>?
    let codecs: String
    let bandwidth: Int
    let width: Int
    let height: Int
    let frameRate: String?
}

struct BiliDashSource: Sendable {
    let video: BiliDashTrack
    let audio: BiliDashTrack?
}

#if os(iOS)
import AVFoundation

/// Plays Bilibili DASH as HLS. The `.m4s` files are fragmented MP4 with a `sidx` index, which is
/// exactly what HLS-fMP4 byte-range playlists need: we fetch the init segment + index (a few
/// hundred bytes), turn the index into playlists, and let AVPlayer stream the segments itself. That
/// gives real buffering, an exact duration and instant seeking, instead of stitching two progressive
/// files together (which reported 20 s for an hour-long video and froze the picture).
final class BiliHLSLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let scheme = "mou-hls"
    private static let queue = DispatchQueue(label: "moumusic.bili.hls")
    private static var live: [ObjectIdentifier: BiliHLSLoader] = [:]
    private static var order: [ObjectIdentifier] = []
    private static let lock = NSLock()

    private struct Prepared {
        let initSegment: Data
        let segments: [(offset: Int, size: Int, duration: Double)]
    }

    private enum Kind: String {
        case video, audio
    }

    private let source: BiliDashSource
    private let userAgent: String
    private let session: URLSession
    private var cache: [String: Data] = [:]
    private var pending: [String: [AVAssetResourceLoadingRequest]] = [:]
    private var inFlight = Set<String>()
    private var prepared: [Kind: Task<Prepared, Error>] = [:]
    private let stateLock = NSLock()

    private init(source: BiliDashSource, userAgent: String) {
        self.source = source
        self.userAgent = userAgent
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    static func asset(for source: BiliDashSource, userAgent: String) -> AVURLAsset {
        let url = URL(string: "\(scheme)://stream/master.m3u8")!
        // The segments are plain https URLs fetched by AVPlayer itself; these headers apply to them.
        let headers = ["Referer": "https://www.bilibili.com/", "User-Agent": userAgent]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let loader = BiliHLSLoader(source: source, userAgent: userAgent)
        asset.resourceLoader.setDelegate(loader, queue: queue)
        lock.lock()
        let key = ObjectIdentifier(asset)
        live[key] = loader
        order.append(key)
        while order.count > 8 { live[order.removeFirst()] = nil }
        lock.unlock()
        return asset
    }

    // MARK: AVAssetResourceLoaderDelegate (on `queue`)

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme else { return false }
        let name = url.lastPathComponent
        if let data = cache[name] {
            Self.respond(loadingRequest, name: name, data: data)
            return true
        }
        pending[name, default: []].append(loadingRequest)
        if inFlight.insert(name).inserted {
            Task.detached { [self] in
                let result: Result<Data, Error>
                do { result = .success(try await build(name)) } catch { result = .failure(error) }
                Self.queue.async { self.finish(name, result) }
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for (name, requests) in pending {
            pending[name] = requests.filter { $0 !== loadingRequest }
        }
    }

    private func finish(_ name: String, _ result: Result<Data, Error>) {
        inFlight.remove(name)
        let requests = pending.removeValue(forKey: name) ?? []
        switch result {
        case .success(let data):
            cache[name] = data
            for request in requests { Self.respond(request, name: name, data: data) }
        case .failure(let error):
            let detail = error.localizedDescription
            Task { @MainActor in
                DiagnosticLogStore.shared.append(level: .warning, category: "哔哩哔哩播放", message: "HLS 清单生成失败", detail: "\(name)：\(detail)")
            }
            for request in requests { request.finishLoading(with: error) }
        }
    }

    private static func respond(_ request: AVAssetResourceLoadingRequest, name: String, data: Data) {
        if let info = request.contentInformationRequest {
            info.contentType = name.hasSuffix(".m3u8") ? "public.m3u-playlist" : "public.mpeg-4"
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let dataRequest = request.dataRequest {
            let start = Int(dataRequest.requestedOffset)
            let end = dataRequest.requestsAllDataToEndOfResource
                ? data.count : min(data.count, start + dataRequest.requestedLength)
            if start < end { dataRequest.respond(with: data.subdata(in: start..<end)) }
        }
        request.finishLoading()
    }

    // MARK: Playlist generation

    private func build(_ name: String) async throws -> Data {
        switch name {
        case "master.m3u8":
            return Data(masterPlaylist().utf8)
        case "video.m3u8":
            return Data(try await mediaPlaylist(.video).utf8)
        case "audio.m3u8":
            return Data(try await mediaPlaylist(.audio).utf8)
        case "video-init.mp4":
            return try await prepare(.video).initSegment
        case "audio-init.mp4":
            return try await prepare(.audio).initSegment
        default:
            throw URLError(.fileDoesNotExist)
        }
    }

    private func masterPlaylist() -> String {
        func codec(_ value: String) -> String {
            value.lowercased().hasPrefix("hev1") ? "hvc1" + value.dropFirst(4) : value
        }
        let video = source.video
        let audioCodec = source.audio.map { $0.codecs.isEmpty ? "mp4a.40.2" : $0.codecs }
        var codecs = codec(video.codecs.isEmpty ? "avc1.640028" : video.codecs)
        if let audioCodec { codecs += "," + audioCodec }
        let bandwidth = max(video.bandwidth + (source.audio?.bandwidth ?? 0), 100_000)
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        var info = "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),AVERAGE-BANDWIDTH=\(bandwidth),CODECS=\"\(codecs)\""
        if video.width > 0, video.height > 0 { info += ",RESOLUTION=\(video.width)x\(video.height)" }
        if let rate = video.frameRate.flatMap(Double.init), rate > 0 { info += String(format: ",FRAME-RATE=%.3f", rate) }
        if source.audio != nil {
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(Self.scheme)://stream/audio.m3u8\"")
            info += ",AUDIO=\"aud\""
        }
        lines.append(info)
        lines.append("\(Self.scheme)://stream/video.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    private func track(_ kind: Kind) throws -> BiliDashTrack {
        switch kind {
        case .video: return source.video
        case .audio:
            guard let audio = source.audio else { throw URLError(.fileDoesNotExist) }
            return audio
        }
    }

    private func mediaPlaylist(_ kind: Kind) async throws -> String {
        let info = try await prepare(kind)
        let track = try track(kind)
        var components = URLComponents(url: track.urls[0], resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let mediaURL = (components?.url ?? track.urls[0]).absoluteString
        let target = Int((info.segments.map(\.duration).max() ?? 6).rounded(.up))
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(target, 1))",
            "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(Self.scheme)://stream/\(kind.rawValue)-init.mp4\""
        ]
        for segment in info.segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append("#EXT-X-BYTERANGE:\(segment.size)@\(segment.offset)")
            lines.append(mediaURL)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Fetches init segment + `sidx` once per track (shared by the playlist and the init request).
    private func prepare(_ kind: Kind) async throws -> Prepared {
        let track = try track(kind)
        let retag = kind == .video && track.codecs.lowercased().hasPrefix("hev1")
        let task: Task<Prepared, Error> = stateLock.biliWithLock {
            if let existing = prepared[kind] { return existing }
            let created = Task { try await self.fetchPrepared(track: track, retag: retag) }
            prepared[kind] = created
            return created
        }
        return try await task.value
    }

    private func fetchPrepared(track: BiliDashTrack, retag: Bool) async throws -> Prepared {
        guard let initRange = track.initRange, let indexRange = track.indexRange,
              indexRange.lowerBound > initRange.upperBound || indexRange.lowerBound == initRange.upperBound + 1 else {
            throw URLError(.cannotParseResponse)
        }
        var lastError: Error = URLError(.badServerResponse)
        for url in track.urls {
            do {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.fragment = nil
                var request = URLRequest(url: components?.url ?? url)
                request.setValue("bytes=\(initRange.lowerBound)-\(indexRange.upperBound)", forHTTPHeaderField: "Range")
                request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                let base = initRange.lowerBound
                guard data.count > indexRange.upperBound - base else { throw URLError(.cannotParseResponse) }
                var initData = data.subdata(in: 0..<(initRange.upperBound - base + 1))
                if retag { Self.retagHEVC(&initData) }
                let sidx = data.subdata(in: (indexRange.lowerBound - base)..<(indexRange.upperBound - base + 1))
                let segments = try Self.parseSidx(sidx, anchor: indexRange.upperBound + 1)
                guard !segments.isEmpty else { throw URLError(.cannotParseResponse) }
                return Prepared(initSegment: initData, segments: segments)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Binary helpers

    private static func parseSidx(_ data: Data, anchor: Int) throws -> [(offset: Int, size: Int, duration: Double)] {
        let bytes = [UInt8](data)
        func u32(_ index: Int) -> Int {
            (Int(bytes[index]) << 24) | (Int(bytes[index + 1]) << 16) | (Int(bytes[index + 2]) << 8) | Int(bytes[index + 3])
        }
        func u64(_ index: Int) -> Int { (u32(index) << 32) | u32(index + 4) }
        guard bytes.count >= 32, String(bytes: bytes[4..<8], encoding: .ascii) == "sidx" else {
            throw URLError(.cannotParseResponse)
        }
        let version = bytes[8]
        var cursor = 12
        cursor += 4                       // reference_ID
        let timescale = max(u32(cursor), 1)
        cursor += 4
        let firstOffset: Int
        if version == 0 {
            cursor += 4                   // earliest_presentation_time
            firstOffset = u32(cursor)
            cursor += 4
        } else {
            cursor += 8
            firstOffset = u64(cursor)
            cursor += 8
        }
        cursor += 2                       // reserved
        let count = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
        cursor += 2
        var offset = anchor + firstOffset
        var result: [(offset: Int, size: Int, duration: Double)] = []
        for _ in 0..<count {
            guard cursor + 12 <= bytes.count else { break }
            let size = u32(cursor) & 0x7FFF_FFFF
            let duration = Double(u32(cursor + 4)) / Double(timescale)
            result.append((offset, size, duration))
            offset += size
            cursor += 12
        }
        return result
    }

    /// `hev1` (parameter sets possibly in-band) is re-tagged `hvc1`, which is what AVFoundation plays.
    private static func retagHEVC(_ data: inout Data) {
        let from = Array("hev1".utf8), to = Array("hvc1".utf8)
        var index = data.startIndex
        while index + 4 <= data.endIndex {
            if data[index] == from[0], data[index + 1] == from[1], data[index + 2] == from[2], data[index + 3] == from[3] {
                data.replaceSubrange(index..<index + 4, with: to)
            }
            index += 1
        }
    }
}
#endif
