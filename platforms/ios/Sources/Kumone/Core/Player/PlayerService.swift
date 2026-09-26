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

    /// The list the player is walking through (shuffled or ordered).
    var activeQueue: [Track] { shuffleEnabled ? shuffledQueue : queue }

    var upcomingTracks: [Track] {
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
        let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
        return playNextList + Array(rest.prefix(200))
    }

    var hasCurrentTrack: Bool { currentTrack != nil }

    var currentQuality: AudioQuality {
        trackQualityOverride ?? SettingsManager.shared.audioQuality
    }

    func availableQualitiesForCurrentTrack() async -> [AudioQuality] {
        guard let track = currentTrack else { return [] }
#if os(iOS)
        let playbackMode = SettingsManager.shared.playbackSourceMode
        let cacheKey = qualityAvailabilityCacheKey(for: track, mode: playbackMode)
        if let cached = qualityAvailabilityCache[cacheKey], cached.expiresAt > Date() {
            return cached.qualities
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
            qualityTasks.append(Task {
                await NeteaseAPI.officialQualityNames(
                    for: track.id, duration: track.duration
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
        for task in qualityTasks {
            names.formUnion(await task.value)
        }
        var seenTypes = Set<String>()
        let available = AudioQuality.allCases.filter {
            names.contains($0.lxType) && seenTypes.insert($0.lxType).inserted
        }
        let result = available.isEmpty ? [.standard] : available
        // Do not cache a timeout/empty-source fallback as if it were a real
        // capability result; the source may finish initializing moments later.
        if !names.isEmpty {
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
    private struct QualityAvailabilityCacheEntry {
        let expiresAt: Date
        let qualities: [AudioQuality]
    }
    private var qualityAvailabilityCache: [String: QualityAvailabilityCacheEntry] = [:]
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
    }
    private var lastLiveActivityProgress = -10.0
    private var liveActivityLyric: String?
#endif
    private var runtimeStarted = false

    private init() {
        engine.actionAtItemEnd = .pause
        sleepTimer.onDeadlineReached = { [weak self] in
            self?.pause()
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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
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
                      let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                      reason == .oldDeviceUnavailable, self.isPlaying else { return }
                self.pause()
            }
        }
        #endif

        timeObserver = engine.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }

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
                    if self.isPlaying,
                       seconds - self.lastLiveActivityProgress >= 5 {
                        self.lastLiveActivityProgress = seconds
                        self.syncLiveActivity()
                    }
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

#if os(iOS)
    /// Starts or refreshes the system Live Activity. The system performs the
    /// actual expanded-to-compact Dynamic Island transition when the user
    /// leaves the app or it moves to the background.
    private func syncLiveActivity(newTrack: Bool = false) {
        guard #available(iOS 16.2, *), let track = currentTrack else { return }
        MoumusicPlaybackActivityManager.shared.synchronize(
            title: track.name,
            artist: track.artistNames,
            artworkURL: liveArtworkURL(for: track),
            currentLyric: liveActivityLyric,
            elapsed: progress,
            duration: duration,
            isPlaying: isPlaying,
            newTrack: newTrack
        )
    }

    /// LX and account-backed results do not always put the cover in the same
    /// field. Prefer the unified album cover, then use the source metadata
    /// aliases used by the imported User API formats.
    private func liveArtworkURL(for track: Track) -> String? {
        let candidates = [
            track.album.picUrl,
            track.sourceMetadata["picUrl"],
            track.sourceMetadata["picurl"],
            track.sourceMetadata["albumPic"],
            track.sourceMetadata["album_pic"],
            track.sourceMetadata["cover"],
            track.sourceMetadata["coverUrl"],
            track.sourceMetadata["pic"],
            track.artists.first?.picUrl,
        ]
        return candidates.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }
#else
    private func syncLiveActivity(newTrack: Bool = false) {}
#endif

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
                syncLiveActivity()
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
            syncLiveActivity()
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

    func togglePlayPause() {
        guard let track = currentTrack else { return }
        if isPlaying {
            engine.pause()
            isPlaying = false
            AudioSpectrum.shared.reset()
        } else if engine.currentItem == nil {
            // Restored session: re-resolve the source.
            startPlaying(track, indexUnchanged: true, preserveTrackQualityOverride: true)
            return
        } else {
            engine.play()
            engine.rate = playbackRate
            isPlaying = true
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? Double(playbackRate) : 0)
        syncLiveActivity()
    }

    func pause() {
        engine.pause()
        isPlaying = false
        AudioSpectrum.shared.reset()
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
        syncLiveActivity()
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
        let index = lyrics?.activeIndex(at: seconds + SettingsManager.shared.lyricsOffset)
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
        WidgetSnapshotStore.update(track: currentTrack, lyric: snapshotLyric)
        #if os(iOS)
        let previousLyric = liveActivityLyric
        liveActivityLyric = snapshotLyric
        NowPlayingManager.shared.updateCurrentLyric(snapshotLyric)
        // ActivityKit cannot observe the app's LyricsCursor directly. Push a
        // state update when the active line changes so the expanded island and
        // lock-screen activity show the same line as the in-app player.
        if previousIndex != index || previousLyric != snapshotLyric {
            syncLiveActivity()
        }
        #endif
    }

    func refreshLyricsCursor() {
        updateLyricsCursor(at: livePlaybackTime)
    }

    private func publishLyrics(_ parsed: ParsedLyrics, for track: Track, generation: Int) {
        lyrics = parsed
        updateLyricsCursor(at: livePlaybackTime)

        // Many source adapters provide the original lyrics but omit the
        // translation field. Enrich the already-visible lyrics from a public
        // NetEase metadata match so English/Japanese songs can show a
        // translation when one exists, without delaying first paint.
        guard parsed.lines.contains(where: { $0.translation == nil }) else { return }
        Task { [weak self] in
            await self?.enrichTranslation(for: track, base: parsed, generation: generation)
        }
    }

    private func enrichTranslation(for track: Track, base: ParsedLyrics,
                                   generation: Int) async {
        let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
        let candidate: Track?
        if ["wy", "netease", "163"].contains(source) {
            candidate = track
        } else {
            candidate = try? await NeteaseAPI.matchingSong(for: track,
                                                           requireDuration: false)
        }
        guard let candidate,
              let response = try? await NeteaseAPI.lyric(id: candidate.id) else { return }
        let metadata = LyricsParser.parse(response, includeVerbatim: false)
        guard !metadata.isEmpty, generation == resolveGeneration else { return }

        var merged = base
        var changed = false
        for index in merged.lines.indices where merged.lines[index].translation == nil {
            guard let nearest = metadata.lines.min(by: {
                abs($0.time - merged.lines[index].time) < abs($1.time - merged.lines[index].time)
            }), abs(nearest.time - merged.lines[index].time) < 0.5,
                  let translation = nearest.translation, !translation.isEmpty else { continue }
            merged.lines[index].translation = translation
            changed = true
        }
        guard changed, generation == resolveGeneration else { return }
        lyrics = merged
    }

    func seek(to seconds: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        progress = seconds
        updateLyricsCursor(at: seconds)
        engine.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            guard let completion else { return }
            Task { @MainActor in completion() }
        }
        NowPlayingManager.shared.updateElapsed(
            seconds,
            rate: isPlaying ? Double(playbackRate) : 0
        )
        syncLiveActivity()
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
                    syncLiveActivity()
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
            syncLiveActivity()
            return
        }
        advanceToNext(userInitiated: false)
    }

    // MARK: - Source resolution

    private func startPlaying(_ track: Track, indexUnchanged: Bool = false,
                              resumeAt: TimeInterval? = nil,
                              preserveTrackQualityOverride: Bool = false) {
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
        WidgetSnapshotStore.update(track: track, lyric: nil)
        progress = resumeAt ?? 0
        lastLiveActivityProgress = progress - 5
        #if os(iOS)
        liveActivityLyric = nil
        #endif
        pendingSeek = resumeAt
        duration = track.duration
        servedQuality = nil
        unblockSource = nil
        isTrial = false
        lyrics = nil
        scrobbled = false
        startScrobbled = false
        isPlaying = true
        syncLiveActivity(newTrack: true)
        lyricsCursor.activeIndex = nil
        // Before the URL is even resolved: holds the bars still rather than
        // letting them fall back to the decorative animation for the moment it
        // takes to find out whether this source can be tapped.
        AudioSpectrum.shared.beginPreparing()
        resolveGeneration += 1
        let generation = resolveGeneration

        NowPlayingManager.shared.updateMetadata(for: track, duration: track.duration)
        persistState()

        Task {
            await resolveAndLoad(
                track,
                generation: generation,
                requestedQuality: requestedQuality
            )
        }
        Task {
            await loadLyrics(for: track, generation: generation)
        }
    }

    private func resolveAndLoad(_ track: Track, generation: Int,
                                requestedQuality: AudioQuality) async {
        let quality = requestedQuality.rawValue
#if os(macOS)
        let isLXCatalogTrack = track.source != nil
#endif
        var resolvedURL: URL?
        var servedByLXQuality: String?
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
                syncLiveActivity()
                return
            }
            if playbackMode != .thirdParty, hasOfficialAccount,
               let official = await resolveOfficialAudio(
                for: track, quality: requestedQuality
               ) {
                resolvedURL = official.url
                servedByLXQuality = official.quality
            }

            if resolvedURL == nil, playbackMode != .official, hasLXSource {
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
                    do {
                        let candidate = try await LXUserAPIService.shared.resolveMusicURL(
                            for: track,
                            quality: quality,
                            excludingURLs: rejectedPreviewURLs
                        )
                        if await isLikelyPreviewURL(candidate.url, expectedDuration: track.duration) {
                            rejectedPreviewURLs.insert(candidate.url.absoluteString)
                            lastError = LXUserAPIService.LXError.sourceUnavailable(
                                "闊虫簮杩斿洖 30 绉掕瘯鍚墖娈碉紝宸插垏鎹㈠鐢ㄩ煶婧?"
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
            } catch {
                guard generation == resolveGeneration else { return }
                consecutiveFailures += 1
                ToastCenter.shared.show("《\(track.name)》播放失败：\(error.localizedDescription)")
                // A source-level error is not fixed by immediately trying five
                // more queue entries. Keep the current song visible so the user
                // can adjust the source or retry after reading the real error.
                isPlaying = false
                syncLiveActivity()
                return
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
            ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放\(reason.map { "：\($0)" } ?? "")"))
            if consecutiveFailures < 5 {
                advanceToNext(userInitiated: false)
            } else {
                isPlaying = false
                syncLiveActivity()
            }
            return
        }

        consecutiveFailures = 0
#if os(iOS)
        servedQuality = servedByLXQuality
        NowPlayingManager.shared.updateResolvedQuality(servedQuality, for: track)
#else
        servedQuality = servedByLXQuality ?? data?.level
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
        let asset = AVURLAsset(url: url)
        let assetTrack = await loadAudioTrack(from: asset, timeout: 2)
        guard generation == resolveGeneration else { return }

        let item = AVPlayerItem(asset: asset)
        if let assetTrack, let mix = AudioSpectrum.shared.makeAudioMix(for: assetTrack) {
            item.audioMix = mix
        } else {
            AudioSpectrum.shared.markUntappable()
        }

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
        engine.replaceCurrentItem(with: item)
        let seekPosition = pendingSeek
        pendingSeek = nil
        if let seekPosition, seekPosition > 0 {
            engine.seek(to: CMTime(seconds: seekPosition, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, generation == self.resolveGeneration else { return }
                    self.engine.play()
                    self.engine.rate = self.playbackRate
                }
            }
        } else {
            engine.play()
            engine.rate = playbackRate
        }
        isPlaying = true

        if !startScrobbled {
            startScrobbled = true
#if os(iOS)
            syncListeningStart(track: track, sourceID: source.sourceID)
#else
            let tid = track.id
            let sid = source.sourceID
            Task.detached { await NeteaseAPI.scrobbleStart(trackID: tid, sourceID: sid) }
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
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Resolve a full-length provider URL using the account belonging to the
    /// track's catalogue. The returned quality is the provider's response.
    private func resolveOfficialAudio(for track: Track, quality: AudioQuality) async -> OfficialAudio? {
        let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
        let candidates = qualityCandidates(startingAt: quality)

        if source.isEmpty || ["wy", "163", "netease", "neteasecloudmusic", "cloudmusic"].contains(source),
           NeteaseClient.shared.isLoggedIn {
            for candidate in candidates {
                guard let data = (try? await NeteaseAPI.songURL(
                    ids: [track.id], level: candidate.neteaseLevel
                ))?.first,
                data.freeTrialInfo == nil,
                data.time <= 0 || track.duration <= 0
                    || TimeInterval(data.time) / 1000 >= max(45, track.duration * 0.65),
                let rawURL = data.url,
                let url = validAudioURL(rawURL) else { continue }
                return OfficialAudio(url: url, quality: NeteaseAPI.officialQuality(for: data).lxType)
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
            for candidate in candidates {
                let token = qqQualityToken(for: candidate)
                guard attempted.insert(token).inserted,
                      let resolved = try? await QQMusicAPI.shared.musicURL(
                        songMid: songMid, mediaMid: mediaMid, quality: token, cookie: cookie
                      ),
                      let actual = AudioQuality(lxType: resolved.quality) else { continue }
                return OfficialAudio(url: resolved.url, quality: actual.lxType)
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
            for candidate in candidates {
                let token = candidate.lxType
                guard attempted.insert(token).inserted,
                      let resolved = try? await KugouAPI.shared.musicURL(
                        hash: hash, quality: token, cookie: cookie,
                        albumID: albumID, albumAudioID: albumAudioID
                      ),
                      let actual = AudioQuality(lxType: resolved.quality) else { continue }
                return OfficialAudio(url: resolved.url, quality: actual.lxType)
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

    private func loadLyrics(for track: Track, generation: Int) async {
#if os(iOS)
        let sourceKey = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
        if ["wy", "netease", "163"].contains(sourceKey),
           let response = try? await NeteaseAPI.lyric(id: track.id) {
            guard generation == resolveGeneration else { return }
            let parsed = LyricsParser.parse(response)
            if !parsed.isEmpty {
                publishLyrics(parsed, for: track, generation: generation)
                return
            }
        }

        // Prefer the selected LX source's own lyric action. It may expose
        // yrc/lxlyric word timings that the catalogue adapters do not have.
        if !sourceKey.isEmpty,
           LXSourceStore.shared.selectedSource != nil,
           let lx = try? await LXUserAPIService.shared.resolveLyrics(for: track) {
            guard generation == resolveGeneration else { return }
            let parsed = LyricsParser.parseLX(lyric: lx.lyric, tlyric: lx.tlyric,
                                               rlyric: lx.rlyric, lxlyric: lx.lxlyric,
                                               yrc: lx.yrc)
            if !parsed.isEmpty {
               publishLyrics(parsed, for: track, generation: generation)
               return
            }
        }

        // Catalogue lyrics are metadata only. Playback is still resolved by
        // the selected LX User API source in resolveAndLoad(_:generation:requestedQuality:).
        if !sourceKey.isEmpty,
           let native = try? await LXCatalogService.nativeLyrics(for: track) {
            guard generation == resolveGeneration else { return }
            let parsed = LyricsParser.parseLX(lyric: native.lyric, tlyric: native.tlyric,
                                               rlyric: native.rlyric, lxlyric: native.lxlyric)
            if !parsed.isEmpty {
               publishLyrics(parsed, for: track, generation: generation)
               return
            }
        }

        // If this platform has no lyric endpoint or no result, search every
        // supported catalogue platform by metadata. IDs are never reused
        // across platforms, so a matched track is required before fetching.
        let fallbackPlatforms = ["tx", "wy", "kw", "kg", "mg"]
        for platform in fallbackPlatforms where platform != sourceKey {
            guard let matched = await LXCatalogService.matchingTrack(track, on: platform),
                  let native = try? await LXCatalogService.nativeLyrics(for: matched) else {
                continue
            }
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

        // LX catalogue IDs are platform-specific. If the selected source has
        // no lyric implementation, use a public NetEase catalogue match only
        // for lyric metadata; audio still comes exclusively from LX.
        if !sourceKey.isEmpty {
            if let candidate = try? await NeteaseAPI.matchingSong(for: track),
               let response = try? await NeteaseAPI.lyric(id: candidate.id) {
                let parsed = LyricsParser.parse(response, includeVerbatim: false)
                if !parsed.isEmpty {
                    guard generation == resolveGeneration else { return }
               publishLyrics(parsed, for: track, generation: generation)
               return
                }
            }
        }

        // Do not leave the lyric panel in a permanent loading state when no
        // provider has lyrics for this track.
        guard generation == resolveGeneration else { return }
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
                try? await Task.sleep(for: .seconds(3))
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
        // Listening history only needs the NetEase auth cookie. Requiring the
        // profile here made a temporary account/profile request failure look
        // like a logged-out account and silently skipped the sync.
        guard NeteaseClient.shared.isLoggedIn else { return }
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
        guard NeteaseClient.shared.isLoggedIn else {
            ListeningSyncStore.shared.recordFailure()
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
        Task.detached {
            await NeteaseAPI.scrobbleFinish(trackID: track.id, sourceID: sourceID, seconds: seconds)
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
            return (try await NeteaseAPI.playRecords(uid: uid, week: false).map(\.song), .none)
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
