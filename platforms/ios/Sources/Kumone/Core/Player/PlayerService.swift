import AVFoundation
import Foundation

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// User-facing playback modes. The two shuffle variants are kept separate so
/// users can choose either a one-pass random order or a random order that
/// loops when the queue is exhausted.
enum PlaybackMode: String, CaseIterable, Identifiable {
    case sequential
    case repeatAll
    case repeatOne
    case shuffle
    case shuffleRepeat

    var id: Self { self }

    var title: String {
        switch self {
        case .sequential: return "顺序播放"
        case .repeatAll: return "列表循环"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机播放"
        case .shuffleRepeat: return "随机循环"
        }
    }

    var icon: String {
        switch self {
        case .sequential: return "arrow.right"
        case .repeatAll: return "repeat"
        case .repeatOne: return "repeat.1"
        case .shuffle, .shuffleRepeat: return "shuffle"
        }
    }

    var shuffleEnabled: Bool { self == .shuffle || self == .shuffleRepeat }

    var repeatMode: RepeatMode {
        switch self {
        case .sequential, .shuffle: return .off
        case .repeatAll, .shuffleRepeat: return .all
        case .repeatOne: return .one
        }
    }

    var next: PlaybackMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Where the current queue came from — used for scrobbling and UI affordances.
enum PlaySource: Equatable {
    case playlist(Int)
    case album(Int)
    case artist(Int)
    case daily
    case cloud
    case none

    var sourceID: Int {
        switch self {
        case .playlist(let id), .album(let id), .artist(let id): return id
        default: return 0
        }
    }
}

/// Where playback started from — listed under "Recently Played" in the Dock
/// menu, where picking one reloads it and starts playing again.
///
/// This is deliberately separate from `PlaySource`: heartbeat mode plays out
/// of the liked-songs playlist for scrobbling purposes, but as a *place* it is
/// its own thing, and the recents page has no source at all.
struct PlayContext: Codable, Hashable {
    enum Kind: String, Codable {
        /// Reloaded by id.
        case playlist, album, artist
        /// Fixed per-account entry points, each reloaded from its own API.
        case daily, cloud, recents, heartbeat, fm
    }

    let kind: Kind
    /// Zero for the fixed entry points, which have no id of their own.
    let id: Int
    let name: String

    static func playlist(id: Int, name: String) -> PlayContext {
        .init(kind: .playlist, id: id, name: name)
    }

    static func album(id: Int, name: String) -> PlayContext {
        .init(kind: .album, id: id, name: name)
    }

    static func artist(id: Int, name: String) -> PlayContext {
        .init(kind: .artist, id: id, name: name)
    }

    static var daily: PlayContext { .init(kind: .daily, id: 0, name: String(localized: "每日推荐")) }
    static var cloud: PlayContext { .init(kind: .cloud, id: 0, name: String(localized: "音乐云盘")) }
    static var recents: PlayContext { .init(kind: .recents, id: 0, name: String(localized: "最近播放")) }
    static var heartbeat: PlayContext { .init(kind: .heartbeat, id: 0, name: String(localized: "心动模式")) }
    static var fm: PlayContext { .init(kind: .fm, id: 0, name: String(localized: "私人漫游")) }

    /// Identity is the place, not its current title — a renamed playlist is
    /// still the same entry in the recents list.
    static func == (lhs: PlayContext, rhs: PlayContext) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(id)
    }
}

enum RightPanel {
    case lyrics, queue
}

/// The playback engine: queue, shuffle/repeat, personal FM, URL resolution,
/// lyrics, scrobbling. Modeled on YesPlayMusic's Player class, backed by AVPlayer.
/// High-frequency playback position, isolated so per-tick updates only
/// re-render the scrubbers/lyrics that observe it — not every view holding
/// the PlayerService.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var progress: TimeInterval = 0
}

/// Which lyric line is current.
///
/// Every lyric view used to derive this itself, which meant observing the clock
/// and re-rendering on every tick just to discover the line hadn't changed —
/// and for the now-playing page, whose body is the whole immersive layout, that
/// was five full re-evaluations a second. Computing it once here and publishing
/// only on a change turns that into one re-render per lyric line.
@MainActor
final class LyricsCursor: ObservableObject {
    @Published var activeIndex: Int?
}

@MainActor
final class PlayerService: ObservableObject {
    static let shared = PlayerService()

    // MARK: - Observable state

    @Published private(set) var queue: [Track] = []
    @Published private(set) var shuffledQueue: [Track] = []
    @Published private(set) var playNextList: [Track] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var currentTrack: Track?
    @Published private(set) var source: PlaySource = .none
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var duration: TimeInterval = 0
    /// True when the shown tier was checked against the audio file itself (not just the source's label).
    @Published private(set) var servedQualityMeasured = false
    @Published private(set) var servedQuality: String?
    /// The route that supplied the playable URL for the current track. This
    /// is intentionally separate from `servedQuality`: a third-party source
    /// can advertise a tier that the logged-in account does not own.
    @Published private(set) var servedSourceLabel: String?
    /// The resolved quality belongs to one concrete track. Keeping the key
    /// next to the label prevents a late resolver from making the next song
    /// appear to have the previous song's quality.
    @Published private(set) var servedQualityTrackKey: String?
    /// A selection made from the now-playing quality picker applies only to
    /// this playing track. The Settings value remains the default for the
    /// next track and is never overwritten by an in-player tap.
    @Published private(set) var trackQualityOverride: AudioQuality?
    @Published private(set) var unblockSource: String?
    @Published private(set) var isTrial = false
    let clock = PlaybackClock()
    let lyricsCursor = LyricsCursor()
    let sleepTimer = SleepTimer()
    /// Passthrough to the clock so existing `progress` reads/writes keep working.
    var progress: TimeInterval {
        get { clock.progress }
        set { clock.progress = newValue }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat") }
    }

    @Published private(set) var shuffleEnabled = false {
        didSet { UserDefaults.standard.set(shuffleEnabled, forKey: "player.shuffle") }
    }

    var playbackMode: PlaybackMode {
        if shuffleEnabled {
            return repeatMode == .all ? .shuffleRepeat : .shuffle
        }
        switch repeatMode {
        case .off: return .sequential
        case .all: return .repeatAll
        case .one: return .repeatOne
        }
    }
    @Published var volume: Float = 1 {
        didSet {
#if os(iOS)
            // iOS output volume is owned by the system. The visible control
            // is MPVolumeView; keep AVPlayer at unity gain so it cannot cap
            // the system volume behind the user's back.
            engine.volume = 1
#else
            engine.volume = volume
            UserDefaults.standard.set(volume, forKey: "player.volume")
#endif
        }
    }

    /// Playback speed is owned by the player so it is consistent across the
    /// full-screen player, mini-player, CarPlay and interruption resume.
    @Published var playbackRate: Float = 1 {
        didSet {
            let clamped = min(max(playbackRate, 0.5), 2.0)
            if clamped != playbackRate {
                playbackRate = clamped
                return
            }
            UserDefaults.standard.set(Double(playbackRate), forKey: "player.playbackRate")
            guard isPlaying else { return }
            engine.rate = playbackRate
            NowPlayingManager.shared.updateElapsed(progress, rate: Double(playbackRate))
        }
    }

    @Published private(set) var isFMMode = false
    @Published private(set) var fmUpcoming: [Track] = []
    /// Where playback was most recently started from, newest first —
    /// surfaced as "Recently Played" in the Dock menu.
    @Published private(set) var recentContexts: [PlayContext] = []
    @Published private(set) var lyrics: ParsedLyrics?
    @Published var activePanel: RightPanel?
    @Published var showNowPlaying = false
    /// Set by the player screen (tap on the artist); the main window pushes it onto the current tab.
    @Published var pendingDestination: Destination?

    /// Opens the artist page of one of the current track's artists and closes the player.
    func openArtist(_ artist: ArtistRef, for track: Track) {
        let source = (track.source ?? track.sourceMetadata["source"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let destination: Destination
        switch source {
        case "bili":
            ToastCenter.shared.show("哔哩哔哩 UP 主请在 B 站页面里查看")
            return
        case "", "wy", "163", "netease", "neteasecloudmusic", "cloudmusic":
            destination = artist.id > 0
                ? .artist(artist.id)
                : .lxArtist(source: .wy, name: artist.name, avatarURL: artist.picUrl)
        default:
            let key = ["qq", "qqmusic", "qq-music"].contains(source) ? "tx" : (source == "kugou" ? "kg" : source)
            guard let platform = LXCatalogPlatform(rawValue: key) else {
                ToastCenter.shared.show("暂不支持打开该平台的歌手页")
                return
            }
            destination = .lxArtist(source: platform, name: artist.name, avatarURL: artist.picUrl)
        }
        pendingDestination = destination
        showNowPlaying = false
    }

    /// The list the player is walking through (shuffled or ordered).
    var activeQueue: [Track] { shuffleEnabled ? shuffledQueue : queue }

    var upcomingTracks: [Track] {
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
        let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
        return playNextList + Array(rest.prefix(200))
    }

    var hasCurrentTrack: Bool { currentTrack != nil }

    /// Whether the system can restore something meaningful after the app has
    /// been terminated or the AVPlayer item has been released.
    var hasResumablePlayback: Bool {
        currentTrack != nil || !queue.isEmpty || !recentContexts.isEmpty
    }

    var currentQuality: AudioQuality {
        trackQualityOverride ?? SettingsManager.shared.audioQuality
    }

    func availableQualitiesForCurrentTrack(forceRefresh: Bool = false) async -> [AudioQuality] {
        guard let track = currentTrack else { return [] }
        let trackKey = track.playbackKey
#if os(iOS)
        let playbackMode = SettingsManager.shared.playbackSourceMode
        let cacheKey = qualityAvailabilityCacheKey(for: track, mode: playbackMode)
        // Every tier a probe ever confirmed for this track stays on the list: a probe that times out or
        // fails once must not make a tier disappear (and the next open bring it back).
        let known = knownQualityTiers[cacheKey] ?? []
        let refuted: Set<String> = []
        // Never offer a tier the selected source / signed-in accounts cannot deliver at all.
        let allowed = QualitySupport.allowedTiers(for: playbackMode, track: track)
        if !forceRefresh, let cached = qualityAvailabilityCache[cacheKey], cached.expiresAt > Date() {
            // A probe can finish before playback resolves the real URL and
            // cache only the safe 128K fallback. Merge the verified result for
            // this exact track into that cache hit so the picker does not stay
            // stuck on the earlier, incomplete answer.
            var servedType: String?
            if servedQualityTrackKey == trackKey, let servedQuality,
               let actualQuality = AudioQuality(lxType: servedQuality) {
                servedType = actualQuality.lxType
            }
            return AudioQuality.allCases.filter {
                $0.lxType == servedType
                    || ((cached.qualities.contains($0) || known.contains($0.lxType))
                        && !refuted.contains($0.lxType) && allowed.contains($0.lxType))
            }
        }
        var names: Set<String> = []
        let source = (track.source ?? track.sourceMetadata["source"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isNativeNetease = source.isEmpty || ["wy", "163", "netease",
                                                  "neteasecloudmusic", "cloudmusic"].contains(source)
        let isQQMusic = ["tx", "qq", "qqmusic", "qq-music"].contains(source)
        let isKugou = ["kg", "kugou"].contains(source)
        let isMigu = ["mg", "migu"].contains(source)
        let isKuwo = ["kw", "kuwo"].contains(source)
        var qualityTasks: [Task<[String], Never>] = []
        if playbackMode != .official {
            qualityTasks.append(Task { @MainActor in
                await LXUserAPIService.shared.availableQualityNames(for: track)
            })
        }
        if playbackMode != .thirdParty,
           NeteaseClient.shared.isLoggedIn,
           isNativeNetease {
            let allowNeteasePremium = AccountStore.shared.hasActiveVIP
            qualityTasks.append(Task {
                await NeteaseAPI.officialQualityNames(
                    for: track.id,
                    duration: track.duration,
                    allowPremium: allowNeteasePremium
                )
            })
        }
        if playbackMode != .thirdParty,
           QQMusicSessionStore.shared.isLoggedIn,
           isQQMusic {
            qualityTasks.append(Task { @MainActor in
                await officialQualityNames(for: track)
            })
        }
        if playbackMode != .thirdParty,
           KugouSessionStore.shared.isLoggedIn,
           isKugou {
            qualityTasks.append(Task { @MainActor in
                await officialQualityNames(for: track)
            })
        }
        if playbackMode != .thirdParty, isMigu,
           let copyrightId = track.sourceMetadata["copyrightId"], !copyrightId.isEmpty {
            qualityTasks.append(Task {
                await MiguAPI.shared.availableQualities(copyrightId: copyrightId)
            })
        }
        if playbackMode != .thirdParty, isKuwo,
           let songID = track.sourceMetadata["songmid"], !songID.isEmpty {
            qualityTasks.append(Task {
                await KuwoAPI.shared.availableQualities(songID: songID)
            })
        }
        // The picker is a convenience probe, not a reason to hold the sheet
        // open while one dead source retries. Keep all already-started probes
        // concurrent and cap the aggregate wait for this concrete track.
        let probedNames: [String] = await Self.withQualityProbeTimeout(operation: {
            var values: [String] = []
            for task in qualityTasks {
                values.append(contentsOf: await task.value)
            }
            return values
        }) ?? []
        guard !Task.isCancelled, currentTrack?.playbackKey == trackKey else {
            return []
        }
        names.formUnion(probedNames)
        names.formUnion(known)
        // A provider may return the playable URL before its capability probe
        // finishes (or expose only a lower fallback tier in the probe). Keep
        // the quality actually served for this track visible in the picker,
        // but never borrow the previous track's value.
        if servedQualityTrackKey == trackKey,
           let servedQuality,
           let actualQuality = AudioQuality(lxType: servedQuality) {
            names.insert(actualQuality.lxType)
        }
        rememberQualityTiers(names, for: cacheKey)
        var seenTypes = Set<String>()
        let servedNow: String? = (servedQualityTrackKey == trackKey)
            ? servedQuality.flatMap(AudioQuality.init(lxType:))?.lxType : nil
        let available = AudioQuality.allCases.filter {
            names.contains($0.lxType)
                && ($0.lxType == servedNow || (!refuted.contains($0.lxType) && allowed.contains($0.lxType)))
                && seenTypes.insert($0.lxType).inserted
        }
        let result = available.isEmpty ? [.standard] : available
        // Do not cache a timeout/empty-source fallback as if it were a real
        // capability result; the source may finish initializing moments later.
        // A cold source often answers only some tiers: never cache a thin result as the final answer.
        if names.count >= 3 {
            qualityAvailabilityCache[cacheKey] = QualityAvailabilityCacheEntry(
                expiresAt: Date().addingTimeInterval(30),
                qualities: result
            )
        }
        return result
#else
        return AudioQuality.allCases
#endif
    }

#if os(iOS)
    private func qualityAvailabilityCacheKey(for track: Track,
                                             mode: PlaybackSourceMode) -> String {
        let sourceIDs = LXSourceStore.shared.playbackSources
            .map(\.id)
            .joined(separator: ",")
        let accountState = [
            NeteaseClient.shared.isLoggedIn ? "wy1" : "wy0",
            AccountStore.shared.hasActiveVIP ? "wyvip1" : "wyvip0",
            QQMusicSessionStore.shared.isLoggedIn ? "tx1" : "tx0",
            KugouSessionStore.shared.isLoggedIn ? "kg1" : "kg0",
        ].joined(separator: ",")
        return [track.playbackKey, mode.rawValue, sourceIDs, accountState]
            .joined(separator: "|")
    }
#endif

    func selectQuality(_ quality: AudioQuality) {
        guard let track = currentTrack else { return }
        let resumeAt = progress
        trackQualityOverride = quality
        startPlaying(
            track,
            indexUnchanged: true,
            resumeAt: resumeAt,
            preserveTrackQualityOverride: true
        )
    }

    // MARK: - Engine

    private let engine = AVPlayer()

    /// Live playback position straight from the player, for smooth per-frame
    /// karaoke highlighting (the published `progress` is intentionally coarse).
    var livePlaybackTime: TimeInterval {
        // While a seek is still running the player keeps reporting the old position until the new one has data (seconds on a
        // slow stream): the lyrics follow the target at once instead of lagging behind it.
        if let pending = pendingSeekPosition, Date().timeIntervalSince(lastSeekRequestAt) < 8 { return pending }
        let t = engine.currentTime().seconds
        return t.isFinite ? t : progress
    }
    private var pendingSeekPosition: TimeInterval?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var resolveGeneration = 0
    /// Only the newest track may own resolver/lyrics work.  Cancelling the
    /// previous tasks also prevents rapid next/previous taps from keeping
    /// several source requests, AVAsset probes and lyric parsers alive at once.
    private var resolveTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private struct QualityAvailabilityCacheEntry {
        let expiresAt: Date
        let qualities: [AudioQuality]
    }
    private var qualityAvailabilityCache: [String: QualityAvailabilityCacheEntry] = [:]
    /// Tiers confirmed per track (and source / account state), kept across launches.
    private var knownQualityTiers: [String: Set<String>] = {
        let stored = UserDefaults.standard.dictionary(forKey: "moumusic.knownQualityTiers") as? [String: [String]] ?? [:]
        return stored.mapValues(Set.init)
    }()

    private func rememberQualityTiers(_ names: Set<String>, for key: String) {
        guard !names.isEmpty else { return }
        let before = knownQualityTiers[key] ?? []
        let after = before.union(names)
        guard after != before else { return }
        knownQualityTiers[key] = after
        if knownQualityTiers.count > 400 {
            for stale in knownQualityTiers.keys.prefix(100) where stale != key { knownQualityTiers[stale] = nil }
        }
        UserDefaults.standard.set(knownQualityTiers.mapValues { Array($0) }, forKey: "moumusic.knownQualityTiers")
    }
    private var pendingSeek: TimeInterval?
    /// URLs already found to be 30-second previews, per track, so the re-resolve asks for another one.
    private var previewRejects: [String: Set<String>] = [:]
    private var consecutiveFailures = 0
    private var scrobbled = false
    private var startScrobbled = false
#if os(iOS)
    /// Account URLs are tried for the matching catalogue before the enabled
    /// LX sources. A provider downgrade is reported using the actual tier.
    private var pendingNeteaseTrackIDs: [String: Int] = [:]

    private struct OfficialAudio {
        let url: URL
        let quality: String
        let sourceLabel: String
    }
#endif
    private var runtimeStarted = false

    private init() {
        engine.actionAtItemEnd = .pause
        sleepTimer.onDeadlineReached = { [weak self] in
            self?.pause()
            // Bilibili videos / lives play through their own player.
            NotificationCenter.default.post(name: .moumusicSleepTimerFired, object: nil)
        }
#if os(iOS)
        volume = 1
        engine.volume = 1
#else
        volume = UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.8
        engine.volume = volume
#endif
        if let storedRate = UserDefaults.standard.object(forKey: "player.playbackRate") as? Double {
            playbackRate = min(max(Float(storedRate), 0.5), 2.0)
        } else {
            playbackRate = 1
        }
        repeatMode = UserDefaults.standard.string(forKey: "player.repeat")
            .flatMap(RepeatMode.init) ?? .off
        shuffleEnabled = UserDefaults.standard.bool(forKey: "player.shuffle")
    }

    /// Starts the parts of the player that touch system audio and media
    /// services.  Keeping this out of the singleton initializer is important
    /// on iOS: SwiftUI creates shared observable objects while the app scene
    /// is still being brought up, and iOS 27 can terminate an app that calls
    /// into an audio session or remote-command center too early.
    func startRuntime() {
        guard !runtimeStarted else { return }
        runtimeStarted = true

        #if os(iOS)
        do {
            let mixOptions: AVAudioSession.CategoryOptions = UserDefaults.standard.bool(forKey: "moumusic.mixWithOthers") ? [.mixWithOthers] : []
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: mixOptions)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to activate audio session: \(error)")
        }

        // Resume after interruptions (phone calls, WeChat voice messages, …).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleAudioInterruption(note)
            }
        }
        // Pause when the output route disappears (headphones unplugged).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      SettingsManager.shared.autoPauseOnRouteChange,
                      let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                      reason == .oldDeviceUnavailable, self.isPlaying else { return }
                self.pause()
            }
        }
        #endif

        timeObserver = engine.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleepTimer.fireIfDue()
                guard !self.isScrubbing else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                // While a seek is pending the player still reports the old position: following it
                // made the lyrics jump back and forth during quick scrubbing / lyric taps.
                // Only briefly: a slow streamed seek must not freeze the lyrics while the audio keeps playing.
                if (self.seekInFlight || self.queuedSeekTarget != nil),
                   Date().timeIntervalSince(self.lastSeekRequestAt) < 0.8 { return }
                self.watchClock(seconds)

                // Self-healing: once no fade is running, the audible state must match what the UI says
                // (an interrupted fade used to leave the song playing after "pause", or silent after play).
                if Date() > self.fadeDeadline {
                    if !self.isPlaying, self.engine.timeControlStatus != .paused {
                        self.engine.pause()
                        self.engine.volume = 1
                    } else if self.isPlaying, self.engine.volume < 0.99 {
                        self.engine.volume = 1
                    }
                }

                // Lyrics need this cadence to stay in sync; the cursor itself
                // only publishes when the line actually changes.
                self.updateLyricsCursor(at: seconds)

                // The scrubber does not. Publishing the position every tick
                // re-renders it — and SwiftUI rebuilds the display list for the
                // whole tree each time — to move the thumb a fraction of a
                // pixel. Half a second is still smoother than the eye needs.
                if abs(seconds - self.progress) > 0.45 {
                    self.progress = seconds
                    NowPlayingManager.shared.updateElapsed(
                        seconds,
                        rate: self.isPlaying ? Double(self.playbackRate) : 0
                    )
                }
            }
        }

#if targetEnvironment(simulator)
        // The simulator plays through the Mac's speakers: tests and debug runs stay silent.
        engine.isMuted = true
#endif
        statusObservation = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self?.noteWaiting(player)
            }
        }
        // The item's time jumped on its own (not through our seek): a stream that reconnects and lands somewhere else is
        // one way for the lyrics to end up seconds away from the sound.
        NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pendingSeekPosition == nil, self.queuedSeekTarget == nil, !self.seekInFlight,
                      Date().timeIntervalSince(self.lastSeekRequestAt) > 2,
                      self.engine.currentTime().seconds > 1 else { return }
                DiagnosticLogStore.shared.append(
                    level: .warning, category: "播放时钟", message: "播放位置发生跳变（不是你拖动造成的）",
                    detail: String(format: "跳到 %.1f 秒 · %@", self.engine.currentTime().seconds, self.clockDetail()))
            }
        }

        try? FileManager.default.removeItem(at: Self.flacCacheDirectory)
        NowPlayingManager.shared.attach(to: self)
        restoreState()
    }

    // MARK: - Clock watch (diagnostics)

    private var clockWatch: (wall: Date, clock: TimeInterval)?
    private var lastWaitLogAt = Date.distantPast

    private func clockDetail() -> String {
        var parts = ["状态 \(engine.timeControlStatus.rawValue)", String(format: "速率 %.2f", engine.rate)]
        if let event = engine.currentItem?.accessLog()?.events.last {
            parts.append("卡顿 \(event.numberOfStalls) 次")
            if event.observedBitrate > 0 { parts.append(String(format: "下载码率 %.0f kbps", event.observedBitrate / 1000)) }
        }
        return parts.joined(separator: " · ")
    }

    /// While the song plays, the player clock must advance as fast as the wall clock. Every 10 seconds the two are compared;
    /// a difference means the clock stood still or jumped while the sound went on (or the other way round), which is what
    /// makes the lyrics drift away from the sound.
    private func watchClock(_ clock: TimeInterval) {
        // A seek moves the clock on purpose: the window starts again 2 seconds after the last one.
        guard isPlaying, !isBuffering, !isScrubbing, engine.rate > 0, !seekInFlight, queuedSeekTarget == nil,
              Date().timeIntervalSince(lastSeekRequestAt) > 2 else { clockWatch = nil; return }
        let now = Date()
        guard let start = clockWatch else { clockWatch = (now, clock); return }
        let wall = now.timeIntervalSince(start.wall)
        guard wall >= 10 else { return }
        let drift = (clock - start.clock) - wall * Double(engine.rate)
        if abs(drift) > 0.15 {
            DiagnosticLogStore.shared.append(
                level: .warning, category: "播放时钟", message: String(format: "播放时钟 %.0f 秒内与实际时间差 %+.2f 秒", wall, drift),
                detail: String(format: "正数：时钟跑在实际时间前面；负数：时钟被卡住或落后。位置 %.1f 秒 · ", clock) + clockDetail())
        }
        clockWatch = (now, clock)
    }

    private func noteWaiting(_ player: AVPlayer) {
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate, isPlaying,
              Date().timeIntervalSince(lastWaitLogAt) > 2 else { return }
        lastWaitLogAt = Date()
        DiagnosticLogStore.shared.append(
            level: .info, category: "播放时钟", message: "缓冲等待",
            detail: String(format: "位置 %.1f 秒 · 原因 %@ · ", player.currentTime().seconds, player.reasonForWaitingToPlay?.rawValue ?? "-") + clockDetail())
    }

    /// Set while the user drags the seek bar so the time observer doesn't fight the thumb.
    var isScrubbing = false

    #if os(iOS)
    private var wasPlayingBeforeInterruption = false

    private func handleAudioInterruption(_ note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                // The system already silenced us; sync our state and UI.
                isPlaying = false
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
            }
        case .ended:
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume) else { return }
            wasPlayingBeforeInterruption = false
            try? AVAudioSession.sharedInstance().setActive(true)
            engine.play()
            engine.rate = playbackRate
            isPlaying = true
            NowPlayingManager.shared.updateElapsed(progress, rate: Double(playbackRate))
        @unknown default:
            break
        }
    }
    #endif

    // MARK: - Entry points

    /// - Parameter context: the place these tracks came from. Supplying it
    ///   lists that place in the Dock menu's recently played section; callers
    ///   playing an ad-hoc selection (search results, a single track) omit it.
    func play(tracks: [Track], source: PlaySource, startAt track: Track? = nil,
              context: PlayContext? = nil) {
        guard !tracks.isEmpty else { return }
        if let context { recordRecent(context) }
        isFMMode = false
        queue = tracks
        self.source = source
        playNextList.removeAll()
        // When shuffle is already enabled, starting a playlist should not
        // silently pin the first catalogue item. An explicit `startAt` still
        // wins when the user tapped a particular song.
        let startTrack = track ?? (shuffleEnabled ? tracks.randomElement()! : tracks[0])
        if shuffleEnabled {
            reshuffle(keeping: startTrack)
            currentIndex = 0
        } else {
            currentIndex = tracks.firstIndex(where: { $0.playbackKey == startTrack.playbackKey }) ?? 0
        }
        startPlaying(activeQueue[currentIndex])
    }

    func playTrack(_ track: Track) {
        if let idx = activeQueue.firstIndex(where: { $0.playbackKey == track.playbackKey }) {
            currentIndex = idx
            startPlaying(track)
        } else {
            play(tracks: [track], source: .none)
        }
    }

    /// Insert a track right after the current one.
    func addToPlayNext(_ track: Track, playNow: Bool = false) {
        playNextList.append(track)
        if playNow || currentTrack == nil {
            advanceToNext(userInitiated: true)
        } else {
            ToastCenter.shared.show(String(localized: "已添加到下一首播放"))
        }
    }

    /// 相似歌曲: queues NetEase's similar songs (`/v1/discovery/simiSong`) after the current track.
    func queueSimilarSongs() {
        guard let track = currentTrack else { return }
        Task { @MainActor in
            let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
            var seedID: Int? = (source.isEmpty || ["wy", "163", "netease"].contains(source)) ? track.id : nil
            if seedID == nil { seedID = try? await NeteaseAPI.matchingSong(for: track, requireDuration: false)?.id }
            guard let seedID, let songs = try? await NeteaseAPI.similarSongs(id: seedID, limit: 20), !songs.isEmpty else {
                ToastCenter.shared.show("没有找到相似歌曲")
                return
            }
            let existing = Set((activeQueue + playNextList).map(\.playbackKey))
            let fresh = songs.map { $0.normalizedForLXPlayback() }.filter { !existing.contains($0.playbackKey) }
            playNextList.append(contentsOf: fresh)
            ToastCenter.shared.show("已添加 \(fresh.count) 首相似歌曲到下一首播放")
        }
    }

    @discardableResult
    func resumeLastPlayback() -> Bool {
        // The persisted queue normally restores `currentTrack` during
        // startRuntime(). Keep a defensive fallback for a remote command
        // arriving while that state is still being rebuilt.
        if currentTrack == nil, !activeQueue.isEmpty {
            let index = min(max(currentIndex, 0), activeQueue.count - 1)
            currentIndex = index
            currentTrack = activeQueue[index]
            duration = activeQueue[index].duration
            NowPlayingManager.shared.updateMetadata(for: activeQueue[index], duration: duration)
        }

        guard let track = currentTrack else {
            // A queue-less install can still have a recent playlist context.
            // Resolve it asynchronously rather than making the system Play
            // button appear broken.
            guard let context = recentContexts.first else { return false }
            play(context: context)
            return true
        }

        if isPlaying { return true }
        if engine.currentItem == nil {
            // Restored session: re-resolve the source.
            startPlaying(track, indexUnchanged: true, preserveTrackQualityOverride: true)
            return true
        }

        engine.play()
        engine.rate = playbackRate
        isPlaying = true
        NowPlayingManager.shared.updateElapsed(progress, rate: Double(playbackRate))
        persistState()
        return true
    }

    // MARK: Fade in / out (设置 → 播放设置 → 播放暂停淡入淡出)

    private var fadeTask: Task<Void, Never>?
    /// Until this moment a fade owns the player gain; afterwards the gain / pause state must match `isPlaying`.
    private var fadeDeadline = Date.distantPast
    private var fadeEnabled: Bool {
        UserDefaults.standard.object(forKey: "moumusic.fadeEnabled") as? Bool ?? true
    }

    /// Ramps the player gain; `then` runs only if the ramp was not interrupted.
    private func fadeVolume(to target: Float, duration: Double, then: (@MainActor () -> Void)? = nil) {
        fadeTask?.cancel()
        fadeDeadline = Date().addingTimeInterval(duration + 0.3)
        guard fadeEnabled, duration > 0 else {
            engine.volume = target
            then?()
            return
        }
        let start = engine.volume
        fadeTask = Task { @MainActor [weak self] in
            let steps = 16
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.engine.volume = start + (target - start) * Float(step) / Float(steps)
            }
            then?()
        }
    }

    private func pauseWithFade() {
        isPlaying = false
        AudioSpectrum.shared.reset()
        fadeVolume(to: 0, duration: 0.25) { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.engine.pause()
            self.engine.volume = 1
        }
    }

    private func resumeWithFade() {
        fadeTask?.cancel()
        if fadeEnabled { engine.volume = 0 }
        engine.play()
        engine.rate = playbackRate
        isPlaying = true
        fadeVolume(to: 1, duration: 0.45)
    }

    func togglePlayPause() {
        guard let track = currentTrack else {
            _ = resumeLastPlayback()
            return
        }
        if isPlaying {
            pauseWithFade()
        } else if engine.currentItem == nil {
            // Restored session: re-resolve the source.
            startPlaying(track, indexUnchanged: true, preserveTrackQualityOverride: true)
            return
        } else {
            resumeWithFade()
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? Double(playbackRate) : 0)
    }

    func pause() {
        pauseWithFade()
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    func next() {
        advanceToNext(userInitiated: true)
    }

    func previous() {
        if isFMMode { return }
        if progress > 4 || activeQueue.isEmpty {
            seek(to: 0)
            return
        }
        var idx = currentIndex - 1
        if idx < 0 {
            guard repeatMode == .all else {
                seek(to: 0)
                return
            }
            idx = activeQueue.count - 1
        }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    /// Recomputes the current lyric line, publishing only on a change.
    /// The lead makes a line light up just before it is sung.
    private func updateLyricsCursor(at seconds: TimeInterval) {
        let index = lyrics?.activeIndex(at: seconds + SettingsManager.shared.effectiveLyricsOffset)
        let previousIndex = lyricsCursor.activeIndex
        if index != lyricsCursor.activeIndex {
            lyricsCursor.activeIndex = index
        }
        // Keep the widget's three fields independent. Before the first timed
        // line starts, use the first lyric line instead of leaving the widget
        // with a stale placeholder (or making it look like metadata shifted
        // into the lyric/artist field).
        let snapshotLyric = index.flatMap { lyrics?.lines[$0].text }
            ?? lyrics?.lines.first?.text
        #if os(iOS)
        NowPlayingManager.shared.updateCurrentLyric(snapshotLyric)
        #endif
    }

    func refreshLyricsCursor() {
        updateLyricsCursor(at: livePlaybackTime)
    }

    /// The lyric clock settings at the moment lyrics are shown, for the diagnostic log.
    private static func lyricSyncDetail() -> String {
        #if os(iOS)
        let settings = SettingsManager.shared
        let auto = settings.automaticLyricsCompensation
        return String(format: " · 输出%@ 自动补偿%+.2f 秒 全局%+.2f 本首%+.2f", auto.route, auto.latency + auto.lead,
                      settings.lyricsOffset, settings.songLyricsOffset)
        #else
        return ""
        #endif
    }

    private func publishLyrics(_ parsed: ParsedLyrics, for track: Track, generation: Int) {
        lyrics = parsed
        DiagnosticLogStore.shared.append(
            level: .info, category: "歌词", message: parsed.hasVerbatimTimings ? "逐字歌词" : "逐句歌词",
            detail: "\(track.name) · 来源 \(track.source ?? "wy") · \(parsed.lines.count) 行" + Self.lyricSyncDetail())
        updateLyricsCursor(at: livePlaybackTime)
        checkLyricsVersion(for: track, generation: generation)

        // Many source adapters provide the original lyrics but omit the
        // translation field. Enrich the already-visible lyrics from a public
        // NetEase metadata match so English/Japanese songs can show a
        // translation when one exists, without delaying first paint.
        guard parsed.lines.contains(where: { $0.translation == nil }) else { return }
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            await self?.enrichTranslation(for: track, base: parsed, generation: generation)
        }
    }

    /// Lyric payloads of other catalogues that carry a translation for the same song.
    private func translationSources(for track: Track) async -> [ParsedLyrics] {
        var sources: [ParsedLyrics] = []
        let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
        let neteaseTrack: Track? = ["wy", "netease", "163"].contains(source)
            ? track
            : (try? await NeteaseAPI.matchingSong(for: track, requireDuration: false))
        if let neteaseTrack, let response = try? await NeteaseAPI.lyric(id: neteaseTrack.id) {
            let metadata = LyricsParser.parse(response, includeVerbatim: false)
            if !metadata.isEmpty { sources.append(metadata) }
        }
        let qqTrack: Track? = ["tx", "qq", "qqmusic"].contains(source)
            ? track
            : await LXCatalogService.matchingTrack(track, on: "tx")
        if let qqTrack, let native = try? await LXCatalogService.nativeLyrics(for: qqTrack),
           let translated = native.tlyric, !translated.isEmpty {
            let parsed = LyricsParser.parseLX(lyric: native.lyric, tlyric: translated)
            if !parsed.isEmpty { sources.append(parsed) }
        }
        return sources
    }

    private func enrichTranslation(for track: Track, base: ParsedLyrics,
                                   generation: Int) async {
        let sources = await translationSources(for: track)
        guard !sources.isEmpty, generation == resolveGeneration else { return }

        // A translation belongs to the line with the same words, not to whatever line is nearest in time: the credits at the
        // start of a song sit within a fraction of a second of the first sung line and all took its translation.
        func key(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        func sameWords(_ a: String, _ b: String) -> Bool {
            let (x, y) = (key(a), key(b))
            guard !x.isEmpty, !y.isEmpty else { return false }
            if x == y { return true }
            return min(x.count, y.count) >= 8 && x.prefix(8) == y.prefix(8)
        }
        var merged = base
        var changed = false
        for index in merged.lines.indices where merged.lines[index].translation == nil {
            let line = merged.lines[index]
            for metadata in sources {
                let match = metadata.lines
                    .filter { ($0.translation?.isEmpty == false) && abs($0.time - line.time) < 4 && sameWords($0.text, line.text) }
                    .min(by: { abs($0.time - line.time) < abs($1.time - line.time) })
                guard let translation = match?.translation else { continue }
                merged.lines[index].translation = translation
                changed = true
                break
            }
        }
        guard changed, generation == resolveGeneration else { return }
        lyrics = merged
        // Translation enrichment happens after the first lyric payload. Push
        // the merged line through the same snapshot path so the widget and
        // Live Activity do not keep the pre-enrichment placeholder.
        updateLyricsCursor(at: livePlaybackTime)
    }

    // MARK: - Local copy of a streamed FLAC

    private var flacLocalCopy: Task<LocalFLACResult, Never>?
    /// The local copies kept for songs that were played (key: the song and the quality it was played in).
    private var localFLACFiles: [String: URL] = [:]
    private var localFLACDeletion: [String: Task<Void, Never>] = [:]
    /// The copy of the song that is playing now (it is never deleted under the player).
    private var currentLocalFLACKey: String?
    /// How long a song's copy stays after the song is left: played again within this time, the copy is used at once.
    private static let localFLACKeepSeconds: UInt64 = 60

    /// The local copy of the song playing now, if it plays from one.
    var currentLocalFLACFile: URL? { currentLocalFLACKey.flatMap { localFLACFiles[$0] } }

    private func localFLACKey(for track: Track, quality: String?) -> String {
        track.playbackKey + "|" + (quality ?? "")
    }

    nonisolated private static var flacCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MoumusicFLAC", isDirectory: true)
    }

    /// What the background download of a FLAC came to: the file, or why there is none.
    struct LocalFLACResult: Sendable {
        var file: URL?
        var failure: String?
        var seconds: Double = 0
        var convertSeconds: Double = 0
    }

    /// Downloads a FLAC to the caches folder.
    nonisolated private static func downloadFLAC(_ remote: URL) async -> LocalFLACResult {
        let started = Date()
        var request = URLRequest(url: remote, timeoutInterval: 120)
        request.setValue("AppleCoreMedia/1.0.0 (iPhone; U; CPU OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let temp: URL
        let response: URLResponse
        do { (temp, response) = try await URLSession.shared.download(for: request) } catch {
            return LocalFLACResult(file: nil, failure: Task.isCancelled ? nil : "下载失败：\(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            return LocalFLACResult(file: nil, failure: "服务器返回 \(http.statusCode)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? 0
        guard size > 500_000 else {
            try? FileManager.default.removeItem(at: temp)
            return LocalFLACResult(file: nil, failure: "下载到的文件只有 \(size) 字节，不是完整音频")
        }
        try? FileManager.default.createDirectory(at: flacCacheDirectory, withIntermediateDirectories: true)
        let target = flacCacheDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        do { try FileManager.default.moveItem(at: temp, to: target) } catch {
            try? FileManager.default.removeItem(at: temp)
            return LocalFLACResult(file: nil, failure: "保存失败：\(error.localizedDescription)")
        }
        // AVFoundation lands a few seconds away from the asked position when it jumps inside a FLAC (measured: a seek to 120 s
        // decoded the sound of 111 s), although reading it from the start is exact. The same audio as lossless PCM
        // (CAF) is exact to jump in, so the player continues from that copy.
        let decoded = Date()
        guard let pcm = convertToPCM(target) else {
            try? FileManager.default.removeItem(at: target)
            return LocalFLACResult(file: nil, failure: "下载完成但转换成无损 PCM 失败")
        }
        try? FileManager.default.removeItem(at: target)
        return LocalFLACResult(file: pcm, failure: nil, seconds: Date().timeIntervalSince(started),
                               convertSeconds: Date().timeIntervalSince(decoded))
    }

    /// Reads a FLAC from its start (exact) and writes the same samples, bit depth and channel layout as PCM in a CAF file.
    nonisolated static func convertToPCM(_ flac: URL) -> URL? {
        do {
            let input = try AVAudioFile(forReading: flac)
            let format = input.processingFormat
            let bits = Int(input.fileFormat.streamDescription.pointee.mBitsPerChannel)
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVLinearPCMBitDepthKey: bits >= 24 ? 24 : 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            if let layout = format.channelLayout?.layout {
                let size = MemoryLayout<AudioChannelLayout>.size
                    + max(0, Int(layout.pointee.mNumberChannelDescriptions) - 1) * MemoryLayout<AudioChannelDescription>.size
                settings[AVChannelLayoutKey] = Data(bytes: layout, count: size)
            }
            try? FileManager.default.createDirectory(at: flacCacheDirectory, withIntermediateDirectories: true)
            let target = flacCacheDirectory.appendingPathComponent(UUID().uuidString + ".caf")
            let output = try AVAudioFile(forWriting: target, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else { return nil }
            while input.framePosition < input.length {
                if Task.isCancelled { try? FileManager.default.removeItem(at: target); return nil }
                try input.read(into: buffer, frameCount: 32768)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            return target
        } catch {
            return nil
        }
    }

    /// The song is left (another one starts, or it ended): its copy is deleted a minute later unless the song comes back.
    private func leaveLocalFLAC() {
        guard let key = currentLocalFLACKey else { return }
        currentLocalFLACKey = nil
        guard localFLACFiles[key] != nil else { return }
        localFLACDeletion[key]?.cancel()
        localFLACDeletion[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.localFLACKeepSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.currentLocalFLACKey != key else { return }
            if let file = self.localFLACFiles.removeValue(forKey: key) { try? FileManager.default.removeItem(at: file) }
            self.localFLACDeletion[key] = nil
        }
    }

    /// The kept copy of this song, if there is one; asking for it cancels its deletion.
    private func keptLocalFLAC(for key: String) -> URL? {
        guard let file = localFLACFiles[key], FileManager.default.fileExists(atPath: file.path) else {
            localFLACFiles[key] = nil
            return nil
        }
        localFLACDeletion[key]?.cancel()
        localFLACDeletion[key] = nil
        return file
    }

    /// Settings > clear cache removed the files: forget the copies that are gone (the one playing now is never removed).
    func forgetClearedLocalFLACCopies() {
        for (key, file) in localFLACFiles where !FileManager.default.fileExists(atPath: file.path) {
            localFLACDeletion[key]?.cancel()
            localFLACDeletion[key] = nil
            localFLACFiles[key] = nil
        }
    }

    /// A streamed FLAC without a seek table has its positions estimated from byte offsets: after a seek (or a reconnect)
    /// the sound can be seconds away from the position the player reports, and the lyrics follow that position. Once the
    /// same file is on the device (downloaded in the background while the song already plays), continue from it at the
    /// same position: local positions are exact, so seeks, lyric taps and the lyric clock are right from then on.
    private func swapToLocalFile(_ file: URL, key: String, replacing old: AVPlayerItem, generation: Int, downloadSeconds: Double, convertSeconds: Double) async {
        guard generation == resolveGeneration, engine.currentItem === old else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        localFLACFiles[key] = file
        currentLocalFLACKey = key
        localFLACDeletion[key]?.cancel()
        localFLACDeletion[key] = nil
        let localAsset = AVURLAsset(url: file)
        // Parsed before the hand-over, so the hand-over itself has less left to do.
        _ = try? await localAsset.load(.tracks, .duration)
        let newItem = AVPlayerItem(asset: localAsset)
        #if DEBUG && os(iOS)
        if AudioTapProbe.enabled, let audio = try? await localAsset.loadTracks(withMediaType: .audio).first {
            newItem.audioMix = AudioTapProbe.shared.makeMix(for: audio)
        }
        #endif
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: newItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleItemEnded() }
        }
        // A short fade around the hand-over: no click, and the gap is a dip in volume instead of a cut. The position is read
        // after the fade-out so that nothing between the two is skipped.
        let wasPlaying = engine.rate > 0
        if wasPlaying {
            fadeVolume(to: 0, duration: 0.05)
            try? await Task.sleep(nanoseconds: 70_000_000)
        }
        guard generation == resolveGeneration, engine.currentItem === old else { engine.volume = 1; return }
        let position = engine.currentTime()
        guard position.isValid, position.seconds.isFinite else { engine.volume = 1; return }
        let started = Date()
        lastSeekRequestAt = started  // our own jump: the clock watch must not report it
        engine.replaceCurrentItem(with: newItem)
        _ = await engine.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        lastSeekRequestAt = Date()
        guard generation == resolveGeneration, engine.currentItem === newItem else { engine.volume = 1; return }
        if wasPlaying, isPlaying {
            engine.playImmediately(atRate: playbackRate)
            fadeVolume(to: 1, duration: 0.15)
        } else {
            engine.volume = 1
        }
        clockWatch = nil
        let megabytes = Double((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0) / 1_048_576
        DiagnosticLogStore.shared.append(
            level: .info, category: "播放音质", message: "FLAC 已下载到本机、转成无损 PCM 并切换",
            detail: String(format: "下载和转换共 %.1f 秒（其中转换 %.1f 秒），在 %.1f 秒处切换，文件 %.1f MB，切换耗时 %.2f 秒；此后快进、点歌词和歌词对齐按精确位置。",
                           downloadSeconds, convertSeconds, position.seconds, megabytes, Date().timeIntervalSince(started)))
    }

    private var seekInFlight = false
    private var lastSeekRequestAt = Date.distantPast
    private var queuedSeekTarget: TimeInterval?
    private var queuedSeekCompletions: [@MainActor () -> Void] = []

    /// Chase-style seeking: while one seek is running only the newest target is kept, so scrubbing quickly
    /// never piles up requests on a streaming asset.
    func seek(to seconds: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        progress = seconds
        updateLyricsCursor(at: seconds)
        NowPlayingManager.shared.updateElapsed(
            seconds,
            rate: isPlaying ? Double(playbackRate) : 0
        )
        queuedSeekTarget = seconds
        pendingSeekPosition = seconds
        clockWatch = nil
        lastSeekRequestAt = Date()
        if let completion { queuedSeekCompletions.append(completion) }
        drainSeek()
    }

    private func drainSeek() {
        guard !seekInFlight, let target = queuedSeekTarget else { return }
        queuedSeekTarget = nil
        seekInFlight = true
        let isLocalFile = (engine.currentItem?.asset as? AVURLAsset)?.url.isFileURL ?? false
        // Exact seeks only for local files; streamed ones accept a small tolerance (exact seeks need a full index and stall for
        // seconds on a stream without one, which left the lyrics behind after a drag). The lyrics follow the position the
        // player really lands on, so the tolerance does not put them out of sync.
        let tolerance = isLocalFile ? CMTime.zero : CMTime(seconds: isScrubbing ? 0.4 : 0.5, preferredTimescale: 600)
        engine.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if self.queuedSeekTarget == nil {
                    self.pendingSeekPosition = nil
                    let landed = self.engine.currentTime().seconds
                    let took = Date().timeIntervalSince(self.lastSeekRequestAt)
                    if took > 1 || (landed.isFinite && abs(landed - target) > 0.8) {
                        DiagnosticLogStore.shared.append(
                            level: .info, category: "播放时钟", message: "定位完成",
                            detail: String(format: "要求 %.1f 秒，播放器落在 %.1f 秒，耗时 %.1f 秒 · ", target, landed, took) + self.clockDetail())
                    }
                    self.updateLyricsCursor(at: self.livePlaybackTime)
                    let completions = self.queuedSeekCompletions
                    self.queuedSeekCompletions = []
                    completions.forEach { $0() }
                    self.restoreAudioAfterSeek()
                }
                self.drainSeek()
            }
        }
    }

    /// A seek must never leave the player silent or paused behind the UI's back.
    private func restoreAudioAfterSeek() {
        guard isPlaying else { return }
        fadeTask?.cancel()
        fadeDeadline = .distantPast
        if engine.volume < 1 { engine.volume = 1 }
        if engine.timeControlStatus == .paused { engine.playImmediately(atRate: playbackRate) }
    }

    func toggleShuffle() {
        guard !isFMMode else { return }
        shuffleEnabled.toggle()
        if shuffleEnabled {
            if let current = currentTrack {
                reshuffle(keeping: current)
                currentIndex = 0
            } else if !queue.isEmpty {
                // A restored queue can exist before the current item is
                // resolved. Build the shuffled order now instead of leaving
                // `activeQueue` empty until the next play request.
                shuffledQueue = queue.shuffled()
                currentIndex = -1
            }
        } else {
            if let current = currentTrack {
                currentIndex = queue.firstIndex(where: { $0.playbackKey == current.playbackKey }) ?? 0
            } else {
                currentIndex = -1
            }
        }
        persistState()
    }

    func cycleRepeatMode() {
        guard !isFMMode else { return }
        repeatMode = repeatMode.next
    }

    /// Single-button mode cycle for the iOS minimal transport row:
    /// sequential → loop all → loop one → shuffle → sequential.
    func cyclePlaybackMode() {
        guard !isFMMode else { return }
        setPlaybackMode(playbackMode.next)
    }

    func setPlaybackMode(_ mode: PlaybackMode) {
        guard !isFMMode else { return }
        if mode.shuffleEnabled != shuffleEnabled {
            toggleShuffle()
        }
        repeatMode = mode.repeatMode
        if !queue.isEmpty { persistState() }
    }

    /// Jump to a track in the upcoming list (queue panel click).
    func jumpTo(_ track: Track) {
        if let nextIdx = playNextList.firstIndex(where: { $0.playbackKey == track.playbackKey }) {
            playNextList.removeSubrange(0...nextIdx)
            startPlaying(track, indexUnchanged: true)
            return
        }
        if let idx = activeQueue.firstIndex(where: { $0.playbackKey == track.playbackKey }) {
            currentIndex = idx
            startPlaying(track)
        }
    }

    func removeFromUpcoming(_ track: Track) {
        if let idx = playNextList.firstIndex(where: { $0.playbackKey == track.playbackKey }) {
            playNextList.remove(at: idx)
            return
        }
        if let idx = queue.firstIndex(where: { $0.playbackKey == track.playbackKey }), idx != currentIndex || shuffleEnabled {
            queue.remove(at: idx)
        }
        if let idx = shuffledQueue.firstIndex(where: { $0.playbackKey == track.playbackKey }) {
            shuffledQueue.remove(at: idx)
        }
    }

    // MARK: - Personal FM

    func startFM() {
        guard !isFMMode || !isPlaying else { return }
#if os(iOS)
        if SettingsManager.shared.homeRecommendationMode == .lx,
           LXSourceStore.shared.selectedSource == nil {
            ToastCenter.shared.show("请先在设置 → LX 音源中选择一个播放音源")
            return
        }
#endif
        recordRecent(.fm)
        isFMMode = true
        shuffleEnabled = false
        repeatMode = .off
        queue = []
        shuffledQueue = []
        playNextList = []
        currentIndex = -1
        source = .none
        Task { await fmAdvance() }
    }

    func fmNext() {
        guard isFMMode else { return }
        Task { await fmAdvance() }
    }

    func fmTrash() {
        guard isFMMode, let track = currentTrack else { return }
        Task {
            await fmAdvance()
#if os(iOS)
            guard SettingsManager.shared.homeRecommendationMode != .lx else { return }
#endif
            try? await NeteaseAPI.fmTrash(id: track.id)
        }
    }

    private func fmAdvance() async {
#if os(iOS)
        if SettingsManager.shared.homeRecommendationMode == .lx {
            guard LXSourceStore.shared.selectedSource != nil else {
                ToastCenter.shared.show("请先在设置 → LX 音源中选择一个播放音源")
                return
            }
            if fmUpcoming.isEmpty {
                let platform = SettingsManager.shared.homeRecommendationPlatform
                fmUpcoming = (try? await LXCatalogService.recommendedTracks(platform: platform, limit: 30)) ?? []
            }
            guard !fmUpcoming.isEmpty else {
                ToastCenter.shared.show("LX 漫游暂时没有歌曲，请检查网络或更换推荐平台")
                return
            }
            let track = fmUpcoming.removeFirst()
            startPlaying(track, indexUnchanged: true)
            return
        }
#endif
        if fmUpcoming.isEmpty {
            for attempt in 0..<3 {
                if let tracks = try? await NeteaseAPI.personalFM(), !tracks.isEmpty {
                    fmUpcoming = tracks
                    break
                }
                if attempt == 2 {
                    ToastCenter.shared.show(String(localized: "获取私人漫游数据失败"))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard !fmUpcoming.isEmpty else { return }
        let track = fmUpcoming.removeFirst()
        startPlaying(track, indexUnchanged: true)
        if fmUpcoming.count < 1 {
            if let more = try? await NeteaseAPI.personalFM() {
                fmUpcoming.append(contentsOf: more)
            }
        }
    }

    // MARK: - Advancing

    private func advanceToNext(userInitiated: Bool) {
        if isFMMode {
            Task { await fmAdvance() }
            return
        }
        if !playNextList.isEmpty {
            let track = playNextList.removeFirst()
            startPlaying(track, indexUnchanged: true)
            return
        }
        guard !activeQueue.isEmpty else { return }
        var idx = currentIndex + 1
        if idx >= activeQueue.count {
            guard repeatMode == .all else {
                if userInitiated {
                    ToastCenter.shared.show(String(localized: "已经是最后一首了"))
                } else {
                    isPlaying = false
                    NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                }
                return
            }
            idx = 0
        }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    private func handleItemEnded() {
        scrobbleIfNeeded(completed: true)
        if sleepTimer.consumeEndOfCurrentTrack() {
            progress = duration
            updateLyricsCursor(at: duration)
            pause()
            engine.replaceCurrentItem(with: nil)
            return
        }
        if repeatMode == .one, !isFMMode {
            scrobbled = false
            seek(to: 0)
            engine.play()
            isPlaying = true
            return
        }
        leaveLocalFLAC()
        advanceToNext(userInitiated: false)
    }

    // MARK: - Source resolution

    private func startPlaying(_ track: Track, indexUnchanged: Bool = false,
                              resumeAt: TimeInterval? = nil,
                              preserveTrackQualityOverride: Bool = false) {
        resolveTask?.cancel()
        lyricsTask?.cancel()
        translationTask?.cancel()
        let track = track.normalizedForLXPlayback()
        // Each song keeps the lyric offset the user dialled in for it.
        SettingsManager.shared.songLyricsOffset = SongLyricOffsetStore.shared.offset(for: track.playbackKey)
        if !preserveTrackQualityOverride {
            trackQualityOverride = nil
        }
        // Capture the request for this track before launching the async
        // resolver. Reading `currentQuality` inside that task is racy: a fast
        // next/previous tap can replace the current track and its override
        // before the old task gets scheduled, making the new song inherit the
        // previous song's lossless request.
        let requestedQuality = currentQuality
        // Stop and detach the previous item before starting an asynchronous
        // URL/lyric resolution. Otherwise a fast next/previous tap leaves the
        // old AVPlayerItem audible until the new source responds.
        engine.pause()
        engine.replaceCurrentItem(with: nil)
        if let old = endObserver {
            NotificationCenter.default.removeObserver(old)
            endObserver = nil
        }
        scrobbleIfNeeded(completed: false)
        currentTrack = track
        progress = resumeAt ?? 0
        pendingSeek = resumeAt
        duration = track.duration
        servedQuality = nil
        servedSourceLabel = nil
        servedQualityTrackKey = nil
        unblockSource = nil
        isTrial = false
        lyrics = nil
        scrobbled = false
        startScrobbled = false
        isPlaying = true
        lyricsCursor.activeIndex = nil
        // Before the URL is even resolved: holds the bars still rather than
        // letting them fall back to the decorative animation for the moment it
        // takes to find out whether this source can be tapped.
        AudioSpectrum.shared.beginPreparing()
        resolveGeneration += 1
        let generation = resolveGeneration

        NowPlayingManager.shared.updateMetadata(for: track, duration: track.duration)
        persistState()

        resolveTask = Task { [weak self] in
            guard let self else { return }
            await self.resolveAndLoad(
                track,
                generation: generation,
                requestedQuality: requestedQuality
            )
        }
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            await self.loadLyrics(for: track, generation: generation)
            // A lyric lookup that came back empty is often just a failed request: try again twice more.
            for delay in [2_500_000_000, 6_000_000_000] as [UInt64] {
                guard !Task.isCancelled, generation == self.resolveGeneration,
                      self.lyrics == nil || self.lyrics?.isEmpty == true else { return }
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, generation == self.resolveGeneration else { return }
                await self.loadLyrics(for: track, generation: generation)
            }
        }
    }

    private func resolveAndLoad(_ track: Track, generation: Int,
                                requestedQuality: AudioQuality) async {
        guard !Task.isCancelled, generation == resolveGeneration else { return }
        let resolveStartedAt = Date()
        let quality = requestedQuality.rawValue
#if os(macOS)
        let isLXCatalogTrack = track.source != nil
#endif
        var resolvedURL: URL?
        var biliAudioDash: BiliDashTrack?
        var servedByLXQuality: String?
        var servedBySourceLabel: String?
        var servedByPlatform: String?
#if os(macOS)
        var data: SongURLData?
#endif

#if os(iOS)
        // Prefer a matching account source in automatic mode. If it fails,
        // automatic mode falls back to the enabled LX sources.
        if let local = DownloadManager.shared.record(for: track),
           FileManager.default.fileExists(atPath: local.fileURL.path) {
            resolvedURL = local.fileURL
            servedByLXQuality = local.quality
            servedBySourceLabel = "本地下载"
        } else if (track.source ?? "").lowercased() == "bili" {
            // Bilibili "listen" mode: the video's audio stream plays through the
            // same player as every other song.
            do {
                let cookie = BilibiliSessionStore.shared.cookie
                // Listening only needs the cid and the audio streams: two small requests instead of the full
                // video page plus its subtitle lookup.
                let bvid = track.sourceMetadata["bvid"] ?? ""
                let cid = try await BilibiliAPI.shared.firstCID(bvid: bvid, cookie: cookie)
                let audio = try await BilibiliAPI.shared.audioPlayback(bvid: bvid, cid: cid, cookie: cookie)
                resolvedURL = audio.url
                biliAudioDash = audio.dash
                servedByLXQuality = audio.quality.title
                servedBySourceLabel = "哔哩哔哩"
            } catch {
                guard !Task.isCancelled, generation == resolveGeneration else { return }
                ToastCenter.shared.show("《\(track.name)》音频读取失败：\(error.localizedDescription)")
                isPlaying = false
                return
            }
        } else {
            let sourceValue = (track.source ?? track.sourceMetadata["source"] ?? "")
                .lowercased()
            let isNativeNetease = sourceValue.isEmpty || ["wy", "163", "netease",
                                                           "neteasecloudmusic", "cloudmusic"].contains(sourceValue)
            let isQQMusic = ["tx", "qq", "qqmusic", "qq-music"].contains(sourceValue)
            let isKugou = ["kg", "kugou"].contains(sourceValue)
            // Migu's public listen route needs no account.
            let isMigu = ["mg", "migu"].contains(sourceValue)
            let isKuwo = ["kw", "kuwo"].contains(sourceValue)
            let playbackMode = SettingsManager.shared.playbackSourceMode
            let hasOfficialAccount = (isNativeNetease && NeteaseClient.shared.isLoggedIn)
                || (isQQMusic && QQMusicSessionStore.shared.isLoggedIn)
                || (isKugou && KugouSessionStore.shared.isLoggedIn)
                || isMigu
                || isKuwo
            let hasLXSource = !LXSourceStore.shared.playbackSources.isEmpty
            // Automatic mode with an enabled LX source goes to the source first (one fast request); the account is
            // only the fallback. Probing the account first cost seconds and often could not deliver the top tiers.
            let thirdPartyFirst = playbackMode == .automatic && hasLXSource
            guard hasLXSource || (playbackMode != .thirdParty && hasOfficialAccount) else {
                guard generation == resolveGeneration else { return }
                ToastCenter.shared.show("请先登录账号或在设置 → LX 音源中选择播放音源")
                isPlaying = false
                return
            }
            // 自动模式：账号只能给出比所选音质低的档位（例如非会员选了环绕声 / 母带，只拿到 320k）时，
            // 先记下账号的结果，再向三方音源要所选音质；三方没有更好的才用回账号的结果。
            var officialFallback: OfficialAudio?
            if playbackMode != .thirdParty, hasOfficialAccount, !thirdPartyFirst,
               let official = await resolveOfficialAudio(
                for: track, quality: requestedQuality
               ) {
                resolvedURL = official.url
                servedByLXQuality = official.quality
                servedBySourceLabel = official.sourceLabel
                if playbackMode == .automatic, hasLXSource,
                   let servedRank = Self.qualityRank(official.quality),
                   let wantedRank = Self.qualityRank(requestedQuality.lxType), servedRank > wantedRank {
                    officialFallback = official
                    resolvedURL = nil
                }
            }

            // Account-only mode normally never leaves the account. A free account playing a
            // VIP song may opt in (Settings) to a third-party source, with a notice.
            let isVIPSong = track.fee == 1 || track.fee == 4
            let accountIsVIP = isNativeNetease ? AccountStore.shared.hasActiveVIP
                : (isQQMusic ? (QQMusicSessionStore.shared.isVIP == true)
                   : (isKugou ? KugouSessionStore.shared.isVIP : false))
            let vipFallbackAllowed = playbackMode == .official && resolvedURL == nil && isVIPSong
                && !accountIsVIP && hasLXSource
                && UserDefaults.standard.bool(forKey: "moumusic.vipThirdPartyFallback")
            if vipFallbackAllowed {
                ToastCenter.shared.show("当前账号不是会员，正在使用第三方音源播放会员歌曲")
            } else if resolvedURL == nil, playbackMode == .official, isVIPSong, !accountIsVIP {
                ToastCenter.shared.show("会员歌曲需要会员账号；可在设置里开启「账号模式下用第三方音源播放会员歌曲」")
            }

            if resolvedURL == nil, playbackMode != .official || vipFallbackAllowed, hasLXSource {
            do {
                var resolved: LXUserAPIService.ResolvedURL?
                var lastError: Error?
                var rejectedPreviewURLs = previewRejects[track.playbackKey] ?? []
                // A signed source URL can expire or fail once while the
                // provider is waking up. Retry the same track once before
                // reporting a playback failure; advancing the queue here
                // would make an intermittent QQ result look like a wrong song.
                // A few third-party endpoints return a 30-second audition
                // URL even when asked for Atmos/Master. Probe the resulting
                // asset before handing it to AVPlayer, then ask the remaining
                // enabled source candidates for a full-length stream.
                for attempt in 0..<4 {
                    guard !Task.isCancelled, generation == resolveGeneration else { return }
                    do {
                        let candidate = try await LXUserAPIService.shared.resolveMusicURL(
                            for: track,
                            quality: quality,
                            excludingURLs: rejectedPreviewURLs,
                            forceThirdParty: vipFallbackAllowed
                        )
                        // Preview clips are caught after playback starts (see the duration check below), not by a
                        // network probe that used to delay every start by up to 4 s.
                        resolved = candidate
                        break
                    } catch {
                        lastError = error
                        if attempt < 3 {
                            try? await Task.sleep(for: .milliseconds(350))
                        }
                    }
                }
                guard let resolved else {
                    throw lastError ?? LXUserAPIService.LXError.resolveFailed([])
                }
                resolvedURL = resolved.url
                servedByLXQuality = resolved.quality
                servedBySourceLabel = "LX 第三方音源"
                servedByPlatform = resolved.platform
                if let officialFallback,
                   let officialRank = Self.qualityRank(officialFallback.quality),
                   let thirdRank = Self.qualityRank(resolved.quality), thirdRank >= officialRank {
                    // The third-party source did not beat the account's tier: keep the account stream.
                    resolvedURL = officialFallback.url
                    servedByLXQuality = officialFallback.quality
                    servedBySourceLabel = officialFallback.sourceLabel
                    servedByPlatform = nil
                }
                // Only the account-mode fallback is worth a notice: with a third-party source chosen
                // on purpose, "会员歌曲将通过第三方音源播放" is just noise.
                if vipFallbackAllowed, (track.fee == 1 || track.fee == 4),
                   UserDefaults.standard.object(forKey: "moumusic.vipReminder") as? Bool ?? true {
                    ToastCenter.shared.show("会员歌曲，已通过第三方音源播放")
                }
            } catch {
                guard !Task.isCancelled, generation == resolveGeneration else { return }
                var rescue = officialFallback
                if rescue == nil, thirdPartyFirst, hasOfficialAccount {
                    rescue = await resolveOfficialAudio(for: track, quality: requestedQuality)
                }
                if let officialFallback = rescue {
                    // Nothing better than the account's own tier was found: play that.
                    resolvedURL = officialFallback.url
                    servedByLXQuality = officialFallback.quality
                    servedBySourceLabel = officialFallback.sourceLabel
                } else {
                consecutiveFailures += 1
                DiagnosticLogStore.shared.append(
                    level: .error,
                    category: "Playback",
                    message: "播放失败",
                    detail: error.localizedDescription
                )
                ToastCenter.shared.show("《\(track.name)》播放失败：\(error.localizedDescription)")
                // A source-level error is not fixed by immediately trying five
                // more queue entries. Keep the current song visible so the user
                // can adjust the source or retry after reading the real error.
                isPlaying = false
                return
                }
            }
            }
        }
#else
        if resolvedURL == nil, !isLXCatalogTrack {
            data = try? await NeteaseAPI.songURL(ids: [track.id], level: quality).first
            if data?.url == nil, quality != AudioQuality.standard.rawValue {
                data = try? await NeteaseAPI.songURL(ids: [track.id], level: AudioQuality.standard.rawValue).first
            }
            if let urlString = data?.url {
                resolvedURL = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
            }
        }
        guard generation == resolveGeneration else { return }

        // Keep the legacy desktop-only fallback isolated from iOS. iOS must
        // never silently turn a failed source request into a Kuwo URL.
        if resolvedURL == nil || data?.freeTrialInfo != nil, SettingsManager.shared.enableUnblock {
            if let unblocked = await UnblockService.resolve(track) {
                guard generation == resolveGeneration else { return }
                resolvedURL = unblocked.url
                unblockSource = unblocked.source
                data = nil
                ToastCenter.shared.show(String(localized: "已使用第三方音源：\(unblocked.source)"))
            }
        }
#endif

        guard generation == resolveGeneration else { return }

        guard let url = resolvedURL else {
            consecutiveFailures += 1
            let reason = track.playability(privilege: nil,
                                           isLoggedIn: AccountStore.shared.isLoggedIn,
                                           vipType: AccountStore.shared.vipType).reason
            let detail = reason ?? (lastOfficialFailure.isEmpty ? nil : "账号音源未返回完整音频（\(String(lastOfficialFailure.prefix(80)))）")
            ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放\(detail.map { "：\($0)" } ?? "")"))
            if consecutiveFailures < 5 {
                advanceToNext(userInitiated: false)
            } else {
                isPlaying = false
            }
            return
        }

        consecutiveFailures = 0
#if os(iOS)
        // Do not publish the requested/provider-advertised tier yet.  Some
        // sources return an Atmos/Master capability label for a URL that is
        // actually ordinary Hi-Res or even 320K.  The player UI will receive
        // the verified result after AVFoundation has loaded the audio track.
        servedQuality = nil
        servedSourceLabel = servedBySourceLabel
        servedQualityTrackKey = nil
#else
        servedQuality = servedByLXQuality ?? data?.level
        servedQualityTrackKey = track.playbackKey
        if data?.freeTrialInfo != nil {
            isTrial = true
            ToastCenter.shared.show(String(localized: "VIP 歌曲，当前为试听片段"))
        }
#endif

        // Resolve the asset's audio track before the item goes live: an audio mix
        // attached after playback starts is silently ignored, so the spectrum tap
        // has to be spliced in here or not at all. Sources that refuse byte-range
        // requests never resolve a track — those play untapped and the UI falls
        // back to its decorative animation.
        let asset: AVURLAsset
        // The previous song is left now (its copy goes in a minute); a copy kept for THIS song is played from at once.
        let localKey = localFLACKey(for: track, quality: servedByLXQuality)
        leaveLocalFLAC()
        let keptCopy: URL? = (!url.isFileURL && url.pathExtension.lowercased() == "flac") ? keptLocalFLAC(for: localKey) : nil
        if let keptCopy {
            asset = AVURLAsset(url: keptCopy)
            currentLocalFLACKey = localKey
            DiagnosticLogStore.shared.append(level: .info, category: "播放音质", message: "使用上次留下的本地 FLAC 副本",
                                             detail: "\(track.name)：不用重新下载，位置精确。")
        } else if (track.source ?? "").lowercased() == "bili" {
            let biliUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
#if os(iOS)
            // Listen mode plays the DASH audio as audio-only HLS (like the video player does): a raw .m4s URL
            // handed to AVPlayer often never loads (time stays at 0:00), and gives no real duration or seeking.
            if let biliAudioDash {
                asset = BiliHLSLoader.audioAsset(for: biliAudioDash, userAgent: biliUserAgent)
            } else {
                asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": [
                    "Referer": "https://www.bilibili.com/", "User-Agent": biliUserAgent]])
            }
#else
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": [
                "Referer": "https://www.bilibili.com/", "User-Agent": biliUserAgent]])
#endif
        } else {
            // Precise timing for MP3 (VBR seeks otherwise land on an estimated byte offset and the lyrics drift); on other
            // remote formats it makes AVPlayer scan the stream first, which froze loading and fast scrubbing. A streamed
            // FLAC has the same estimate problem, but asking AVPlayer for precise timing froze the player on some
            // networks: a FLAC plays from the stream at once and is copied to the device in the background instead
            // (`swapToLocalFile`), where positions are exact.
            if url.pathExtension.lowercased() == "mp3" {
                asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            } else {
                asset = AVURLAsset(url: url)
            }
        }
        // Start streaming immediately: AVPlayer buffers while it plays. The audio track is
        // probed in the background afterwards (spectrum tap + verified quality) instead of
        // delaying the first sound.
        guard generation == resolveGeneration else { return }

#if os(iOS)
        servedQualityMeasured = false
        servedQuality = verifiedServedQuality(
            providerQuality: servedByLXQuality,
            audioTrack: nil
        )
        servedQualityTrackKey = track.playbackKey
        NowPlayingManager.shared.updateResolvedQuality(servedQuality, for: track)
#endif

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0
        AudioSpectrum.shared.markUntappable()

        if let old = endObserver {
            NotificationCenter.default.removeObserver(old)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleItemEnded()
            }
        }
        // A pause fade still running from the previous track must not leave the gain low.
        fadeTask?.cancel()
        engine.volume = 1
        engine.replaceCurrentItem(with: item)
        let seekPosition = pendingSeek
        pendingSeek = nil
        if let seekPosition, seekPosition > 0 {
            // Resuming at a position after a quality switch: an exact seek on a freshly attached stream waits for
            // that byte range before anything plays, and starting only after it finished left playback hanging
            // until the user nudged it. Seek loosely and start right away; AVPlayer applies the seek as data arrives.
            engine.automaticallyWaitsToMinimizeStalling = false
            engine.seek(to: CMTime(seconds: seekPosition, preferredTimescale: 600), completionHandler: { _ in })
            engine.playImmediately(atRate: playbackRate)
        } else {
            // Pure online streaming: start as soon as the first data arrives instead of
            // waiting for AVPlayer to buffer ahead; nothing is written to disk.
            engine.automaticallyWaitsToMinimizeStalling = false
            fadeTask?.cancel()
            if fadeEnabled { engine.volume = 0 }
            engine.playImmediately(atRate: playbackRate)
            fadeVolume(to: 1, duration: 0.6)
        }
        isPlaying = true

        let providerQualitySnapshot = servedByLXQuality
        let sourceLabelSnapshot = servedBySourceLabel
        let servedPlatformSnapshot = servedByPlatform
        let resolveSeconds = Date().timeIntervalSince(resolveStartedAt)
        let urlHost = url.host ?? "-"
        let urlExtension = url.pathExtension.isEmpty ? "-" : url.pathExtension.lowercased()
        flacLocalCopy?.cancel()
        flacLocalCopy = nil
        var localCopy: Task<LocalFLACResult, Never>?
        if keptCopy == nil, urlExtension == "flac", !url.isFileURL, (track.source ?? "").lowercased() != "bili",
           UserDefaults.standard.object(forKey: "moumusic.lyrics.preciseFLAC") as? Bool ?? true {
            let remote = url
            let copy = Task.detached(priority: .utility) { await Self.downloadFLAC(remote) }
            flacLocalCopy = copy
            localCopy = copy
        }
        let localCopyForSwap = localCopy
        Task { [weak self, weak item] in
            guard let self else { return }
            let probed = await self.loadAudioTrack(from: asset, timeout: 6)
            guard generation == self.resolveGeneration, let item, self.engine.currentItem === item else { return }
#if os(iOS)
            // The label comes from the stream itself: codec, sample rate, channel count and data rate of
            // the track AVFoundation decodes. A tier the source claims is only shown when those facts
            // support it; when the track cannot be read at all the source's own label stays (unverified).
            let measured = await Self.measuredQuality(claimed: providerQualitySnapshot, track: probed)
            // AVFoundation often cannot read a streamed FLAC in time: then read the file header itself.
            let fileTier: String? = measured == nil
                ? await RemoteAudioInspector.measuredQuality(of: url, duration: track.duration) : nil
            // When the file cannot be measured and the source gave no label, the file name still says a lot (QQ
            // prefixes every tier, .flac is lossless).
            let providerUnknown = providerQualitySnapshot == nil || AudioQuality.isUnknownResolvedQuality(providerQualitySnapshot ?? "")
            let urlTier = providerUnknown ? Self.tierFromURL(url) : nil
            let shown = measured ?? fileTier ?? urlTier ?? providerQualitySnapshot
            guard generation == self.resolveGeneration, self.engine.currentItem === item else { return }
            self.servedQualityMeasured = (measured != nil || fileTier != nil)
            self.servedQuality = shown
            self.servedQualityTrackKey = track.playbackKey
            // One log entry per played song: what was asked, what the source said, what the file really is.
            let facts: StreamFacts? = await {
                guard let probed else { return nil }
                return await Self.streamFacts(of: probed)
            }()
            func fourCC(_ value: UInt32) -> String {
                let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
                let text = String(bytes: bytes, encoding: .ascii) ?? ""
                return text.trimmingCharacters(in: .whitespaces).isEmpty ? String(value) : text
            }
            let factsLine = facts.map {
                "\(fourCC($0.format)) · \(Int($0.sampleRate)) Hz · \($0.bits > 0 ? "\($0.bits) bit · " : "")\($0.channels) 声道 · \(Int($0.bitrate / 1000)) kbps"
            } ?? "无法读取（沿用音源标签）"
            let requestedLabel = requestedQuality.platformLabel(track.source)
            let usedLabel = shown.flatMap(AudioQuality.init(lxType:))?.platformLabel(track.source) ?? (shown ?? "未知")
            let wasDowngraded: Bool = {
                guard let wantedRank = Self.qualityRank(requestedQuality.lxType),
                      let gotRank = Self.qualityRank(shown) else { return false }
                return gotRank > wantedRank
            }()
            // A played file that is longer / shorter than the catalogue entry is another version of the song:
            // lyrics written for the original then run early or late. Say so in the log.
            let audioSeconds = (try? await asset.load(.duration))?.seconds ?? 0
            let audioLengthLine: String = {
                guard audioSeconds.isFinite, audioSeconds > 0 else { return "时长：音频未读到" }
                let catalogue = track.duration
                let gap = catalogue > 0 ? audioSeconds - catalogue : 0
                let note = abs(gap) > 2.5 ? "（相差 \(String(format: "%+.1f", gap)) 秒：可能是另一个版本，歌词可能对不上）" : ""
                return String(format: "时长：音频 %.1f 秒 / 歌曲信息 %.1f 秒", audioSeconds, catalogue) + note
            }()
            let ownPlatform = (track.source ?? track.sourceMetadata["source"] ?? "wy").lowercased()
            // A 30-second clip for a full-length song is a preview: remember the URL and resolve again.
            if audioSeconds.isFinite, audioSeconds > 0, audioSeconds <= 35, track.duration >= 60,
               (self.previewRejects[track.playbackKey]?.count ?? 0) < 3 {
                self.previewRejects[track.playbackKey, default: []].insert(url.absoluteString)
                ToastCenter.shared.show("音源返回的是试听片段，正在换源重试")
                self.startPlaying(track, indexUnchanged: true, resumeAt: nil, preserveTrackQualityOverride: true)
                return
            }
            // The audio came from another platform and is not the same length as this song's own entry: lyrics from
            // the song's platform are timed for a different cut. Take them from the platform that served the audio.
            // With verbatim lyrics on, the lyric lookup itself picks the best platform; a second publish
            // here swapped the lyrics a moment after the first and made the lyric page reload (the flicker at the start).
            if !SettingsManager.shared.verbatimLyrics,
               let served = servedPlatformSnapshot, served != ownPlatform, audioSeconds.isFinite, audioSeconds > 0,
               abs(audioSeconds - track.duration) > 0.25 {
                Task { [weak self] in await self?.realignLyrics(for: track, servedPlatform: served, generation: generation) }
            }
            // Lyrics that run past the end of this audio belong to another cut of the song.
            if audioSeconds.isFinite, audioSeconds > 0 {
                self.servedAudio = (track.playbackKey, audioSeconds)
                self.checkLyricsVersion(for: track, generation: generation)
            }
            let platformNote: String = {
                guard let served = servedPlatformSnapshot, served != ownPlatform else { return "" }
                return "（这首歌在\(ownPlatform)没有该音质，音频取自 \(served) 平台的同一首歌）"
            }()
            DiagnosticLogStore.shared.append(
                level: wasDowngraded ? .warning : .info,
                category: "播放音质",
                message: "\(track.name) → \(usedLabel)\(wasDowngraded ? "（已降级）" : "")",
                detail: [
                    "歌曲：\(track.name) · \(track.artistNames)",
                    "平台：\(track.source ?? "wy")　来源：\(sourceLabelSnapshot ?? "-")" + platformNote,
                    "播放模式：\(SettingsManager.shared.playbackSourceMode.rawValue)",
                    "请求音质：\(requestedLabel)",
                    "音源返回标签：\(providerQualitySnapshot ?? "无")",
                    "文件实测：\(factsLine)",
                    "文件头实测：\(fileTier ?? "无")",
                    "实际使用：\(usedLabel)",
                    "地址：\(urlHost) · .\(urlExtension)",
                    String(format: "解析耗时：%.2f 秒", resolveSeconds),
                    audioLengthLine,
                ].joined(separator: "\n")
            )
            let wanted = self.currentQuality
            let spatial: [AudioQuality] = [.master, .atmos, .dolby, .surround]
            let served = (self.servedQuality ?? "").lowercased()
            let servedSpatial = ["atmos", "dolby", "surround", "master", "sky", "jyeffect", "jymaster", "spatial"].contains { served.contains($0) }
            // "音质降级时提示" in settings turns this notice off (the log entry and the picker still say it).
            if spatial.contains(wanted), !served.isEmpty, !servedSpatial,
               UserDefaults.standard.object(forKey: "moumusic.qualityDowngradeNotice") as? Bool ?? true {
                ToastCenter.shared.show("这首歌没有「\(wanted.displayName)」音源（需歌曲本身提供且账号有对应会员），已按 \(served) 播放")
            }
            NowPlayingManager.shared.updateResolvedQuality(self.servedQuality, for: track)
#endif
            // The spectrum tap is decoration: attach it only to plain stereo lossy streams. On lossless /
            // hi-res / multichannel audio a tap can leave playback silent.
            if let probed, await Self.spectrumTapIsSafe(for: probed),
               let mix = AudioSpectrum.shared.makeAudioMix(for: probed) {
                item.audioMix = mix
            }
            #if DEBUG && os(iOS)
            if AudioTapProbe.enabled, let probed { item.audioMix = AudioTapProbe.shared.makeMix(for: probed) }
            #endif
            if let localCopyForSwap {
                let result = await localCopyForSwap.value
                if let file = result.file {
                    await self.swapToLocalFile(file, key: localKey, replacing: item, generation: generation, downloadSeconds: result.seconds, convertSeconds: result.convertSeconds)
                } else if let failure = result.failure, generation == self.resolveGeneration {
                    DiagnosticLogStore.shared.append(
                        level: .warning, category: "播放音质", message: "FLAC 没能下载到本机，继续用网络播放",
                        detail: failure + "。拖动进度条后歌词可能偏几秒。")
                }
            }
        }

        if !startScrobbled {
            startScrobbled = true
#if os(iOS)
            syncListeningStart(track: track, sourceID: source.sourceID)
#else
            if AccountStore.shared.isLoggedIn {
                let tid = track.id
                let sid = source.sourceID
                Task.detached { await NeteaseAPI.scrobbleStart(trackID: tid, sourceID: sid) }
            } else {
                ListeningSyncStore.shared.markSignedOut()
            }
#endif
        }

#if os(macOS)
        if let time = data?.time, time > 0 {
            duration = TimeInterval(time) / 1000
            NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
        }
#endif
    }

#if os(iOS)
    /// Quality probing is a UI hint, not playback itself. A stalled account
    /// endpoint must not keep the picker spinning for the full playback
    /// timeout. All callers also cancel the losing task after the first result.
    private nonisolated static func withQualityProbeTimeout<T: Sendable>(
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            // No timeout: quality detection simply waits for the source to answer.
            group.addTask { await operation() }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Resolve a full-length provider URL using the account belonging to the
    /// track's catalogue. The returned quality is the provider's response.
    private var lastOfficialFailure = ""

    /// Position in the highest-to-lowest quality order (smaller = better); nil for unknown labels.
    private static func qualityRank(_ lxType: String?) -> Int? {
        guard let lxType, let quality = AudioQuality(lxType: lxType) else { return nil }
        return AudioQuality.allCases.firstIndex(of: quality)
    }

    private func resolveOfficialAudio(for track: Track, quality: AudioQuality) async -> OfficialAudio? {
        lastOfficialFailure = ""
        let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
        let requestedCandidates = qualityCandidates(startingAt: quality)

        if source.isEmpty || ["wy", "163", "netease", "neteasecloudmusic", "cloudmusic"].contains(source),
           NeteaseClient.shared.isLoggedIn {
            await AccountStore.shared.ensureVIPInfo()
            let hasActiveNeteaseVIP = AccountStore.shared.hasActiveVIP
            // Premium tiers (Hi-Res / Atmos / Master ...) are asked for together, whatever the local
            // membership flag says (it can be wrong for an SVIP account), but a tier only counts when
            // NetEase really serves that very level: for a non-member it "answers" with a downgraded
            // level, which must not pre-empt the third-party sources or the lower official tiers.
            let neteaseCandidates = requestedCandidates.filter { !$0.requiresNeteaseVIP }
            let premiumCandidates = requestedCandidates.filter(\.requiresNeteaseVIP)
            var failureNotes: [String] = []
            var obtainedAudio = false
            defer {
                if !failureNotes.isEmpty {
                    let joined = failureNotes.joined(separator: " | ")
                    lastOfficialFailure = joined
                    let obtained = obtainedAudio
                    Task { @MainActor in
                        DiagnosticLogStore.shared.append(
                            level: obtained ? .info : .warning, category: "网易云账号音源",
                            message: obtained ? "《\(track.name)》部分档位网易云未提供，已用较低档位" : "《\(track.name)》未取得完整音频",
                            detail: "会员=\(hasActiveNeteaseVIP) \(joined)")
                    }
                }
            }
            if !premiumCandidates.isEmpty {
                let songID = track.id
                let replies: [(AudioQuality, SongURLData?)] = await withTaskGroup(
                    of: (AudioQuality, SongURLData?).self
                ) { group in
                    for candidate in premiumCandidates {
                        group.addTask {
                            (candidate, (try? await NeteaseAPI.songURL(ids: [songID], level: candidate.neteaseLevel))?.first)
                        }
                    }
                    var collected: [(AudioQuality, SongURLData?)] = []
                    for await reply in group { collected.append(reply) }
                    return collected
                }
                for candidate in premiumCandidates {
                    guard let data = replies.first(where: { $0.0 == candidate })?.1 else {
                        failureNotes.append("\(candidate.neteaseLevel):接口无返回"); continue
                    }
                    guard data.freeTrialInfo == nil, let rawURL = data.url, let url = validAudioURL(rawURL) else {
                        failureNotes.append("\(candidate.neteaseLevel):无完整地址"); continue
                    }
                    guard (data.level ?? "").lowercased() == candidate.neteaseLevel.lowercased() else {
                        failureNotes.append("\(candidate.neteaseLevel):返回档位=\(data.level ?? "-")"); continue
                    }
                    guard data.time <= 0 || track.duration <= 0
                        || TimeInterval(data.time) / 1000 >= max(45, track.duration * 0.65) else {
                        failureNotes.append("\(candidate.neteaseLevel):时长不足 \(data.time)ms"); continue
                    }
                    obtainedAudio = true
                    return OfficialAudio(
                        url: url,
                        quality: NeteaseAPI.officialQuality(for: data)?.lxType ?? candidate.lxType,
                        sourceLabel: "网易云官方账号音源"
                    )
                }
            }
            for candidate in neteaseCandidates {
                guard let data = (try? await NeteaseAPI.songURL(
                    ids: [track.id], level: candidate.neteaseLevel
                ))?.first else { failureNotes.append("\(candidate.neteaseLevel):接口无返回"); continue }
                guard data.freeTrialInfo == nil else { failureNotes.append("\(candidate.neteaseLevel):仅试听"); continue }
                guard data.time <= 0 || track.duration <= 0
                    || TimeInterval(data.time) / 1000 >= max(45, track.duration * 0.65) else {
                    failureNotes.append("\(candidate.neteaseLevel):时长不足 \(data.time)ms"); continue
                }
                guard let rawURL = data.url, let url = validAudioURL(rawURL) else {
                    failureNotes.append("\(candidate.neteaseLevel):无地址 fee=\(data.fee)"); continue
                }
                obtainedAudio = true
                return OfficialAudio(
                    url: url,
                    quality: NeteaseAPI.officialQuality(for: data)?.lxType ?? "unknown",
                    sourceLabel: "网易云官方账号音源"
                )
            }
        }

        if ["tx", "qq", "qqmusic", "qq-music"].contains(source),
           QQMusicSessionStore.shared.isLoggedIn,
           let cookie = QQMusicSessionStore.shared.cookie {
            let songMid = track.sourceMetadata["songmid"] ?? String(track.id)
            let mediaMid = track.sourceMetadata["strMediaMid"]?.isEmpty == false
                ? track.sourceMetadata["strMediaMid"]
                : track.sourceMetadata["media_mid"]
            var attempted = Set<String>()
            for candidate in requestedCandidates {
                let token = qqQualityToken(for: candidate)
                guard attempted.insert(token).inserted,
                      let resolved = try? await QQMusicAPI.shared.musicURL(
                        songMid: songMid, mediaMid: mediaMid, quality: token, cookie: cookie
                      ),
                      let actual = AudioQuality(lxType: resolved.quality) else { continue }
                return OfficialAudio(
                    url: resolved.url,
                    quality: actual.lxType,
                    sourceLabel: "QQ 音乐官方账号音源"
                )
            }
        }

        if ["kg", "kugou"].contains(source),
           KugouSessionStore.shared.isLoggedIn,
           let cookie = KugouSessionStore.shared.cookie,
           let hash = track.sourceMetadata["hash"] ?? track.sourceMetadata["Hash"], !hash.isEmpty {
            let albumID = track.sourceMetadata["albumId"]
            let albumAudioID = track.sourceMetadata["albumAudioId"]
                ?? track.sourceMetadata["albumAudioID"]
                ?? track.sourceMetadata["mixsongid"]
            var attempted = Set<String>()
            for candidate in requestedCandidates {
                let token = candidate.lxType
                guard attempted.insert(token).inserted,
                      let resolved = try? await KugouAPI.shared.musicURL(
                        hash: hash, quality: token, cookie: cookie,
                        albumID: albumID, albumAudioID: albumAudioID
                      ),
                      let actual = AudioQuality(lxType: resolved.quality) else { continue }
                return OfficialAudio(
                    url: resolved.url,
                    quality: actual.lxType,
                    sourceLabel: "酷狗音乐官方账号音源"
                )
            }
        }

        if ["mg", "migu"].contains(source) {
            let copyrightId = track.sourceMetadata["copyrightId"] ?? ""
            if !copyrightId.isEmpty {
                var attempted = Set<String>()
                for candidate in requestedCandidates {
                    let token = candidate.lxType
                    guard attempted.insert(token).inserted,
                          let resolved = try? await MiguAPI.shared.musicURL(
                            copyrightId: copyrightId, contentId: nil, quality: token
                          ),
                          let actual = AudioQuality(lxType: resolved.quality) else { continue }
                    return OfficialAudio(
                        url: resolved.url,
                        quality: actual.lxType,
                        sourceLabel: "咪咕音乐官方接口"
                    )
                }
            }
        }

        if ["kw", "kuwo"].contains(source),
           let songID = track.sourceMetadata["songmid"], !songID.isEmpty {
            var attempted = Set<String>()
            for candidate in requestedCandidates {
                let token = candidate.lxType
                guard attempted.insert(token).inserted,
                      let resolved = try? await KuwoAPI.shared.musicURL(songID: songID, quality: token),
                      let actual = AudioQuality(lxType: resolved.quality) else { continue }
                return OfficialAudio(
                    url: resolved.url,
                    quality: actual.lxType,
                    sourceLabel: "酷我音乐官方接口"
                )
            }
        }

        return nil
    }

    /// Probe the authenticated provider instead of advertising a fixed list
    /// of labels. This keeps the quality picker honest: VIP-only tiers and
    /// unavailable Hi-Res variants are omitted, and a provider downgrade is
    /// represented by the quality returned by its API.
    private func officialQualityNames(for track: Track) async -> [String] {
        let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
        var available: [String] = []

        func append(_ quality: AudioQuality) {
            if !available.contains(quality.lxType) {
                available.append(quality.lxType)
            }
        }

        if ["tx", "qq", "qqmusic", "qq-music"].contains(source),
           let cookie = QQMusicSessionStore.shared.cookie {
            let songMid = track.sourceMetadata["songmid"] ?? String(track.id)
            let mediaMid = track.sourceMetadata["strMediaMid"]?.isEmpty == false
                ? track.sourceMetadata["strMediaMid"]
                : track.sourceMetadata["media_mid"]
            let results = await withTaskGroup(of: String?.self) { group in
                for requested in ["jymaster", "flac24bit", "atmos", "dolby", "flac", "320k", "128k"] {
                    group.addTask {
                        guard let resolved = await Self.withQualityProbeTimeout(operation: {
                            try? await QQMusicAPI.shared.musicURL(
                                songMid: songMid,
                                mediaMid: mediaMid,
                                quality: requested,
                                cookie: cookie
                            )
                        }),
                        ["http", "https"].contains(resolved.url.scheme?.lowercased()) else {
                            return nil
                        }
                        return AudioQuality(lxType: resolved.quality)?.lxType
                    }
                }
                var values: [String] = []
                for await value in group {
                    if let value { values.append(value) }
                }
                return values
            }
            for result in results {
                if let quality = AudioQuality(lxType: result) {
                    append(quality)
                }
            }
        }

        if ["kg", "kugou"].contains(source),
           let cookie = KugouSessionStore.shared.cookie,
           let hash = track.sourceMetadata["hash"] ?? track.sourceMetadata["Hash"], !hash.isEmpty {
            let albumID = track.sourceMetadata["albumId"]
            let albumAudioID = track.sourceMetadata["albumAudioId"]
                ?? track.sourceMetadata["albumAudioID"]
                ?? track.sourceMetadata["mixsongid"]
            let results = await withTaskGroup(of: String?.self) { group in
                for requested in ["jymaster", "atmos", "dolby", "flac24bit", "flac", "320k", "128k"] {
                    group.addTask {
                        guard let resolved = await Self.withQualityProbeTimeout(operation: {
                            try? await KugouAPI.shared.musicURL(
                                hash: hash,
                                quality: requested,
                                cookie: cookie,
                                albumID: albumID,
                                albumAudioID: albumAudioID
                            )
                        }),
                        ["http", "https"].contains(resolved.url.scheme?.lowercased()) else {
                            return nil
                        }
                        return AudioQuality(lxType: resolved.quality)?.lxType
                    }
                }
                var values: [String] = []
                for await value in group {
                    if let value { values.append(value) }
                }
                return values
            }
            for result in results {
                if let quality = AudioQuality(lxType: result) {
                    append(quality)
                }
            }
        }

        return available
    }

    private func qualityCandidates(startingAt quality: AudioQuality) -> [AudioQuality] {
        guard let index = AudioQuality.allCases.firstIndex(of: quality) else {
            return AudioQuality.allCases
        }
        return Array(AudioQuality.allCases[index...])
    }

    private func qqQualityToken(for quality: AudioQuality) -> String {
        switch quality {
        case .master: return "jymaster"
        case .hires: return "flac24bit"
        case .atmos: return "atmos"
        case .surround: return "surround"
        case .dolby: return "dolby"
        case .lossless: return "flac"
        case .exhigh, .higher: return "320k"
        case .standard: return "128k"
        }
    }

    private func validAudioURL(_ rawURL: String) -> URL? {
        guard let url = URL(string: rawURL.replacingOccurrences(of: "http://", with: "https://")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
#endif

    /// Resolves the asset's audio track, giving up after `timeout` so a slow or
    /// uncooperative source delays playback no longer than it would today.
    private func loadAudioTrack(from asset: AVURLAsset, timeout: TimeInterval) async -> AVAssetTrack? {
        await withTaskGroup(of: AVAssetTrack?.self) { group in
            group.addTask {
                try? await asset.loadTracks(withMediaType: .audio).first
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Returns the quality of the bytes that AVFoundation is actually about
    /// to play.  Provider `type` fields are useful fallbacks, but they are
    /// frequently copied from a capability list; the track's estimated data
    /// rate is the safer source for the label shown beside the scrubber.
    private func verifiedServedQuality(
        providerQuality: String?,
        audioTrack: AVAssetTrack?
    ) -> String? {
        let normalizedProvider = providerQuality?.lowercased()
            .replacingOccurrences(of: " ", with: "")
        let requiresTechnicalVerification = [
            "master", "jymaster", "master_quality", "master-quality",
            "atmos", "immersive", "dolby", "dolby-atmos", "dolbyatmos",
            "surround", "spatial", "spatial-audio",
            "flac24bit", "flac24", "hires", "highres",
        ].contains(normalizedProvider ?? "")

        // A semantic tier such as Atmos or Master is not safe to display
        // until the actual audio track has been inspected.  If a source does
        // not expose track metadata, show "检测中" rather than repeating a
        // capability label that may not belong to this URL.
        guard let audioTrack else {
            return requiresTechnicalVerification ? nil : providerQuality
        }
        let rate = audioTrack.estimatedDataRate
        guard rate.isFinite, rate > 0 else {
            return requiresTechnicalVerification ? nil : providerQuality
        }

        // CD-quality FLAC is commonly around 1.4 Mbps. Do not call that
        // Hi-Res merely because it is lossless; use a higher conservative
        // threshold so an account/source cannot advertise Hi-Res for a plain
        // lossless URL. A source must provide a genuinely larger stream.
        switch Int(rate.rounded()) {
        case 1_800_000...:
            return "flac24bit"
        case 600_000..<1_800_000:
            return "flac"
        case 300_000..<600_000:
            return "320k"
        default:
            return "128k"
        }
    }

    /// What the decoder is actually going to get: codec, sample rate, bit depth, channels, data rate.
    private struct StreamFacts {
        let format: AudioFormatID
        let sampleRate: Double
        let channels: Int
        let bits: Int
        let bitrate: Double
    }

    private static func streamFacts(of track: AVAssetTrack) async -> StreamFacts? {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              basic.mSampleRate > 0 else { return nil }
        let rate = (try? await track.load(.estimatedDataRate)) ?? 0
        return StreamFacts(format: basic.mFormatID, sampleRate: basic.mSampleRate,
                           channels: Int(basic.mChannelsPerFrame), bits: Int(basic.mBitsPerChannel),
                           bitrate: Double(rate))
    }

    private static func spectrumTapIsSafe(for track: AVAssetTrack) async -> Bool {
        guard let facts = await streamFacts(of: track) else { return false }
        let lossless = facts.format == kAudioFormatFLAC || facts.format == kAudioFormatAppleLossless
        return !lossless && facts.channels <= 2 && facts.sampleRate <= 48_000
    }

    /// Quality label derived from the stream's real properties (nil when the track cannot be read).
    /// A claimed tier is kept only if the measured stream satisfies it.
    private static func measuredQuality(claimed: String?, track: AVAssetTrack?) async -> String? {
        guard let track, let facts = await streamFacts(of: track) else { return nil }
        let lossless = facts.format == kAudioFormatFLAC || facts.format == kAudioFormatAppleLossless
        let dolby = facts.format == kAudioFormatEnhancedAC3 || facts.format == kAudioFormatAC3
        let hiRes = lossless && (facts.sampleRate >= 88_200 || facts.bits >= 24 || facts.bitrate >= 1_800_000)
        let claim = (claimed ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        switch claim {
        case "master", "jymaster", "master_quality", "master-quality":
            if lossless, facts.sampleRate >= 176_400 { return "jymaster" }
        case "atmos", "immersive", "spatial", "spatial-audio", "jyeffect":
            // A Hi-Res stereo file is just Hi-Res: Spatial needs more than two channels.
            if facts.channels >= 3 { return "atmos" }
        case "dolby", "dolby-atmos", "dolbyatmos":
            if dolby { return "dolby" }
        case "surround", "sky":
            if facts.channels >= 6 { return "surround" }
        default:
            break
        }
        if dolby { return "dolby" }
        if facts.channels >= 6 { return "surround" }
        if lossless { return hiRes ? "flac24bit" : "flac" }
        return facts.bitrate >= 224_000 ? "320k" : "128k"
    }

    /// Lyrics of the same song from the platform that actually served the audio (its cut can differ in length).
    private func realignLyrics(for track: Track, servedPlatform: String, generation: Int) async {
#if os(iOS)
        guard let matched = await LXCatalogService.matchingTrack(track, on: servedPlatform),
              let native = try? await LXCatalogService.nativeLyrics(for: matched) else { return }
        let parsed = LyricsParser.parseLX(lyric: native.lyric, tlyric: native.tlyric,
                                           rlyric: native.rlyric, lxlyric: native.lxlyric)
        guard !parsed.isEmpty, !Task.isCancelled, generation == resolveGeneration else { return }
        // Never trade the lyrics on screen for something worse: a stub (the credits only), far fewer lines, or line-timed
        // lyrics in place of word-timed ones. The platforms' timings of a song agree within a fraction of a second anyway.
        let shown = lyrics
        let shownCount = shown?.lines.count ?? 0
        if parsed.lines.count < Self.minimumLyricLines || (shownCount > 0 && shownCount < Self.minimumLyricLines)
            || parsed.lines.count * 2 < shownCount
            || ((shown?.hasVerbatimTimings ?? false) && !parsed.hasVerbatimTimings) {
            DiagnosticLogStore.shared.append(level: .info, category: "歌词", message: "\(track.name)：保留当前歌词，不改用 \(servedPlatform) 平台的版本",
                                             detail: "\(servedPlatform) 的歌词 \(parsed.lines.count) 行（逐字：\(parsed.hasVerbatimTimings ? "是" : "否")），当前 \(shownCount) 行。")
            return
        }
        publishLyrics(parsed, for: track, generation: generation)
        DiagnosticLogStore.shared.append(level: .info, category: "歌词", message: "\(track.name)：歌词改用 \(servedPlatform) 平台的版本",
                                         detail: "音频取自 \(servedPlatform)，与歌曲自身平台的版本时长不同，歌词按实际播放的版本对齐。")
#endif
    }

    private static func tierFromURL(_ url: URL) -> String? {
        let guess = QQMusicAPI.quality(forFilename: url.lastPathComponent)
        if guess != "unknown", guess != "192k" { return guess }
        return url.pathExtension.lowercased() == "flac" ? "flac" : nil
    }

    /// The length of the audio that is actually playing for a track, once it has been read.
    private var servedAudio: (key: String, seconds: TimeInterval)?
    /// Lyrics of a track are checked against its audio once (key + generation), so replacing them cannot loop.
    private var versionCheckedKey: String?

    #if DEBUG && os(iOS)
    /// Debug harness only: the FLAC to PCM conversion on its own (returns the new file).
    nonisolated static func debugConvertToPCM(_ flac: URL) -> URL? { convertToPCM(flac) }

    /// Debug harness only: lets the audio tap read the player's clock.
    func debugInstallTapClock() {
        let player = engine
        AudioTapProbe.clock = { player.currentTime().seconds }
    }
    #endif

    #if DEBUG
    /// Debug harness only: the address of the audio that is playing.
    var debugAudioURL: String? { (engine.currentItem?.asset as? AVURLAsset)?.url.absoluteString }

    /// Debug harness only: pretend the audio of the current track is `seconds` long, as if the music source played another cut.
    func debugServeAudio(seconds: TimeInterval) {
        guard let track = currentTrack else { return }
        servedAudio = (track.playbackKey, seconds)
        checkLyricsVersion(for: track, generation: resolveGeneration)
    }
    #endif

    /// Lyrics with fewer lines than this (an instrumental's one line, the credits alone) are shown as they are, but never
    /// replaced by lyrics downloaded from other platforms.
    static let minimumLyricLines = 6

    /// Lyrics written for another cut of the song (a longer version, a live take) run past the end of the audio. Lyrics that
    /// stop earlier are normal (an outro without words), so only an overrun counts.
    static func lyricsFitAudio(_ parsed: ParsedLyrics, audio: TimeInterval?) -> Bool {
        guard let audio, audio.isFinite, audio > 30 else { return true }
        return parsed.endTime <= audio + max(8, audio * 0.03)
    }

    /// Called whenever lyrics are shown and when the audio length becomes known: if the lyrics do not fit the audio, look for
    /// lyrics of another source that do. Never leaves the song without lyrics: when nothing fits, the shown lyrics stay.
    private func checkLyricsVersion(for track: Track, generation: Int) {
        guard let served = servedAudio, served.key == track.playbackKey,
              let current = lyrics, !current.isEmpty,
              !Self.lyricsFitAudio(current, audio: served.seconds) else { return }
        let checkKey = "\(track.playbackKey)#\(generation)"
        guard versionCheckedKey != checkKey else { return }
        versionCheckedKey = checkKey
        DiagnosticLogStore.shared.append(
            level: .warning, category: "歌词", message: "\(track.name)：歌词和音频不是同一个版本",
            detail: String(format: "歌词最后一行在 %.0f 秒，音频只有 %.0f 秒，换其他来源的歌词重试。", current.endTime, served.seconds))
        lyricsTask?.cancel()
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            await self.loadLyrics(for: track, generation: generation, audioDuration: served.seconds)
        }
    }

#if os(iOS)
    private static func verbatimFromQQ(_ track: Track, sourceKey: String) async -> ParsedLyrics? {
        var qqID: String? = sourceKey == "tx" || sourceKey == "qq" ? track.sourceMetadata["id"] : nil
        if qqID == nil { qqID = await LXCatalogService.matchingTrack(track, on: "tx")?.sourceMetadata["id"] }
        guard let qqID, !qqID.isEmpty else { return nil }
        let lines = await QQQRCLyrics.lyricLines(musicID: qqID)
        guard !lines.isEmpty else { return nil }
        var parsed = ParsedLyrics()
        parsed.lines = lines
        return parsed
    }

    private static func verbatimFromNetease(_ track: Track, sourceKey: String) async -> ParsedLyrics? {
        let id: Int?
        if ["wy", "netease", "163"].contains(sourceKey) { id = track.id }
        else { id = (try? await NeteaseAPI.matchingSong(for: track))?.id }
        guard let id, let response = try? await NeteaseAPI.lyric(id: id) else { return nil }
        let parsed = LyricsParser.parse(response, includeVerbatim: true)
        return parsed.hasVerbatimTimings ? parsed : nil
    }

    private static func verbatimFromKugou(_ track: Track, sourceKey: String) async -> ParsedLyrics? {
        let candidate: Track?
        if sourceKey == "kg" { candidate = track } else { candidate = await LXCatalogService.matchingTrack(track, on: "kg") }
        guard let candidate, let native = try? await LXCatalogService.nativeLyrics(for: candidate) else { return nil }
        let parsed = LyricsParser.parseLX(lyric: native.lyric, tlyric: native.tlyric, rlyric: native.rlyric, lxlyric: native.lxlyric)
        return parsed.hasVerbatimTimings ? parsed : nil
    }
#endif

    /// The lyrics of the song's own platform: its word-by-word lyrics when it has them, otherwise whatever the catalogue
    /// serves (usually line-timed). Looked up first, since they belong to the entry the user is playing.
    private static func ownPlatformLyrics(_ track: Track, sourceKey: String) async -> ParsedLyrics? {
        switch sourceKey {
        case "tx", "qq": if let own = await verbatimFromQQ(track, sourceKey: sourceKey) { return own }
        case "wy", "netease", "163": if let own = await verbatimFromNetease(track, sourceKey: sourceKey) { return own }
        case "kg": if let own = await verbatimFromKugou(track, sourceKey: sourceKey) { return own }
        default: break
        }
        guard !sourceKey.isEmpty, let native = try? await LXCatalogService.nativeLyrics(for: track) else { return nil }
        let parsed = LyricsParser.parseLX(lyric: native.lyric, tlyric: native.tlyric, rlyric: native.rlyric, lxlyric: native.lxlyric)
        return parsed.isEmpty ? nil : parsed
    }

    private func loadLyrics(for track: Track, generation: Int, audioDuration: TimeInterval? = nil) async {
#if os(iOS)
        guard !Task.isCancelled, generation == resolveGeneration else { return }
        let sourceKey = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
        // Set when this is the second look for lyrics because the first ones did not fit the audio: a source whose lyrics
        // still do not fit is skipped, and nothing found means the lyrics already shown stay.
        // On the second look the lyrics shown already are real ones: a replacement with less than half of their lines is a stub
        // (a credits line or two) and is skipped. The first look has nothing to compare with, so an instrumental's single
        // "pure music" line is still accepted.
        let shownLineCount = audioDuration != nil ? (lyrics?.lines.count ?? 0) : 0
        // Lyrics of fewer than 6 lines (an instrumental's single "pure music" line, or only the credits) are shown as they are,
        // but they never send the search on to other platforms to replace them: the song's own platform's short lyrics are final,
        // and short lyrics found elsewhere are only the last resort when nothing better exists.
        var shortFinal: ParsedLyrics?
        func fits(_ parsed: ParsedLyrics) -> Bool {
            guard Self.lyricsFitAudio(parsed, audio: audioDuration), parsed.lines.count * 2 >= shownLineCount else { return false }
            if parsed.lines.count < Self.minimumLyricLines {
                if shortFinal == nil { shortFinal = parsed }
                return false
            }
            return true
        }
        // Keep a usable line-timed result, but continue searching for a real
        // word-timed payload.  The latter is what AMLL needs; a line-only LRC
        // must never be split into invented per-character timings.
        var lineTimedFallback: ParsedLyrics?

        // Bilibili videos: use the video's own subtitle track as lyrics.
        if sourceKey == "bili" {
            let cookie = BilibiliSessionStore.shared.cookie
            let bvid = track.sourceMetadata["bvid"] ?? track.sourceMetadata["songmid"] ?? ""
            if let video = try? await BilibiliAPI.shared.videoDetail(bvid: bvid, cookie: cookie),
               let cid = video.cid {
                // The detail call already carries the subtitle list; ask the player API as well
                // (it is the one that lists AI subtitles) and merge, Chinese first.
                var tracks = video.subtitles
                if let extra = try? await BilibiliAPI.shared.subtitleTracks(bvid: video.bvid, aid: video.aid, cid: cid, cookie: cookie) {
                    for item in extra where !tracks.contains(where: { $0.language == item.language && $0.isAIGenerated == item.isAIGenerated && $0.isTranslated == item.isTranslated }) { tracks.append(item) }
                }
                let ranked = tracks.sorted { lhs, rhs in
                    func score(_ s: BilibiliAPI.Subtitle) -> Int {
                        (s.language.lowercased().contains("zh") ? 0 : 4) + (s.isAIGenerated ? 1 : 0) + (s.isTranslated ? 2 : 0)
                    }
                    return score(lhs) < score(rhs)
                }
                if ranked.isEmpty {
                    DiagnosticLogStore.shared.append(level: .info, category: "哔哩哔哩播放", message: "听视频：该视频没有字幕",
                                                     detail: video.bvid + (cookie == nil ? "（未登录，AI 字幕需要登录账号）" : ""))
                }
                for chosen in ranked {
                    guard let cues = try? await BilibiliAPI.shared.subtitleCues(for: chosen, cookie: cookie), !cues.isEmpty else { continue }
                    guard !Task.isCancelled, generation == resolveGeneration else { return }
                    var parsed = ParsedLyrics()
                    parsed.lines = cues.enumerated().map { LyricLine(id: $0.offset, time: $0.element.start, text: $0.element.text) }
                    publishLyrics(parsed, for: track, generation: generation)
                    return
                }
            } else {
                DiagnosticLogStore.shared.append(level: .warning, category: "哔哩哔哩播放", message: "听视频：读取视频详情失败，无法获取字幕", detail: bvid)
            }
        }

        // Word-by-word lyrics, the way LDDC (github.com/chenmozhijin/LDDC) gets them: ask QQ Music (QRC), Kugou (KRC) and
        // NetEase (YRC) at the same time, keep the ones that are the same recording as the audio, and take the one whose
        // length is closest to it. The song's own platform wins a tie.
        if SettingsManager.shared.verbatimLyrics {
            // The three platforms are asked at the same time. The first usable lyrics are shown after at most 1.2 more
            // seconds for the others to arrive (to compare); a slow platform never holds the lyrics back (8 s at most).
            var results: [String: ParsedLyrics] = [:]
            var finished = 0
            // The song's own platform is asked at the same time and goes first: its word-by-word lyrics are shown as soon as
            // they arrive, its line-timed lyrics are kept in case no platform has word-by-word ones.
            var ownResult: ParsedLyrics?
            var ownDone = false
            var ownChecked = false
            Task {
                let own = await Self.ownPlatformLyrics(track, sourceKey: sourceKey)
                ownResult = own
                ownDone = true
            }
            let jobs: [(String, () async -> ParsedLyrics?)] = [
                ("tx", { await Self.verbatimFromQQ(track, sourceKey: sourceKey) }),
                ("wy", { await Self.verbatimFromNetease(track, sourceKey: sourceKey) }),
                ("kg", { await Self.verbatimFromKugou(track, sourceKey: sourceKey) }),
            ]
            for (name, work) in jobs {
                Task {
                    let lyrics = await work()
                    if let lyrics { results[name] = lyrics }
                    finished += 1
                }
            }
            let waitStart = Date()
            var firstUsableAt: Date?
            // True when the own platform's word-by-word lyrics were shown (nothing more to do).
            func useOwnIfReady() -> Bool {
                guard ownDone, !ownChecked else { return false }
                ownChecked = true
                if let own = ownResult, !own.isEmpty, audioDuration == nil, own.lines.count < Self.minimumLyricLines,
                   Self.lyricsFitAudio(own, audio: audioDuration) {
                    DiagnosticLogStore.shared.append(level: .info, category: "歌词", message: "使用歌曲所在平台的短歌词（不到 \(Self.minimumLyricLines) 句）",
                        detail: "\(sourceKey) · \(own.lines.count) 行：照原样显示，不再去其他平台下载替换。")
                    publishLyrics(own, for: track, generation: generation)
                    return true
                }
                guard let own = ownResult, fits(own) else { return false }
                if own.hasVerbatimTimings {
                    DiagnosticLogStore.shared.append(level: .info, category: "歌词", message: "使用歌曲所在平台的逐字歌词",
                        detail: "\(sourceKey) · \(own.lines.count) 行")
                    publishLyrics(own, for: track, generation: generation)
                    return true
                }
                lineTimedFallback = own
                return false
            }
            while finished < jobs.count || !ownDone, Date().timeIntervalSince(waitStart) < 8 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, generation == resolveGeneration else { return }
                if useOwnIfReady() { return }
                if firstUsableAt == nil, !results.isEmpty { firstUsableAt = Date() }
                // The own platform gets a little longer to answer before the others decide.
                if let firstUsableAt, Date().timeIntervalSince(firstUsableAt) > 1.2,
                   ownDone || Date().timeIntervalSince(waitStart) > 3 { break }
            }
            guard !Task.isCancelled, generation == resolveGeneration else { return }
            if useOwnIfReady() { return }
            let found: [(name: String, lyrics: ParsedLyrics?)] = jobs.map { ($0.0, results[$0.0]) }
            guard !Task.isCancelled, generation == resolveGeneration else { return }
            let usable = found.compactMap { item -> (name: String, lyrics: ParsedLyrics, gap: Double)? in
                guard let lyrics = item.lyrics, !lyrics.isEmpty, fits(lyrics) else { return nil }
                let own = item.name == sourceKey || (item.name == "tx" && sourceKey == "qq")
                let gap = audioDuration.map { abs(lyrics.endTime - $0) } ?? 0
                return (item.name, lyrics, gap - (own ? 1.5 : 0))
            }
            // Platforms time their lyrics against different cuts of a song, so a source can start right and still be seconds
            // off further on (an extra or missing section). Sources are compared at the start AND at the end: a source agrees
            // with another when the first and last sung lines fall at the same time. The cut that most sources share wins.
            func probes(_ lyrics: ParsedLyrics) -> [Double] {
                let sung = lyrics.lines.filter { !$0.text.isEmpty }
                guard let first = sung.first, let last = sung.last else { return [] }
                return [first.time, last.time]
            }
            func agreement(_ item: (name: String, lyrics: ParsedLyrics, gap: Double)) -> Int {
                let mine = probes(item.lyrics)
                guard mine.count == 2 else { return 0 }
                return usable.filter { other in
                    guard other.name != item.name else { return false }
                    let theirs = probes(other.lyrics)
                    return theirs.count == 2 && abs(theirs[0] - mine[0]) < 0.6 && abs(theirs[1] - mine[1]) < 1.5
                }.count
            }
            let ranked = usable.sorted { lhs, rhs in
                let (la, ra) = (agreement(lhs), agreement(rhs))
                return la != ra ? la > ra : lhs.gap < rhs.gap
            }
            if let best = ranked.first {
                DiagnosticLogStore.shared.append(level: .info, category: "歌词", message: "逐字歌词候选",
                    detail: ranked.map { String(format: "%@ %d行 首句%.2f 末句%.2f 一致%d", $0.name, $0.lyrics.lines.count,
                        $0.lyrics.lines.first(where: { !$0.text.isEmpty })?.time ?? 0, $0.lyrics.endTime, agreement($0)) }
                        .joined(separator: " | ") + String(format: " | 音频 %.1f", audioDuration ?? 0))
                publishLyrics(best.lyrics, for: track, generation: generation)
                return
            }
        }

        // Second: the community database of hand-timed lyrics (amll-ttml-db), looked up in the index in memory. It never
        // waits for the network (the index loads in the background, see `AMLLTTMLDatabase.prefetch`).
        if AMLLTTMLDatabase.isEnabled {
            Task { await AMLLTTMLDatabase.shared.prefetch() }
            var ownQQIDs: [String] = []
            if sourceKey == "tx" || sourceKey == "qq" {
                if let id = track.sourceMetadata["id"] { ownQQIDs.append(id) }
                if let mid = track.sourceMetadata["songmid"] { ownQQIDs.append(mid) }
            }
            let isNetease = ["wy", "netease", "163"].contains(sourceKey)
            if let community = await AMLLTTMLDatabase.shared.lyrics(
                neteaseID: isNetease ? String(track.id) : nil, qqIDs: ownQQIDs,
                title: track.name, artists: track.artists.map(\.name), duration: track.duration), fits(community) {
                guard !Task.isCancelled, generation == resolveGeneration else { return }
                publishLyrics(community, for: track, generation: generation)
                return
            }
        }

        if ["wy", "netease", "163"].contains(sourceKey),
           let response = try? await NeteaseAPI.lyric(id: track.id) {
            guard !Task.isCancelled, generation == resolveGeneration else { return }
            let parsed = LyricsParser.parse(response)
            if !parsed.isEmpty, fits(parsed) {
                if parsed.hasVerbatimTimings {
                    publishLyrics(parsed, for: track, generation: generation)
                    return
                }
                lineTimedFallback = parsed
            }
        }

        // Prefer the selected LX source's own lyric action. It may expose
        // yrc/lxlyric word timings that the catalogue adapters do not have.
        if !sourceKey.isEmpty,
           LXSourceStore.shared.selectedSource != nil,
           let lx = try? await LXUserAPIService.shared.resolveLyrics(for: track) {
            guard !Task.isCancelled, generation == resolveGeneration else { return }
            let parsed = LyricsParser.parseLX(lyric: lx.lyric, tlyric: lx.tlyric,
                                               rlyric: lx.rlyric, lxlyric: lx.lxlyric,
                                               yrc: lx.yrc)
            if !parsed.isEmpty, fits(parsed) {
                if parsed.hasVerbatimTimings {
                    publishLyrics(parsed, for: track, generation: generation)
                    return
                }
                lineTimedFallback = lineTimedFallback ?? parsed
            }
        }

        // Catalogue lyrics are metadata only. Playback is still resolved by
        // the selected LX User API source in resolveAndLoad(_:generation:requestedQuality:).
        if !sourceKey.isEmpty,
           let native = try? await LXCatalogService.nativeLyrics(for: track) {
            guard !Task.isCancelled, generation == resolveGeneration else { return }
            let parsed = LyricsParser.parseLX(lyric: native.lyric, tlyric: native.tlyric,
                                               rlyric: native.rlyric, lxlyric: native.lxlyric)
            if !parsed.isEmpty, fits(parsed) {
                if parsed.hasVerbatimTimings {
                    publishLyrics(parsed, for: track, generation: generation)
                    return
                }
                lineTimedFallback = lineTimedFallback ?? parsed
            }
        }

        // If this platform has no lyric endpoint or no result, search every
        // supported catalogue platform by metadata. IDs are never reused
        // across platforms, so a matched track is required before fetching.
        let fallbackPlatforms = ["tx", "wy", "kw", "kg", "mg"]
        for platform in fallbackPlatforms where platform != sourceKey {
            guard !Task.isCancelled, generation == resolveGeneration else { return }
            guard let matched = await LXCatalogService.matchingTrack(track, on: platform),
                  let native = try? await LXCatalogService.nativeLyrics(for: matched) else {
                continue
            }
            let parsed = LyricsParser.parseLX(lyric: native.lyric,
                                               tlyric: native.tlyric,
                                               rlyric: native.rlyric,
                                               lxlyric: native.lxlyric)
            if !parsed.isEmpty, fits(parsed) {
                guard !Task.isCancelled, generation == resolveGeneration else { return }
                if parsed.hasVerbatimTimings {
                    publishLyrics(parsed, for: track, generation: generation)
                    return
                }
                lineTimedFallback = lineTimedFallback ?? parsed
            }
        }

        // LX catalogue IDs are platform-specific. If the selected source has
        // no lyric implementation, use a public NetEase catalogue match only
        // for lyric metadata; audio still comes exclusively from LX.
        if !sourceKey.isEmpty {
            if let candidate = try? await NeteaseAPI.matchingSong(for: track),
               let response = try? await NeteaseAPI.lyric(id: candidate.id) {
                // NetEase YRC is the preferred cross-platform fallback for
                // real word timing.  AMLL renders it; it is not safe to
                // fabricate timings when only line-level LRC exists.
                let parsed = LyricsParser.parse(response, includeVerbatim: true)
                if !parsed.isEmpty, fits(parsed) {
                    guard !Task.isCancelled, generation == resolveGeneration else { return }
                    if parsed.hasVerbatimTimings {
                        publishLyrics(parsed, for: track, generation: generation)
                        return
                    }
                    lineTimedFallback = lineTimedFallback ?? parsed
                }
            }
        }

        // Do not leave the lyric panel in a permanent loading state when no
        // provider has lyrics for this track.
        guard generation == resolveGeneration else { return }
        if let lineTimedFallback {
            publishLyrics(lineTimedFallback, for: track, generation: generation)
            return
        }
        // Short lyrics found somewhere (none of the platforms had real ones) are shown after all.
        if let shortFinal, audioDuration == nil {
            publishLyrics(shortFinal, for: track, generation: generation)
            return
        }
        // A second look (lyrics that did not fit the audio) that found nothing better leaves the shown lyrics alone.
        if audioDuration != nil { return }
        lyrics = ParsedLyrics()
        updateLyricsCursor(at: progress)
        return
#else

        // LX song IDs belong to their own platform and must not be sent
        // directly to NetEase. For an LX result, search NetEase by metadata
        // only as a lyric fallback when the imported source has no lyric
        // action or returned an unusable body.
        let response: LyricResponse?
        if track.source == nil {
            response = try? await NeteaseAPI.lyric(id: track.id)
        } else {
            response = nil
        }
        guard generation == resolveGeneration else { return }
        if let response {
            let parsed = LyricsParser.parse(response)
            if !parsed.isEmpty {
               publishLyrics(parsed, for: track, generation: generation)
               return
            }
        }

#if os(iOS)
        // LX Mobile's built-in catalogue adapters own online lyrics. The
        // imported User API normally exposes only `musicUrl`, so asking it
        // for `lyric` cannot work for kw/kg/tx/mg sources.
        if track.source != nil,
           let native = try? await LXCatalogService.nativeLyrics(for: track) {
            let parsed = LyricsParser.parseLX(lyric: native.lyric,
                                               tlyric: native.tlyric,
                                               rlyric: native.rlyric,
                                               lxlyric: native.lxlyric)
            if !parsed.isEmpty {
                guard generation == resolveGeneration else { return }
               publishLyrics(parsed, for: track, generation: generation)
               return
            }
        }

        if track.source != nil {
            if let candidate = try? await NeteaseAPI.matchingSong(for: track),
               let response = try? await NeteaseAPI.lyric(id: candidate.id) {
                let parsed = LyricsParser.parse(response)
                if !parsed.isEmpty {
                    guard generation == resolveGeneration else { return }
               publishLyrics(parsed, for: track, generation: generation)
               return
                }
            }
        }
#endif

#endif

        guard generation == resolveGeneration else { return }
        // A completed lookup should render an empty state instead of leaving
        // the lyric panel in an infinite loading spinner.
        lyrics = ParsedLyrics()
        updateLyricsCursor(at: progress)
    }

    // MARK: - Scrobble

#if os(iOS)
    private func neteaseTrackID(for track: Track) async -> Int? {
        if track.source == nil && track.sourceMetadata["source"] == nil {
            return track.id
        }
        let matched = try? await NeteaseAPI.matchingSong(
            for: track, limit: 12, requireDuration: false
        )
        return matched?.id
    }

    /// Reject obvious provider audition files before they become the active
    /// player item. A normal song's catalogue duration is available locally;
    /// a finite 30-second asset for a multi-minute track is never a valid
    /// high-quality fallback.
    private func isLikelyPreviewURL(_ url: URL, expectedDuration: TimeInterval) async -> Bool {
        guard expectedDuration >= 60 else { return false }
        let asset = AVURLAsset(url: url)
        let loadedDuration: TimeInterval? = await withTaskGroup(of: TimeInterval?.self) { group in
            group.addTask {
                guard let value = try? await asset.load(.duration) else { return nil }
                let seconds = value.seconds
                return seconds.isFinite && seconds > 0 ? seconds : nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let loadedDuration else { return false }
        return loadedDuration <= 35 || loadedDuration < expectedDuration * 0.6
    }

    private func syncListeningStart(track: Track, sourceID: Int) {
        // A cookie can survive a server-side logout or an incomplete bootstrap.
        // Require the verified AccountStore profile too, otherwise playback can
        // appear to sync for a user who is not actually signed in.
        guard AccountStore.shared.isLoggedIn else {
            ListeningSyncStore.shared.markSignedOut()
            return
        }
        let key = track.playbackKey
        Task { [weak self] in
            guard let trackID = await self?.neteaseTrackID(for: track) else { return }
            // Keep the match available immediately. A very short track or a
            // fast user skip can finish before the startplay request returns.
            self?.pendingNeteaseTrackIDs[key] = trackID
            // This is an account history event only. The actual audio URL was
            // already resolved through the selected LX User API source.
            for attempt in 0..<3 {
                if await NeteaseAPI.scrobbleStart(trackID: trackID, sourceID: sourceID) {
                    guard !Task.isCancelled else { return }
                    return
                }
                guard attempt < 2, !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(Double(attempt + 1)))
            }
        }
    }

    private func syncListeningFinish(track: Track, sourceID: Int, seconds: Int) {
        guard seconds > 0 else { return }
        guard AccountStore.shared.isLoggedIn else {
            ListeningSyncStore.shared.markSignedOut()
            return
        }
        let key = track.playbackKey
        let knownID = pendingNeteaseTrackIDs[key]
        Task { [weak self] in
            let trackID: Int?
            if let knownID {
                trackID = knownID
            } else {
                trackID = await self?.neteaseTrackID(for: track)
            }
            guard let trackID else {
                ListeningSyncStore.shared.recordFailure()
                return
            }

            // A failed request must not be presented as a successful local
            // sync. Retry transient cookie/network/API failures before giving
            // up; the next track can still use its own independent event.
            for attempt in 0..<3 {
                if await NeteaseAPI.scrobbleFinish(trackID: trackID,
                                                   sourceID: sourceID,
                                                   seconds: seconds) {
                    guard !Task.isCancelled else { return }
                    ListeningSyncStore.shared.record(seconds: seconds)
                    if let uid = AccountStore.shared.profile?.userId {
                        await ListeningSyncStore.shared.refreshRemoteRecords(uid: uid)
                    }
                    self?.pendingNeteaseTrackIDs.removeValue(forKey: key)
                    return
                }
                if attempt == 0 {
                    await NeteaseAPI.refreshLogin()
                }
                guard attempt < 2, !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(Double(attempt + 1)))
            }

            guard !Task.isCancelled else { return }
            ListeningSyncStore.shared.recordFailure()
            ToastCenter.shared.show("网易云听歌时长同步失败，本次未计入同步时长")
        }
    }
#endif

    private func scrobbleIfNeeded(completed: Bool) {
        guard let track = currentTrack, !scrobbled, progress > 1 else { return }
        scrobbled = true
        // Some LX results omit duration metadata. On completion the AVPlayer
        // progress is still authoritative, so never turn a real listening
        // interval into a zero-second weblog event.
        let seconds = completed ? max(Int(duration), Int(progress)) : Int(progress)
        let sourceID = source.sourceID
#if os(iOS)
        syncListeningFinish(track: track, sourceID: sourceID, seconds: seconds)
#else
        if AccountStore.shared.isLoggedIn {
            Task.detached {
                await NeteaseAPI.scrobbleFinish(trackID: track.id, sourceID: sourceID, seconds: seconds)
            }
        } else {
            ListeningSyncStore.shared.markSignedOut()
        }
#endif
    }

    // MARK: - Shuffle helpers

    private func reshuffle(keeping first: Track) {
        var rest = queue.filter { $0.playbackKey != first.playbackKey }
        rest.shuffle()
        shuffledQueue = [first] + rest
    }

    // MARK: - Persistence

    private static let recentContextsLimit = 6

    private func recordRecent(_ context: PlayContext) {
        recentContexts.removeAll { $0 == context }
        recentContexts.insert(context, at: 0)
        if recentContexts.count > Self.recentContextsLimit {
            recentContexts.removeLast(recentContexts.count - Self.recentContextsLimit)
        }
    }

    /// Reloads a place from the recents list and starts playing it again.
    func play(context: PlayContext) {
        // Personal FM is a stream, not a fixed list — restart it in place.
        guard context.kind != .fm else { return startFM() }
        Task {
            do {
                guard let resolved = try await resolve(context) else { return }
                play(tracks: resolved.tracks, source: resolved.source, context: context)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    // CarPlay uses the same context resolver as the in-app queue. Keeping this
    // internal avoids a second playback pipeline while leaving the method out
    // of the public package API.
    func resolve(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
        switch context.kind {
        case .fm:
            return nil
        case .album:
            return (try await NeteaseAPI.album(id: context.id).songs, .album(context.id))
        case .artist:
            return (try await NeteaseAPI.artist(id: context.id).hotSongs, .artist(context.id))
        case .daily:
            let tracks = try await NeteaseAPI.dailyRecommendSongs()
                .map { $0.normalizedForLXPlayback() }
            return (tracks, .daily)
        case .cloud:
            let songs = try await NeteaseAPI.cloudSongs().data?.compactMap(\.simpleSong) ?? []
            return (songs, .cloud)
        case .recents:
            guard let uid = AccountStore.shared.profile?.userId else { return nil }
            return (try await NeteaseAPI.playRecords(uid: uid, week: true).map(\.song), .none)
        case .heartbeat:
            // Regenerated from a fresh seed, the same way the Home card does it.
            guard let liked = AccountStore.shared.likedSongsPlaylist,
                  let seed = AccountStore.shared.likedTrackIDs.randomElement() else { return nil }
            let tracks = try await NeteaseAPI.intelligenceList(songID: seed, playlistID: liked.id)
            return (tracks, .playlist(liked.id))
        case .playlist:
            let response = try await NeteaseAPI.playlistDetail(id: context.id)
            var tracks = response.playlist.tracks
            // /v6/playlist/detail only carries the first page of tracks.
            let remaining = response.playlist.trackIds.map(\.id).dropFirst(tracks.count)
            for chunk in stride(from: 0, to: remaining.count, by: 500)
                .map({ Array(remaining.dropFirst($0).prefix(500)) }) {
                guard let more = try? await NeteaseAPI.songDetails(ids: chunk) else { break }
                tracks += more.songs
            }
            return (tracks, .playlist(context.id))
        }
    }

    private struct PersistedState: Codable {
        var queue: [Track]
        var currentID: Int?
        var currentKey: String?
        var repeatMode: String
        var shuffle: Bool
        /// Optional so state files written before recents existed still decode.
        var recentContexts: [PlayContext]?
    }

    private func persistState() {
        let state = PersistedState(
            queue: Array(queue.prefix(1000)),
            currentID: currentTrack?.id,
            currentKey: currentTrack?.playbackKey,
            repeatMode: repeatMode.rawValue,
            shuffle: shuffleEnabled,
            recentContexts: recentContexts
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = Self.stateFileURL
        Task.detached {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func restoreState() {
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        // Recents outlive the queue: restore them before bailing out on an
        // empty queue, or the next played track persists an empty list over
        // them and the Dock menu loses its history for good.
        recentContexts = Array((state.recentContexts ?? []).prefix(Self.recentContextsLimit))
        guard !state.queue.isEmpty else { return }
        queue = state.queue
        shuffleEnabled = state.shuffle
        if shuffleEnabled {
            shuffledQueue = queue.shuffled()
        }
        if let idx = state.currentKey.flatMap({ key in
            activeQueue.firstIndex(where: { $0.playbackKey == key })
        }) ?? state.currentID.flatMap({ id in
            activeQueue.firstIndex(where: { $0.id == id })
        }) {
            currentIndex = idx
            currentTrack = activeQueue[idx]
            duration = activeQueue[idx].duration
            NowPlayingManager.shared.updateMetadata(for: activeQueue[idx], duration: duration)
            Task {
                await loadLyrics(for: activeQueue[idx], generation: resolveGeneration)
            }
        }
    }

    private static var stateFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("player-state.json")
    }
}
