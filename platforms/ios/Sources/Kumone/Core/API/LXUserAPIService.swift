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
        /// The catalogue platform that really served the file (differs from the song's own platform when a
        /// cross-platform match supplied it). nil = the song's own platform.
        var platform: String? = nil
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

    private struct MusicURLCandidate {
        let source: LXSourceStore.Source
        let sourcePriority: Int
        let platform: String
        let track: Track
        let supportedQualities: [String]
        let requestedQuality: String
    }

    static let shared = LXUserAPIService()

    // Quality discovery must not hold the sheet open behind a dead source.
    // The actual playback resolver intentionally uses a longer timeout.
    private static let qualityProbeTimeout: TimeInterval = 1.8

    private let session: URLSession
    /// Confirmed probe answers per song / platform / tier, so opening the picker again does not re-request them.
    private var qualityProbeCache: [String: (value: String, at: Date)] = [:]
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
    /// Tiers the selected source declares for a platform it can serve (musicUrl). Checked whenever a source
    /// is loaded (switching sources, app launch) and remembered per source for the next launch.
    @Published private(set) var sourceTierSupport: Set<String> = []
    @Published private(set) var sourceSupportKnown = false

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    /// What the source itself says it can play, per platform that has a musicUrl action.
    private func updateSourceSupport() {
        var tiers = Set<String>()
        for (platform, names) in qualityCapabilities where capabilities[platform]?.contains("musicUrl") == true {
            tiers.insert("128k")
            for name in names { tiers.insert(Self.normalizedQuality(name)) }
        }
        if let id = loadedID {
            UserDefaults.standard.set(Array(tiers), forKey: "moumusic.lx.tierSupport.\(id)")
        }
        recomputeCombinedSupport()
        let readable = AudioQuality.allCases.filter { tiers.contains($0.lxType) }
            .reduce(into: [String]()) { list, quality in
                if !list.contains(quality.sourceDisplayName.components(separatedBy: " / ").last ?? "") {
                    list.append(quality.sourceDisplayName.components(separatedBy: " / ").last ?? "")
                }
            }
        let sourceName = LXSourceStore.shared.sources.first { $0.id == loadedID }?.name ?? "音源"
        DiagnosticLogStore.shared.append(level: .info, category: "音源能力",
                                         message: "\(sourceName) 声明支持：\(readable.joined(separator: "、"))",
                                         detail: "已启用音源合计：\(AudioQuality.allCases.filter { sourceTierSupport.contains($0.lxType) }.map(\.displayName).joined(separator: "、"))。不被任何已启用音源声明的音质不会在列表中显示。")
        QualitySupport.normalizeSelection()
    }

    /// The tiers of ALL enabled sources together (playback tries them in turn), from what each one declared at its
    /// last check. Unknown until every enabled source has been checked once.
    func recomputeCombinedSupport() {
        let enabled = LXSourceStore.shared.playbackSources
        guard !enabled.isEmpty else {
            sourceTierSupport = []
            sourceSupportKnown = true
            return
        }
        var union = Set<String>()
        var allKnown = true
        for source in enabled {
            if let stored = UserDefaults.standard.array(forKey: "moumusic.lx.tierSupport.\(source.id)") as? [String] {
                union.formUnion(stored)
            } else {
                allKnown = false
            }
        }
        sourceTierSupport = union
        sourceSupportKnown = allKnown
    }

    /// Launch / "a source was enabled" check: load every enabled source once to read what it declares, then put
    /// the preferred one back.
    func refreshAllSourceSupport() {
        supportRefreshTask?.cancel()
        supportRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for source in LXSourceStore.shared.playbackSources {
                guard !Task.isCancelled else { return }
                _ = await self.activate(source, waitTime: 5)
            }
            guard !Task.isCancelled else { return }
            if let preferred = LXSourceStore.shared.selectedSource, self.loadedID != preferred.id {
                self.load(preferred)
            }
            self.recomputeCombinedSupport()
            QualitySupport.normalizeSelection()
        }
    }

    private var supportRefreshTask: Task<Void, Never>?

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

        // Importing/selecting a second source invalidates requests issued by
        // the previous JavaScript context.  Cancel the URL tasks and finish
        // their continuations before replacing the context; otherwise an old
        // callback can keep the previous source alive while the new source is
        // being installed.
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        let staleRequests = pending
        pending.removeAll()
        staleRequests.values.forEach { $0.resume(throwing: LXError.noSource) }

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

        guard let js = JSContext() else {
            pendingInitializationID = nil
            statusMessage = "LX JavaScript 运行环境初始化失败"
            return
        }
        js.exceptionHandler = { _, exception in
            if let exception { print("[LX] JavaScript error: \(exception)") }
        }
        context = js
        key = UUID().uuidString
        installHostFunctions(in: js)
        js.evaluateScript(preload)
        if let exception = js.exception {
            context = nil
            pendingInitializationID = nil
            statusMessage = "LX 桥接加载失败：\(exception.toString())"
            return
        }
        let setup = js.objectForKeyedSubscript("lx_setup")
        setup?.call(withArguments: [key, source.id, source.name, source.description,
                                    source.version, source.author, source.homepage, source.script])
        if let exception = js.exception {
            context = nil
            pendingInitializationID = nil
            statusMessage = "LX 音源初始化失败：\(exception.toString())"
            return
        }
        _ = js.evaluateScript(source.script)
        if let exception = js.exception {
            context = nil
            pendingInitializationID = nil
            statusMessage = "LX 音源脚本错误：\(exception.toString())"
            print("[LX] failed to load source \(source.name): \(exception)")
        }
        if context != nil {
            scheduleInitializationFallback(for: source.id)
        }
    }

    func resolveMusicURL(for track: Track, quality: String,
                         excludingURLs: Set<String> = [],
                         forceThirdParty: Bool = false) async throws -> ResolvedURL {
        let sourceMode = SettingsManager.shared.playbackSourceMode
        if forceThirdParty {
            // 账号模式下用户允许非会员用第三方音源播放会员歌曲：不再回到官方账号（只会得到试听片段）。
            return try await resolveMusicURLAcrossSources(for: track, quality: quality, excludingURLs: excludingURLs)
        }
        if sourceMode == .official {
            guard hasAuthenticatedAccount(for: track) else {
                throw LXError.sourceUnavailable("请先登录对应平台账号，并选择该平台歌曲")
            }
            return try await resolveOfficialMusicURL(for: track, quality: quality)
        }

        // Automatic mode follows the same rule as the player and download
        // manager: try the matching account source first, reject preview-only
        // URLs, then fall back to the enabled LX sources.
        if sourceMode == .automatic, hasAuthenticatedAccount(for: track),
           let official = try? await resolveOfficialMusicURL(for: track, quality: quality) {
            return official
        }
        return try await resolveMusicURLAcrossSources(
            for: track,
            quality: quality,
            excludingURLs: excludingURLs
        )
#if false
        ensureSelectedSourceLoaded()
        await waitForSourceReady()
        guard context != nil else { throw LXError.noSource }
        guard capabilities.values.contains(where: { $0.contains("musicUrl") }) else {
            throw LXError.sourceUnavailable(statusMessage)
        }
        let primarySource = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var failures: [String] = []

        for platform in sourceCandidates(for: track, action: "musicUrl") {
            let platformName = LXCatalogPlatform.displayName(for: platform)
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
                                                 info: ["type": protocolQualityToken(requestedQuality, platform: platform),
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
                    data: data,
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
#endif
    }

    /// Resolves through an authenticated provider account when that provider
    /// exposes an official full-track URL. It never bypasses VIP checks or
    /// manufactures a URL when the account is not entitled to play the track.
    private func resolveOfficialMusicURL(for track: Track, quality: String) async throws -> ResolvedURL {
        switch canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy" {
        case "tx":
            guard let cookie = QQMusicSessionStore.shared.cookie,
                  QQMusicSessionStore.shared.isLoggedIn else {
                throw LXError.sourceUnavailable("QQ 音乐账号未登录")
            }
            let songMid = track.sourceMetadata["songmid"] ?? String(track.id)
            var lastError: Error?
            let requestedQualities = [quality, "exhigh", "standard"].reduce(into: [String]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }
            for requestedQuality in requestedQualities {
                do {
                    let audio = try await QQMusicAPI.shared.musicURL(
                        songMid: songMid,
                        mediaMid: track.sourceMetadata["strMediaMid"]?.isEmpty == false
                            ? track.sourceMetadata["strMediaMid"]
                            : track.sourceMetadata["media_mid"],
                        quality: requestedQuality,
                        cookie: cookie
                    )
                    return ResolvedURL(url: audio.url, quality: audio.quality)
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? LXError.sourceUnavailable("QQ 音乐账号没有可用音质")
        case "kg":
            guard let cookie = KugouSessionStore.shared.cookie,
                  KugouSessionStore.shared.isLoggedIn else {
                throw LXError.sourceUnavailable("酷狗音乐账号未登录")
            }
            guard let hash = track.sourceMetadata["hash"] ?? track.sourceMetadata["Hash"],
                  !hash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LXError.sourceUnavailable("酷狗歌曲缺少官方 hash，无法使用账号音源")
            }
            let requestedQualities = [quality, "hires", "lossless", "exhigh", "standard"]
                .reduce(into: [String]()) { result, item in
                    if !result.contains(item) { result.append(item) }
                }
            var lastError: Error?
            for requestedQuality in requestedQualities {
                do {
                    let audio = try await KugouAPI.shared.musicURL(
                        hash: hash,
                        quality: requestedQuality,
                        cookie: cookie,
                        albumID: track.sourceMetadata["albumId"],
                        albumAudioID: track.sourceMetadata["albumAudioId"]
                            ?? track.sourceMetadata["albumAudioID"]
                            ?? track.sourceMetadata["mixsongid"]
                    )
                    return ResolvedURL(url: audio.url, quality: audio.quality)
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? LXError.sourceUnavailable("酷狗音乐账号没有可用音质")
        case "mg":
            guard let copyrightId = track.sourceMetadata["copyrightId"], !copyrightId.isEmpty else {
                throw LXError.sourceUnavailable("咪咕歌曲缺少 copyrightId，无法使用官方接口")
            }
            var lastError: Error?
            let requestedQualities = [quality, "exhigh", "standard"].reduce(into: [String]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }
            for requestedQuality in requestedQualities {
                do {
                    let audio = try await MiguAPI.shared.musicURL(copyrightId: copyrightId, quality: requestedQuality)
                    return ResolvedURL(url: audio.url, quality: audio.quality)
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? LXError.sourceUnavailable("咪咕官方接口没有可用音质")
        case "kw":
            guard let songID = track.sourceMetadata["songmid"], !songID.isEmpty else {
                throw LXError.sourceUnavailable("酷我歌曲缺少 id，无法使用官方接口")
            }
            var lastError: Error?
            let requestedQualities = [quality, "exhigh", "standard"].reduce(into: [String]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }
            for requestedQuality in requestedQualities {
                do {
                    let audio = try await KuwoAPI.shared.musicURL(songID: songID, quality: requestedQuality)
                    return ResolvedURL(url: audio.url, quality: audio.quality)
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? LXError.sourceUnavailable("酷我官方接口没有可用音质")
        default:
            break
        }

        let requested = AudioQuality(rawValue: quality)
            ?? AudioQuality(lxType: quality)
            ?? .standard
        let data = try await NeteaseAPI.songURL(ids: [track.id], level: requested.neteaseLevel).first
        guard let data,
              let rawURL = data.url,
              let url = URL(string: rawURL.replacingOccurrences(of: "http://", with: "https://")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw LXError.sourceUnavailable("官方账号没有返回可播放地址")
        }
        if data.freeTrialInfo != nil {
            throw LXError.sourceUnavailable("官方账号只返回试听片段")
        }
        if data.time > 0, track.duration > 0 {
            let returnedDuration = TimeInterval(data.time) / 1000
            let minimumFullLength = max(45, track.duration * 0.65)
            if returnedDuration < minimumFullLength {
                throw LXError.sourceUnavailable("官方账号只返回试听片段")
            }
        }
        return ResolvedURL(
            url: url,
            quality: NeteaseAPI.officialQuality(for: data)?.lxType ?? "unknown"
        )
    }

    private func hasAuthenticatedAccount(for track: Track) -> Bool {
        switch canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy" {
        case "tx":
            return QQMusicSessionStore.shared.isLoggedIn && QQMusicSessionStore.shared.cookie != nil
        case "wy":
            return NeteaseClient.shared.isLoggedIn
        case "kg":
            return KugouSessionStore.shared.isLoggedIn && KugouSessionStore.shared.cookie != nil
        case "mg", "kw":
            return true   // public route, no account
        default:
            return false
        }
    }

    private static func isNeteaseTrack(_ track: Track) -> Bool {
        guard let rawSource = track.source ?? track.sourceMetadata["source"] else {
            // Native NetEase catalogue responses do not carry an LX source
            // marker. They are the only unmarked tracks in the queue.
            return true
        }
        let source = rawSource
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty || ["wy", "163", "netease", "neteasecloudmusic", "cloudmusic"].contains(source)
    }

    private func resolveMusicURLAcrossSources(for track: Track, quality: String,
                                              excludingURLs: Set<String>) async throws -> ResolvedURL {
        let playbackSources = LXSourceStore.shared.playbackSources
        guard !playbackSources.isEmpty else { throw LXError.noSource }

        let primaryPlatform = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var failures: [String] = []
        var downgradedFallback: ResolvedURL?
        let startedAt = Date()
        var anyCandidate = false

        // Two passes, like Beans: first the song's own platform (no catalogue matching, so the very first
        // request goes out immediately and a hit returns at once); only when that does not satisfy the
        // requested tier, the other platforms (which need a catalogue search each).
        // Pass 0: own platform, requested tier only. Pass 1: other platforms, requested tier only, 2 s budget.
        // Pass 2: own platform again, stepping down tier by tier (only when nothing answered yet).
        let crossPlatformDeadline: TimeInterval = 2
        var crossStartedAt: Date?
        for passIndex in 0..<3 {
        if passIndex == 1 { crossStartedAt = Date() }
        if passIndex == 2, downgradedFallback != nil { break }
        var candidates: [MusicURLCandidate] = []

        // Collect all possible source/platform/quality combinations first.
        // This prevents a low-quality result from the preferred source from
        // masking a higher-quality result exposed by another enabled source.
        for (sourcePriority, source) in playbackSources.enumerated() {
            guard await activate(source) else {
                failures.append("\(source.name): unavailable")
                continue
            }
            let platforms = sourceCandidates(for: track, action: "musicUrl")
            if platforms.isEmpty {
                failures.append("\(source.name): no musicUrl platform")
                continue
            }

            for platform in platforms {
                if (platform == primaryPlatform) != (passIndex != 1) { continue }
                if passIndex == 1, let began = crossStartedAt, Date().timeIntervalSince(began) > crossPlatformDeadline { continue }
                let requestTrack: Track
                if platform == primaryPlatform {
                    requestTrack = track
                } else {
                    // IDs are platform-specific. Match the song before using
                    // a different platform's musicUrl endpoint.
                    guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else {
                        failures.append("\(source.name)/\(platform): track not found")
                        continue
                    }
                    requestTrack = matched
                }

                var supported = supportedQualityNamesForPlayback(for: requestTrack, platform: platform)
                // QQ / Kugou publish which files a song really has: name only those tiers (no doomed requests).
                let songTiers = (platform == "tx" || platform == "kg") ? await PlatformQualityInfo.shared.tiers(for: requestTrack) : nil
                if let songTiers, !songTiers.isEmpty {
                    supported = Self.qualityOrder.filter(songTiers.contains)
                }
                // Capabilities not known yet (source still loading, quality list not refreshed): ask for the
                // tier the user chose instead of silently falling back to 128k.
                var requested = supported.isEmpty
                    ? Self.normalizedQuality(Self.requestedToken(for: quality))
                    : Self.lxQuality(for: quality, supported: supported)
                // Only NetEase's protocol table lists the top tiers; other platforms stop at Hi-Res there. A
                // script may still serve more, so ask for the tier the user chose anyway (own platform, first
                // pass); if it refuses, the step-down pass falls back to what the source declares.
                let wanted = Self.normalizedQuality(Self.requestedToken(for: quality))
                if platform != "wy", !supported.isEmpty, songTiers == nil,
                   Self.qualityRank(wanted) > Self.qualityRank(requested) {
                    requested = wanted
                }
                candidates.append(MusicURLCandidate(
                    source: source,
                    sourcePriority: sourcePriority,
                    platform: platform,
                    track: requestTrack,
                    supportedQualities: supported,
                    requestedQuality: requested
                ))
            }
        }

        candidates.sort {
            let leftQuality = Self.qualityRank($0.requestedQuality)
            let rightQuality = Self.qualityRank($1.requestedQuality)
            if leftQuality != rightQuality { return leftQuality > rightQuality }
            return $0.sourcePriority < $1.sourcePriority
        }

        anyCandidate = anyCandidate || !candidates.isEmpty
        for candidate in candidates {
            // Already holding a lower-tier answer: do not keep every other source busy for long.
            if downgradedFallback != nil, Date().timeIntervalSince(startedAt) > 6 { break }
            guard await activate(candidate.source) else {
                failures.append("\(candidate.source.name)/\(candidate.platform): unavailable")
                continue
            }
            let askedRank = Self.qualityRank(candidate.requestedQuality)
            // What the user chose, not what this platform was asked for: a platform that lacks that tier is not
            // "satisfied" by its best lower one, so the other platforms get their turn (pass 1) before stepping down.
            let wantedRank = max(askedRank, Self.qualityRank(Self.normalizedQuality(Self.requestedToken(for: quality))))
            // The requested tier first, then every lower tier this source declares, best first: when the
            // song lacks the requested tier the source is asked for the next best one instead of giving up.
            var lowerTiers: [String] = []
            let ladder = candidate.supportedQualities.isEmpty
                ? ["flac24bit", "flac", "320k", "128k"]
                : candidate.supportedQualities
            for tier in ladder.map(Self.normalizedQuality) {
                let rank = Self.qualityRank(tier)
                if rank >= 0, rank < askedRank, !lowerTiers.contains(tier) { lowerTiers.append(tier) }
            }
            lowerTiers.sort { Self.qualityRank($0) > Self.qualityRank($1) }
            // The step-down pass does not repeat an undeclared tier that pass 0 already asked for.
            let declaredLadder = ladder.map(Self.normalizedQuality)
            let firstTier = passIndex == 2 && !declaredLadder.contains(candidate.requestedQuality) ? [] : [candidate.requestedQuality]
            for tier in firstTier + (passIndex == 2 ? lowerTiers : []) {
                if passIndex == 1, let began = crossStartedAt, Date().timeIntervalSince(began) > crossPlatformDeadline { break }
                do {
                    let response = try await request(
                        source: candidate.platform,
                        action: "musicUrl",
                        info: [
                            "type": protocolQualityToken(tier, platform: candidate.platform),
                            "musicInfo": musicInfo(
                                for: candidate.track,
                                platform: candidate.platform,
                                qualities: candidate.supportedQualities.isEmpty
                                    ? ["128k", "320k", "flac", "flac24bit"] : candidate.supportedQualities
                            )
                        ],
                        // A tier the source never declared is only a try: do not let a slow refusal hold playback.
                        timeout: (!candidate.supportedQualities.isEmpty && !declaredLadder.contains(Self.normalizedQuality(tier))) ? 3 : 20
                    )
                    guard let data = response["data"] as? [String: Any],
                          let rawURL = data["url"] as? String,
                          let url = URL(string: rawURL),
                          let scheme = url.scheme?.lowercased(),
                          scheme == "http" || scheme == "https" else {
                        failures.append("\(candidate.source.name)/\(candidate.platform): invalid URL (\(tier))")
                        continue
                    }
                    guard !excludingURLs.contains(url.absoluteString) else {
                        failures.append("\(candidate.source.name)/\(candidate.platform): preview URL rejected")
                        continue
                    }
                    guard !Self.isPreviewResponse(data, expectedDuration: candidate.track.duration) else {
                        failures.append("\(candidate.source.name)/\(candidate.platform): preview response rejected")
                        continue
                    }

                    let actualQuality = Self.resolvedQuality(
                        data: data,
                        requested: tier,
                        available: candidate.supportedQualities.isEmpty ? [tier] : candidate.supportedQualities
                    )
                    DiagnosticLogStore.shared.append(level: .info, category: "音源请求", message: "\(candidate.platform) 请求 \(tier) → 返回 \(actualQuality)", detail: "音源：\(candidate.source.name)　轮次：\(passIndex)　返回字段 type=\((data["type"] as? String) ?? "-")")
                    // The same song can come back as Atmos on one request and as FLAC on the next (the source
                    // itself is inconsistent). Before settling for a lower tier, ask for the requested one again
                    // a couple of times: each retry costs a fraction of a second.
                    var bestURL = url
                    var bestQuality = actualQuality
                    if actualQuality != "unknown", passIndex == 0, askedRank >= wantedRank, Self.qualityRank(actualQuality) < wantedRank {
                        for _ in 0..<2 {
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            guard let again = try? await request(
                                source: candidate.platform,
                                action: "musicUrl",
                                info: [
                                    "type": protocolQualityToken(tier, platform: candidate.platform),
                                    "musicInfo": musicInfo(
                                        for: candidate.track,
                                        platform: candidate.platform,
                                        qualities: candidate.supportedQualities.isEmpty
                                            ? ["128k", "320k", "flac", "flac24bit"] : candidate.supportedQualities
                                    )
                                ]
                            ),
                                  let againData = again["data"] as? [String: Any],
                                  let againRaw = againData["url"] as? String,
                                  let againURL = URL(string: againRaw),
                                  let againScheme = againURL.scheme?.lowercased(),
                                  againScheme == "http" || againScheme == "https",
                                  !excludingURLs.contains(againURL.absoluteString),
                                  !Self.isPreviewResponse(againData, expectedDuration: candidate.track.duration) else { continue }
                            let againQuality = Self.resolvedQuality(
                                data: againData,
                                requested: tier,
                                available: candidate.supportedQualities.isEmpty ? [tier] : candidate.supportedQualities
                            )
                            if againQuality != "unknown",
                               Self.qualityRank(againQuality) > Self.qualityRank(bestQuality) {
                                bestURL = againURL
                                bestQuality = againQuality
                            }
                            if Self.qualityRank(bestQuality) >= wantedRank { break }
                        }
                    }
                    let resolved = ResolvedURL(url: bestURL, quality: bestQuality, platform: candidate.platform)
                    let actualRank = Self.qualityRank(bestQuality)
                    if bestQuality == "unknown" {
                        // The source does not say which tier it served: keep it as a fallback and do not
                        // spend more requests on this source's lower tiers.
                        if downgradedFallback == nil { downgradedFallback = resolved }
                        break
                    }
                    if actualRank >= wantedRank { return resolved }
                    // A source can claim Atmos/Master capability globally while returning a lower tier for
                    // this particular track. Keep the BEST such answer as the last resort and let the other
                    // enabled sources try for the requested tier.
                    if downgradedFallback == nil || actualRank > Self.qualityRank(downgradedFallback?.quality ?? "") {
                        downgradedFallback = resolved
                    }
                    failures.append("\(candidate.source.name)/\(candidate.platform): returned \(actualQuality), not \(tier)")
                    // The source answered (just not with the requested tier): that is its best for this song,
                    // so do not hammer its lower tiers. Lower tiers are only tried after a failed request.
                    break
                } catch {
                    DiagnosticLogStore.shared.append(level: .warning, category: "音源请求", message: "\(candidate.platform) 请求 \(tier) 失败", detail: "音源：\(candidate.source.name)　轮次：\(passIndex)　\(error.localizedDescription)")
                    failures.append("\(candidate.source.name)/\(candidate.platform): \(error.localizedDescription)")
                }
            }
        }
        }

        if let downgradedFallback { return downgradedFallback }
        if !anyCandidate && failures.isEmpty {
            throw LXError.sourceUnavailable("No enabled LX source exposes musicUrl")
        }
        throw LXError.resolveFailed(failures)
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
            let platformName = LXCatalogPlatform.displayName(for: platform)
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
            let info = musicInfo(for: track, platform: platform, qualities: supportedQualitys)
            // Probe from the top: the test reports the best tier the source really serves, not the one
            // picked in settings (which only ever asked for a single tier).
            let ladder = (supportedQualitys.isEmpty
                          ? ["jymaster", "atmos", "dolby", "flac24bit", "flac", "320k", "128k"]
                          : supportedQualitys)
                .map(Self.normalizedQuality)
                .filter { Self.qualityRank($0) >= 0 }
            var tiers: [String] = []
            for tier in ladder where !tiers.contains(tier) { tiers.append(tier) }
            tiers.sort { Self.qualityRank($0) > Self.qualityRank($1) }
            var best: String?
            for tier in tiers.prefix(8) {
                guard let response = try? await request(source: platform, action: "musicUrl",
                                                        info: ["type": protocolQualityToken(tier, platform: platform), "musicInfo": info]),
                      let data = response["data"] as? [String: Any],
                      let rawURL = data["url"] as? String,
                      let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https",
                      !Self.isPreviewResponse(data, expectedDuration: track.duration) else { continue }
                let actual = Self.resolvedQuality(data: data, requested: tier,
                                                  available: supportedQualitys.isEmpty ? [tier] : supportedQualitys)
                best = actual == "unknown" ? tier : actual
                break
            }
            if let best {
                let detail = "已通过 \(platformName) 的 musicUrl 接口，实测最高可取到：\(best)"
                let result = SourceCheckResult(status: .available, message: "音源可用", detail: detail)
                statusMessage = "\(result.message)：\(detail)"
                return result
            }
            failures.append("\(platformName)：没有返回有效播放地址")
        }

        let detail = failures.isEmpty ? "音源没有返回可播放地址。" : failures.joined(separator: "；")
        let result = SourceCheckResult(status: .unavailable,
                                       message: "音源不可用",
                                       detail: detail)
        statusMessage = "\(result.message)：\(detail)"
        return result
    }

    func resolveLyrics(for track: Track) async throws -> ResolvedLyrics {
        return try await resolveLyricsAcrossSources(for: track)
#if false
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
#endif
    }
    private func resolveLyricsAcrossSources(for track: Track) async throws -> ResolvedLyrics {
        let playbackSources = LXSourceStore.shared.playbackSources
        guard !playbackSources.isEmpty else { throw LXError.noSource }

        let primaryPlatform = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        for source in playbackSources {
            guard await activate(source) else { continue }
            for platform in sourceCandidates(for: track, action: "lyric") {
                let requestTrack: Track
                if platform == primaryPlatform {
                    requestTrack = track
                } else {
                    guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else { continue }
                    requestTrack = matched
                }

                for attempt in 0..<2 {
                    guard let response = try? await request(
                        source: platform,
                        action: "lyric",
                        info: [
                            "type": "lyric",
                            "musicInfo": musicInfo(for: requestTrack, platform: platform)
                        ]
                    ), let lyrics = await lyricPayload(from: response) else {
                        if attempt == 0 { try? await Task.sleep(for: .milliseconds(350)) }
                        continue
                    }
                    return lyrics
                }
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

    private func request(source: String, action: String, info: [String: Any],
                         timeout: TimeInterval = 20) async throws -> [String: Any] {
        guard context != nil else { throw LXError.noSource }
        let requestKey = "request__\(UUID().uuidString)"
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestKey] = continuation
            callJS(action: "request", data: ["requestKey": requestKey,
                                                "data": ["source": source, "action": action, "info": info]])
            Task { @MainActor [weak self] in
                let nanoseconds = UInt64(max(0.25, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
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
    private func waitForSourceReady(maxWait: TimeInterval = 6) async {
        guard loadedID != nil else { return }
        let attempts = max(1, Int(ceil(maxWait / 0.05)))
        for _ in 0..<attempts {
            guard !Task.isCancelled else { return }
            if !capabilities.isEmpty || context == nil || pendingInitializationID == nil { return }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
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
        // JSONSerialization throws an Objective-C exception (not a Swift
        // Error) for a scalar passed without fragment support.  LX scripts
        // legitimately call the bridge with scalar values for timers and
        // cancellation, so validate the value before serializing it.  A bad
        // provider payload is ignored instead of taking down the app.
        if let data {
            let isFragment = data is String
                || data is NSNumber
                || data is Int
                || data is Int8
                || data is Int16
                || data is Int32
                || data is Int64
                || data is UInt
                || data is UInt8
                || data is UInt16
                || data is UInt32
                || data is UInt64
                || data is Double
                || data is Float
                || data is Bool
                || data is NSNull
            let isContainerValue = data is [Any]
                || data is [String: Any]
                || data is NSArray
                || data is NSDictionary
            let isContainer = isContainerValue && JSONSerialization.isValidJSONObject(data)
            let options: JSONSerialization.WritingOptions = isContainer ? [] : [.fragmentsAllowed]
            if isContainer || isFragment,
               let json = try? JSONSerialization.data(withJSONObject: data, options: options),
               let string = String(data: json, encoding: .utf8) {
                encoded = string
            } else {
                encoded = nil
                print("[LX] ignored non-JSON bridge payload for action \(action)")
            }
        } else {
            encoded = nil
        }
        if let encoded {
            _ = function.call(withArguments: [key, action, encoded])
        } else {
            _ = function.call(withArguments: [key, action])
        }
    }

    private func sourceCandidates(for track: Track, action: String = "musicUrl") -> [String] {
        let primary = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var values: [String] = []

        // Soda Music is a playlist-import format only. Its IDs are not sent
        // to an LX source as a playable platform; imported tracks are matched
        // against the real catalogue platforms below instead.
        if primary != "sd" {
            values.append(primary)
        }

        if primary == "sd" {
            values.append(contentsOf: ["wy", "kw", "kg", "tx", "mg"])
        } else if SettingsManager.shared.enableSourcePlatformFallback {
            values.append(contentsOf: ["wy", "kw", "kg", "tx", "mg"])
        }
        var seen = Set<String>()
        return values.filter { platform in
            capabilities[platform]?.contains(action) == true && seen.insert(platform).inserted
        }
    }

    private func activate(_ source: LXSourceStore.Source,
                          waitTime: TimeInterval = 6) async -> Bool {
        guard !Task.isCancelled else { return false }
        if loadedID != source.id || context == nil {
            load(source)
        }
        await waitForSourceReady(maxWait: waitTime)
        return !Task.isCancelled
            && loadedID == source.id
            && context != nil
            && !capabilities.isEmpty
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
        case "sd", "soda", "sodamusic", "soda-music", "qishui", "qishui-music": return "sd"
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

    // Canonical LX quality tokens, ordered from lowest to highest. Source-specific
    // names are normalized into this list only when the imported source declares them.
    private static let qualityOrder = ["128k", "320k", "flac", "flac24bit", "surround", "dolby", "atmos", "jymaster"]

    func availableQualityNames(for track: Track) async -> [String] {
        // Do not serially wake every imported source when the picker opens.
        // The first three are the same priority order used for playback; a
        // later dead source can still be tested from source management.
        let playbackSources = Array(LXSourceStore.shared.playbackSources.prefix(3))
        let primaryPlatform = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var available = Set<String>()
        if let songTiers = await PlatformQualityInfo.shared.tiers(for: track) {
            // The platform's own file table is exact: no per-song probing needed.
            return Self.qualityOrder.reversed().filter(songTiers.contains)
        }
        if SettingsManager.shared.playbackSourceMode != .thirdParty {
            if primaryPlatform == "wy", NeteaseClient.shared.isLoggedIn {
                await AccountStore.shared.ensureVIPInfo()
                available.formUnion(await NeteaseAPI.officialQualityNames(
                    for: track.id,
                    duration: track.duration,
                    allowPremium: AccountStore.shared.hasActiveVIP
                ))
            } else if primaryPlatform == "tx", QQMusicSessionStore.shared.isLoggedIn {
                available.formUnion(await officialQualityNames(for: track, platform: "tx"))
            } else if primaryPlatform == "kg", KugouSessionStore.shared.isLoggedIn {
                available.formUnion(await officialQualityNames(for: track, platform: "kg"))
            } else if primaryPlatform == "kw", let songID = track.sourceMetadata["songmid"], !songID.isEmpty {
                available.formUnion(await KuwoAPI.shared.availableQualities(songID: songID))
            } else if primaryPlatform == "mg", let copyrightId = track.sourceMetadata["copyrightId"], !copyrightId.isEmpty {
                available.formUnion(await MiguAPI.shared.availableQualities(copyrightId: copyrightId))
            }
        }
        for source in playbackSources {
            guard !Task.isCancelled else { break }
            // The picker should not wait for the full playback/source startup
            // budget. Playback keeps the longer default; quality discovery can
            // retry when the source has finished initializing.
            guard await activate(source, waitTime: Self.qualityProbeTimeout) else { continue }
            let platforms = sourceCandidates(for: track, action: "musicUrl")
            // Quality probing is per-song and performs real network requests.
            // Probe the track's own catalogue first; only use one fallback
            // catalogue when that source cannot serve the primary platform.
            // This keeps the picker accurate without turning it into dozens of
            // cross-platform requests every time the sheet opens.
            let platformsToProbe = platforms.contains(primaryPlatform)
                ? [primaryPlatform]
                : Array(platforms.prefix(1))
            for platform in platformsToProbe {
                guard !Task.isCancelled else { break }
                let qualityTrack: Track
                if platform == primaryPlatform {
                    qualityTrack = track
                } else {
                    guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else { continue }
                    qualityTrack = matched
                }
                let declaredQualities = supportedQualityNames(for: qualityTrack, platform: platform)
                // `qualitys` describes what the adapter claims to support,
                // not what this particular song actually has.  Probe the
                // song's musicUrl response before exposing a quality picker;
                // otherwise a source that declares lossless/master globally
                // makes a 128K-only track advertise unavailable tiers.
                available.formUnion(await probeQualityNames(
                    source: source,
                    platform: platform,
                    track: qualityTrack,
                    declared: declaredQualities
                ))
            }
        }
        let order = Self.qualityOrder
        // The UI is best-first; protocol requests still use the canonical order.
        return order.reversed().filter(available.contains)
    }

    /// Probe account endpoints instead of presenting a hard-coded capability
    /// list. A returned URL and returned provider quality are both required,
    /// so a VIP-only or unavailable tier never appears in the picker.
    private func officialQualityNames(for track: Track, platform: String) async -> [String] {
        var result: [String] = []

        func append(_ resolvedQuality: String) {
            guard let quality = AudioQuality(lxType: resolvedQuality),
                  !result.contains(quality.lxType) else { return }
            result.append(quality.lxType)
        }

        if platform == "tx", let cookie = QQMusicSessionStore.shared.cookie {
            let songMid = track.sourceMetadata["songmid"] ?? String(track.id)
            let mediaMid = track.sourceMetadata["strMediaMid"]?.isEmpty == false
                ? track.sourceMetadata["strMediaMid"]
                : track.sourceMetadata["media_mid"]
            for requested in ["jymaster", "flac24bit", "atmos", "dolby", "flac", "320k", "128k"] {
                if let audio = try? await QQMusicAPI.shared.musicURL(
                    songMid: songMid, mediaMid: mediaMid, quality: requested, cookie: cookie
                ), isValidAudioURL(audio.url) {
                    append(audio.quality)
                }
            }
        }

        if platform == "kg", let cookie = KugouSessionStore.shared.cookie,
           let hash = track.sourceMetadata["hash"] ?? track.sourceMetadata["Hash"],
           !hash.isEmpty {
            let albumID = track.sourceMetadata["albumId"]
            let albumAudioID = track.sourceMetadata["albumAudioId"]
                ?? track.sourceMetadata["albumAudioID"]
                ?? track.sourceMetadata["mixsongid"]
            for requested in ["jymaster", "atmos", "dolby", "flac24bit", "flac", "320k", "128k"] {
                if let audio = try? await KugouAPI.shared.musicURL(
                    hash: hash, quality: requested, cookie: cookie,
                    albumID: albumID, albumAudioID: albumAudioID
                ), isValidAudioURL(audio.url) {
                    append(audio.quality)
                }
            }
        }

        return result
    }

    private func probeQualityName(
        source: LXSourceStore.Source,
        platform: String,
        track: Track,
        requested: String,
        requestedQualities: [String]
    ) async -> String? {
        let cacheKey = "\(track.playbackKey)|\(platform)|\(Self.normalizedQuality(requested))"
        if let hit = qualityProbeCache[cacheKey], Date().timeIntervalSince(hit.at) < 600 { return hit.value }
        do {
            let response = try await request(
                source: platform,
                action: "musicUrl",
                info: [
                    "type": protocolQualityToken(requested, platform: platform),
                    "musicInfo": musicInfo(
                        for: track,
                        platform: platform,
                        qualities: requestedQualities
                    )
                ],
                timeout: Self.qualityProbeTimeout
            )
            guard let data = response["data"] as? [String: Any],
                  let rawURL = data["url"] as? String,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }

            // The file itself is the evidence: read its header (FLAC sample rate / bit depth) or work out
            // the real bitrate from its size. Only when the file cannot be inspected does the source's
            // own label count.
            let label = Self.resolvedQuality(
                data: data,
                requested: requested,
                available: requestedQualities
            )
            let measured = await RemoteAudioInspector.measuredQuality(of: url, duration: track.duration)
            DiagnosticLogStore.shared.append(
                level: .info, category: "音质探测",
                message: "\(track.name) · 请求 \(requested)",
                detail: "音源标签：\(label)\n文件实测：\(measured ?? "无法读取")\n地址：\(url.host ?? "-") · .\(url.pathExtension.isEmpty ? "-" : url.pathExtension.lowercased())"
            )
            if let measured {
                qualityProbeCache[cacheKey] = (measured, Date())
                return measured
            }
            // A lossless claim is a claim about the file, and the file could not be read: do not list it.
            // (Spatial / Dolby cannot be checked from the header at all; for those the label is all there is.)
            if label == "flac" || label == "flac24bit" { return nil }
            if label != "unknown" { qualityProbeCache[cacheKey] = (label, Date()) }
            return label
        } catch {
            return nil
        }
    }

    private func probeQualityNames(
        source: LXSourceStore.Source,
        platform: String,
        track: Track,
        declared: [String]
    ) async -> Set<String> {
        guard await activate(source, waitTime: Self.qualityProbeTimeout) else { return [] }
        let all = declared.isEmpty ? ["128k"] : declared
        let startedAt = Date()
        let premiumFloor = Self.qualityRank("flac")
        let premium = all.filter { Self.qualityRank($0) >= premiumFloor }
        let everyday = all.filter { Self.qualityRank($0) < premiumFloor }

        var verified = Set<String>()
        // Stage 1: the tiers worth knowing about. A lossless / Hi-Res / Spatial file answers for every lower
        // tier too, so 320k and 128k are not probed (and not logged) at all when one of these is confirmed.
        if !premium.isEmpty {
            verified = await probeBatch(source: source, platform: platform, track: track, tiers: premium,
                                        allDeclared: all, budget: everyday.isEmpty ? 2.0 : 1.4)
            if verified.contains(where: { Self.qualityRank($0) >= premiumFloor }) {
                verified.formUnion(everyday.map(Self.normalizedQuality))
                return verified
            }
        }
        // Stage 2: nothing premium: find out which of the everyday tiers the song really has.
        let remaining = max(0.6, 2.0 - Date().timeIntervalSince(startedAt))
        verified.formUnion(await probeBatch(source: source, platform: platform, track: track,
                                            tiers: everyday.isEmpty ? all : everyday,
                                            allDeclared: all, budget: remaining))
        return verified
    }

    /// Probes the given tiers at the same time and returns what has been confirmed when all answered or the
    /// budget (seconds) ran out.
    private func probeBatch(
        source: LXSourceStore.Source,
        platform: String,
        track: Track,
        tiers: [String],
        allDeclared: [String],
        budget: TimeInterval
    ) async -> Set<String> {
        guard !tiers.isEmpty else { return [] }
        let box = QualityProbeBox(count: tiers.count)
        var tasks: [Task<Void, Never>] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.continuation = continuation
            for requested in tiers {
                tasks.append(Task { @MainActor [weak self] in
                    if let self, !Task.isCancelled,
                       let actual = await self.probeQualityName(
                        source: source,
                        platform: platform,
                        track: track,
                        requested: requested,
                        requestedQualities: allDeclared
                       ) {
                        box.verified.insert(actual)
                    }
                    box.remaining -= 1
                    if box.remaining <= 0 { box.finish() }
                })
            }
            tasks.append(Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                box.finish()
            })
        }
        tasks.forEach { $0.cancel() }
        return box.verified
    }

    private func isValidAudioURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Return the qualities that can safely be requested for this track.
    ///
    /// LX source `qualitys` describes the source adapter's capabilities, while
    /// catalogue file sizes describe the individual song.  Use both when the
    /// catalogue knows the song.  When it does not, the declaration is only a
    /// probe candidate; `probeQualityNames` must receive a matching URL and
    /// returned quality before the tier reaches the UI.
    /// Like `supportedQualityNames`, but an unknown capability stays unknown (empty) instead of being
    /// pretended to be "128k only": playback then asks for the tier the user chose and walks down from there.
    private func supportedQualityNamesForPlayback(for track: Track, platform: String) -> [String] {
        let order = Self.qualityOrder
        let declared = qualityCapabilities[platform, default: []]
            .map { Self.normalizedQuality($0) }
            .filter { order.contains($0) }
        let concrete = Self.qualityNames(for: track)
        if declared.isEmpty { return order.filter(concrete.contains) }
        let sourceNames = order.filter(declared.contains)
        if !concrete.isEmpty { return order.filter { sourceNames.contains($0) && concrete.contains($0) } }
        return sourceNames
    }

    private func supportedQualityNames(for track: Track, platform: String) -> [String] {
        let order = Self.qualityOrder
        let declared = qualityCapabilities[platform, default: []]
            .map { Self.normalizedQuality($0) }
            .filter { order.contains($0) }
        let sourceNames = declared.isEmpty ? ["128k"] : order.filter(declared.contains)
        let concrete = Self.qualityNames(for: track)

        if !concrete.isEmpty {
            return order.filter { sourceNames.contains($0) && concrete.contains($0) }
        }

        return sourceNames
    }

    /// Preserve the token expected by the selected LX script. The UI treats
    /// aliases such as master/jymaster as one tier, but the request keeps the
    /// exact token advertised by the active source.
    private func protocolQualityToken(_ quality: String, platform: String) -> String {
        let canonical = Self.normalizedQuality(quality)
        if let declared = qualityCapabilities[platform, default: []].first(where: { Self.normalizedQuality($0) == canonical }) {
            return declared
        }
        // Not declared by the source: LX's current protocol names the top tier `master` (`jymaster` is NetEase's
        // old spelling), which is what sources accept for Kuwo / Kugou / QQ / Migu.
        return canonical == "jymaster" ? "master" : quality
    }

    private func musicInfo(for track: Track, platform: String,
                           qualities requestedQualities: [String]? = nil) -> [String: Any] {
        // LX's User API receives the legacy MusicInfo object, not Kumone's
        // internal Track. This mirrors LX Mobile's toOldMusicInfo() exactly.
        let songmid = track.sourceMetadata["songmid"]
            ?? track.sourceMetadata["songId"]
            ?? String(track.id)
        let albumID = track.sourceMetadata["albumId"] ?? String(track.album.id)
        let canonicalQualities = requestedQualities?.isEmpty == false
            ? requestedQualities!
            : (Self.qualityNames(for: track).isEmpty ? ["128k"] : Self.qualityNames(for: track))
        let qualities = canonicalQualities.map { protocolQualityToken($0, platform: platform) }
        let qualityInfo = canonicalQualities.enumerated().map { index, canonical in
            let protocolToken = qualities[index]
            let size = track.sourceMetadata["lx.quality.\(canonical).size"]
                ?? track.sourceMetadata["lx.quality.\(protocolToken).size"]
                ?? ""
            return ["type": protocolToken, "size": size] as [String: Any]
        }
        let qualityMap = Dictionary(uniqueKeysWithValues: canonicalQualities.enumerated().map { index, canonical in
            let protocolToken = qualities[index]
            let size = track.sourceMetadata["lx.quality.\(canonical).size"]
                ?? track.sourceMetadata["lx.quality.\(protocolToken).size"]
                ?? ""
            return (protocolToken, ["size": size] as [String: Any])
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
            info["albumId"] = track.sourceMetadata["albumId"] ?? albumID
            info["albumAudioId"] = track.sourceMetadata["albumAudioId"]
                ?? track.sourceMetadata["albumAudioID"]
                ?? track.sourceMetadata["mixsongid"]
        case "tx":
            info["songId"] = Int(track.sourceMetadata["id"] ?? "") ?? track.id
            info["strMediaMid"] = track.sourceMetadata["strMediaMid"]?.isEmpty == false
                ? track.sourceMetadata["strMediaMid"]!
                : (track.sourceMetadata["media_mid"] ?? "")
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
        let order = Self.qualityOrder
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

    /// The protocol token for a picker tier.
    private static func requestedToken(for quality: String) -> String {
        switch quality {
        case "master": return "jymaster"
        case "atmos": return "atmos"
        case "dolby": return "dolby"
        case "surround": return "surround"
        case "standard": return "128k"
        case "higher", "exhigh": return "320k"
        case "lossless": return "flac"
        case "hires": return "flac24bit"
        default: return "320k"
        }
    }

    private static func lxQuality(for quality: String, supported: [String]) -> String {
        let requested = requestedToken(for: quality)
        guard !supported.isEmpty else { return "128k" }
        let order = Self.qualityOrder
        guard let requestedIndex = order.firstIndex(of: Self.normalizedQuality(requested)) else { return supported[0] }
        return order[...requestedIndex].reversed().first(where: supported.contains)
            ?? supported.first
            ?? "128k"
    }
    private static func qualityRank(_ value: String) -> Int {
        qualityOrder.firstIndex(of: normalizedQuality(value)) ?? -1
    }
    private static func normalizedQuality(_ value: String) -> String {
        let value = value.lowercased().replacingOccurrences(of: " ", with: "")
        switch value {
        case "128", "128k", "mp3": return "128k"
        case "320", "320k": return "320k"
        case "flac", "lossless", "ape": return "flac"
        case "flac24", "flac24bit", "hires", "highres": return "flac24bit"
        case "master", "jymaster", "master_quality", "master-quality": return "jymaster"
        case "atmos", "immersive": return "atmos"
        case "dolby", "dolby-atmos", "dolbyatmos": return "dolby"
        case "surround", "spatial", "spatial-audio": return "surround"
        default: return value
        }
    }
    private static func resolvedQuality(data: [String: Any], requested: String,
                                       available: [String]) -> String {
        let returned = (data["type"] as? String)
            ?? (data["quality"] as? String)
            ?? (data["format"] as? String)
        // A few adapters return a quality label from their global capability
        // table while the song response contains the real bitrate. Prefer the
        // track-level bitrate whenever it is available.
        if let bitrate = responseBitrate(data) {
            let bitrateQuality: String
            switch bitrate {
            case 900_000...: bitrateQuality = "flac24bit"
            case 600_000..<900_000: bitrateQuality = "flac"
            case 300_000..<600_000: bitrateQuality = "320k"
            // The app has no separate 192-kbps picker tier.  Keep the
            // response below 320 kbps on the safe standard label rather than
            // claiming the 320-kbps `higher` alias.
            case 160_000..<300_000: bitrateQuality = "128k"
            default: bitrateQuality = "128k"
            }
            return normalizedQuality(bitrateQuality)
        }
        // If a User API omits the returned tier we cannot truthfully label a
        // URL as Atmos/Hi-Res. Keep the result explicitly unknown; the caller
        // can still play the URL but must warn instead of showing a fake tier.
        guard let returned else { return "unknown" }
        let normalized = normalizedQuality(returned)
        // Do not fall back to the requested tier here. That was the source of
        // false "无损/母带" labels: a source could return a 128K URL (or an
        // unknown tier) while the caller had requested FLAC/Hi-Res, and this
        // method would then report the request as if it were the response.
        // The picker may still show capabilities, but the playing track must
        // only show a tier explicitly returned by this request.
        guard Self.qualityOrder.contains(normalized),
              available.contains(normalized) || normalized == "128k" else {
            return "unknown"
        }
        return normalized
    }

    private static func responseBitrate(_ data: [String: Any]) -> Int? {
        for key in ["br", "bitrate", "bit_rate", "bitrate_kbps"] {
            if let value = data[key] as? NSNumber {
                let raw = value.doubleValue
                guard raw > 0 else { continue }
                return Int(raw < 1_000 ? raw * 1_000 : raw)
            }
            if let value = data[key] as? String,
               let raw = Double(value), raw > 0 {
                return Int(raw < 1_000 ? raw * 1_000 : raw)
            }
        }
        return nil
    }

    private static func isPreviewResponse(_ data: [String: Any],
                                          expectedDuration: TimeInterval) -> Bool {
        guard expectedDuration >= 60 else { return false }
        let keys = ["duration", "durationMs", "duration_ms", "time", "playTime", "play_time"]
        let milliseconds: Double? = keys.lazy.compactMap { key in
            if let value = data[key] as? NSNumber { return value.doubleValue }
            if let value = data[key] as? String { return Double(value) }
            return nil
        }.first
        guard let milliseconds, milliseconds > 0 else { return false }
        let seconds = milliseconds > 1_000 ? milliseconds / 1_000 : milliseconds
        return seconds <= 35 || seconds < expectedDuration * 0.6
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

/// Looks at the first bytes of an audio URL to tell what it really is, instead of trusting a label.
enum RemoteAudioInspector {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    /// A canonical tier ("flac24bit", "flac", "320k", "128k") measured from the file, or nil when the
    /// file cannot be fetched or recognised.
    static func measuredQuality(of url: URL, duration: TimeInterval) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        // Stream and stop after the first 64 KB: a server that ignores Range would otherwise send the whole file.
        guard let (stream, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else { return nil }
        var head: [UInt8] = []
        do {
            for try await byte in stream {
                head.append(byte)
                if head.count >= 65_536 { break }
            }
        } catch {
            if head.count < 32 { return nil }
        }
        guard head.count >= 32 else { return nil }
        let bytes = Array(head.prefix(64))
        let data = head

        // FLAC: "fLaC", then the STREAMINFO block carries sample rate, channels and bit depth.
        if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) {
            let rate = (Int(bytes[18]) << 12) | (Int(bytes[19]) << 4) | (Int(bytes[20]) >> 4)
            let channels = ((Int(bytes[20]) >> 1) & 7) + 1
            let bits = (((Int(bytes[20]) & 1) << 4) | (Int(bytes[21]) >> 4)) + 1
            guard rate > 0 else { return nil }
            // Only what the header proves: more than two channels is surround, 24-bit at 176.4 kHz or
            // above is Master-class, any other 24-bit / high-rate file is Hi-Res, the rest is CD lossless.
            // A stereo 24-bit FLAC is never "Spatial", whatever the source calls it.
            if channels >= 3 { return "surround" }
            if bits >= 24, rate >= 176_400 { return "jymaster" }
            return (bits >= 24 || rate > 48_000) ? "flac24bit" : "flac"
        }

        // Everything else: bitrate = bytes * 8 / seconds, which needs the total length and the duration.
        let total = totalLength(of: http, received: data.count)
        guard duration >= 30, let total, total > 0 else { return nil }
        let bitrate = Double(total) * 8 / duration
        // MP3 only: an MP4 can hold AAC, ALAC or Dolby (E-AC-3) and the size alone cannot tell them apart.
        let isMP3 = bytes.starts(with: [0x49, 0x44, 0x33]) || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0)
        guard isMP3 else { return nil }
        if bitrate >= 280_000 { return "320k" }
        return "128k"
    }

    private static func totalLength(of response: HTTPURLResponse, received: Int) -> Int? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last, let value = Int(total) { return value }
        if response.statusCode == 200, response.expectedContentLength > 0 {
            return Int(response.expectedContentLength)
        }
        return nil
    }
}

/// Collects probe answers and lets the first of "all done" / "time is up" release the waiting caller.
@MainActor
private final class QualityProbeBox {
    var verified = Set<String>()
    var remaining: Int
    var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    init(count: Int) { remaining = count }

    func finish() {
        guard !finished else { return }
        finished = true
        continuation?.resume()
        continuation = nil
    }
}
