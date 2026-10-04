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
                    || ((cached.qualities.contains($0) || known.contains($0.lxType)) && !refuted.contains($0.lxType))
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
                && ($0.lxType == servedNow || !refuted.contains($0.lxType))
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
        let t = engine.currentTime().seconds
        return t.isFinite ? t : progress
    }
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

        statusObservation = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }

        NowPlayingManager.shared.attach(to: self)
        restoreState()
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

    private func publishLyrics(_ parsed: ParsedLyrics, for track: Track, generation: Int) {
        lyrics = parsed
        DiagnosticLogStore.shared.append(
            level: .info, category: "歌词", message: parsed.hasVerbatimTimings ? "逐字歌词" : "逐句歌词",
            detail: "\(track.name) · 来源 \(track.source ?? "wy") · \(parsed.lines.count) 行")
        updateLyricsCursor(at: livePlaybackTime)

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

        var merged = base
        var changed = false
        for index in merged.lines.indices where merged.lines[index].translation == nil {
            for metadata in sources {
                guard let nearest = metadata.lines.min(by: {
                    abs($0.time - merged.lines[index].time) < abs($1.time - merged.lines[index].time)
                }), abs(nearest.time - merged.lines[index].time) < 1.2,
                      let translation = nearest.translation, !translation.isEmpty else { continue }
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
        lastSeekRequestAt = Date()
        if let completion { queuedSeekCompletions.append(completion) }
        drainSeek()
    }

    private func drainSeek() {
        guard !seekInFlight, let target = queuedSeekTarget else { return }
        queuedSeekTarget = nil
        seekInFlight = true
        let isLocalFile = (engine.currentItem?.asset as? AVURLAsset)?.url.isFileURL ?? false
        // Exact seeks only for local files; streamed ones accept a small tolerance (exact seeks need a
        // full index and can stall for seconds).
        // Dragging the slider chases loosely; the final (or a lyric-tap) seek is exact so lyrics stay in sync.
        let tolerance = (isLocalFile || !isScrubbing) ? CMTime.zero : CMTime(seconds: 0.4, preferredTimescale: 600)
        engine.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if self.queuedSeekTarget == nil {
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
        let quality = requestedQuality.rawValue
#if os(macOS)
        let isLXCatalogTrack = track.source != nil
#endif
        var resolvedURL: URL?
        var servedByLXQuality: String?
        var servedBySourceLabel: String?
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
                let video = try await BilibiliAPI.shared.videoDetail(
                    bvid: track.sourceMetadata["bvid"] ?? "", cookie: cookie)
                let audio = try await BilibiliAPI.shared.audioPlayback(for: video, cookie: cookie)
                resolvedURL = audio.url
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
            let playbackMode = SettingsManager.shared.playbackSourceMode
            let hasOfficialAccount = (isNativeNetease && NeteaseClient.shared.isLoggedIn)
                || (isQQMusic && QQMusicSessionStore.shared.isLoggedIn)
                || (isKugou && KugouSessionStore.shared.isLoggedIn)
            let hasLXSource = !LXSourceStore.shared.playbackSources.isEmpty
            guard hasLXSource || (playbackMode != .thirdParty && hasOfficialAccount) else {
                guard generation == resolveGeneration else { return }
                ToastCenter.shared.show("请先登录账号或在设置 → LX 音源中选择播放音源")
                isPlaying = false
                return
            }
            // 自动模式：账号只能给出比所选音质低的档位（例如非会员选了环绕声 / 母带，只拿到 320k）时，
            // 先记下账号的结果，再向三方音源要所选音质；三方没有更好的才用回账号的结果。
            var officialFallback: OfficialAudio?
            if playbackMode != .thirdParty, hasOfficialAccount,
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
                var rejectedPreviewURLs = Set<String>()
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
                        if await isLikelyPreviewURL(candidate.url, expectedDuration: track.duration) {
                            rejectedPreviewURLs.insert(candidate.url.absoluteString)
                            lastError = LXUserAPIService.LXError.sourceUnavailable(
                                "音源返回 30 秒试听片段，已切换备用音源"
                            )
                            continue
                        }
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
                if let officialFallback,
                   let officialRank = Self.qualityRank(officialFallback.quality),
                   let thirdRank = Self.qualityRank(resolved.quality), thirdRank >= officialRank {
                    // The third-party source did not beat the account's tier: keep the account stream.
                    resolvedURL = officialFallback.url
                    servedByLXQuality = officialFallback.quality
                    servedBySourceLabel = officialFallback.sourceLabel
                }
                // Only the account-mode fallback is worth a notice: with a third-party source chosen
                // on purpose, "会员歌曲将通过第三方音源播放" is just noise.
                if vipFallbackAllowed, (track.fee == 1 || track.fee == 4),
                   UserDefaults.standard.object(forKey: "moumusic.vipReminder") as? Bool ?? true {
                    ToastCenter.shared.show("会员歌曲，已通过第三方音源播放")
                }
            } catch {
                guard !Task.isCancelled, generation == resolveGeneration else { return }
                if let officialFallback {
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
        if (track.source ?? "").lowercased() == "bili" {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": [
                "Referer": "https://www.bilibili.com/",
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            ]])
        } else {
            // Precise timing only for MP3 (VBR seeks otherwise land on an estimated byte offset and the
            // lyrics drift); on other remote formats it makes AVPlayer scan the stream first, which froze
            // loading and fast scrubbing.
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
            engine.seek(to: CMTime(seconds: seekPosition, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, generation == self.resolveGeneration else { return }
                    self.engine.playImmediately(atRate: self.playbackRate)
                }
            }
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
        Task { [weak self, weak item] in
            guard let self else { return }
            let probed = await self.loadAudioTrack(from: asset, timeout: 6)
            guard generation == self.resolveGeneration, let item, self.engine.currentItem === item else { return }
#if os(iOS)
            // The label comes from the stream itself: codec, sample rate, channel count and data rate of
            // the track AVFoundation decodes. A tier the source claims is only shown when those facts
            // support it; when the track cannot be read at all the source's own label stays (unverified).
            let measured = await Self.measuredQuality(claimed: providerQualitySnapshot, track: probed)
            let shown = measured ?? providerQualitySnapshot
            guard generation == self.resolveGeneration, self.engine.currentItem === item else { return }
            self.servedQuality = shown
            self.servedQualityTrackKey = track.playbackKey
            let wanted = self.currentQuality
            let spatial: [AudioQuality] = [.master, .atmos, .dolby, .surround]
            let served = (self.servedQuality ?? "").lowercased()
            let servedSpatial = ["atmos", "dolby", "surround", "master", "sky", "jyeffect", "jymaster", "spatial"].contains { served.contains($0) }
            if spatial.contains(wanted), !served.isEmpty, !servedSpatial {
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
                for requested in ["flac", "320k", "128k"] {
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
        case .master, .atmos, .dolby, .surround, .hires, .lossless: return "flac"
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
            if hiRes { return "atmos" }
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

    private func loadLyrics(for track: Track, generation: Int) async {
#if os(iOS)
        guard !Task.isCancelled, generation == resolveGeneration else { return }
        let sourceKey = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
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

        // Word-by-word lyrics come from QQ Music first (QRC), whatever platform the song is from.
        if SettingsManager.shared.verbatimLyrics {
            var qqID: String? = sourceKey == "tx" || sourceKey == "qq" ? track.sourceMetadata["id"] : nil
            if qqID == nil, let matched = await LXCatalogService.matchingTrack(track, on: "tx") {
                qqID = matched.sourceMetadata["id"]
            }
            guard !Task.isCancelled, generation == resolveGeneration else { return }
            if let qqID, !qqID.isEmpty {
                let qrcLines = await QQQRCLyrics.lyricLines(musicID: qqID)
                guard !Task.isCancelled, generation == resolveGeneration else { return }
                if !qrcLines.isEmpty {
                    var parsed = ParsedLyrics()
                    parsed.lines = qrcLines
                    publishLyrics(parsed, for: track, generation: generation)
                    return
                }
            }
        }

        if ["wy", "netease", "163"].contains(sourceKey),
           let response = try? await NeteaseAPI.lyric(id: track.id) {
            guard !Task.isCancelled, generation == resolveGeneration else { return }
            let parsed = LyricsParser.parse(response)
            if !parsed.isEmpty {
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
            if !parsed.isEmpty {
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
            if !parsed.isEmpty {
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
            if !parsed.isEmpty {
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
                if !parsed.isEmpty {
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
