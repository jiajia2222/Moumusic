#if os(iOS)
import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// One danmaku item with its lane already decided, so drawing is a cheap lookup.
struct PlacedDanmaku: Sendable {
    let text: String
    let color: UInt32
    let start: Double
    let mode: Int
    let lane: Int
}

/// Native Bilibili player model: AVPlayer (video + audio DASH tracks composed
/// into one item), Picture in Picture, AirPlay, 2x press-and-hold, danmaku lanes.
@MainActor
final class BiliPlayerModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isReady = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 1
    @Published private(set) var isBoosting = false
    @Published private(set) var isPiPActive = false
    @Published private(set) var canPiP = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var placedDanmaku: [PlacedDanmaku] = []
    @Published var isScrubbing = false

    let player = AVPlayer()
    var onError: ((String) -> Void)?
    /// Catalogue length of the video; keeps the seek bar usable while the stream reports no duration.
    var fallbackDuration: Double = 0
    /// Per-video key for 续播 (resume where you left off); nil disables it.
    var resumeKey: String?
    /// Title / UP / cover shown on the lock screen and in Control Center while the video plays.
    var nowPlayingMeta: (title: String, author: String, cover: String?)?
    private var lastNowPlayingPush: Double = -10
    /// Called about every 15 s of playback and on stop, to sync 观看历史 to the account.
    var onProgressReport: ((Int) -> Void)?
    private var lastReported: Double = -100
    private var lastSavedResume: Double = 0
    private var resumeApplied = false
    private static let resumeStoreKey = "moumusic.bili.resume"

    private var pipController: AVPictureInPictureController?
    private weak var inlineLayer: AVPlayerLayer?
    private weak var fullscreenLayer: AVPlayerLayer?
    private var timeObserver: Any?
    private var stallTimer: Timer?
    private var controlObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var loadedKey = ""
    private var userRate: Float = 1

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in self?.tick(time) }
        }
        stallTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkStall() }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in self?.apply(status) }
        }
        // iOS suspends video playback in the background while a layer shows the player; detaching
        // the layers (QA1668) lets the audio carry on (live streams and videos alike).
        backgroundObservers = [
            NotificationCenter.default.addObserver(forName: .moumusicSleepTimerFired, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pause() }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isPiPActive else { return }
                    self.inlineLayer?.player = nil
                    self.fullscreenLayer?.player = nil
                }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.inlineLayer?.player = self.player
                    self.fullscreenLayer?.player = self.player
                }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleBecameActive() }
            }
        ]
    }

    private var backgroundObservers: [NSObjectProtocol] = []

    /// Bumped to rebuild the danmaku overlay (it can stop drawing across picture-in-picture / background).
    @Published private(set) var danmakuRefreshToken = UUID()
    /// Re-fetches the danmaku source (video: XML list, live: chat socket).
    var onRefreshDanmaku: (() -> Void)?

    func refreshDanmaku() {
        danmakuRefreshToken = UUID()
        onRefreshDanmaku?()
    }

    /// Returning to the app: the video comes back into the page (picture-in-picture closes by itself)
    /// and the danmaku is refreshed, since it may not have been drawn while the app was away.
    private func handleBecameActive() {
        if isPiPActive { pipController?.stopPictureInPicture() }
        inlineLayer?.player = player
        fullscreenLayer?.player = player
        refreshDanmaku()
    }

    deinit {
        backgroundObservers.forEach { NotificationCenter.default.removeObserver($0) }
        stallTimer?.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    // MARK: Loading

    func load(video: URL?, audio: URL?, dash: BiliDashSource? = nil, autoplay: Bool) {
        let key = "\(video?.absoluteString ?? "")|\(audio?.absoluteString ?? "")|\(dash == nil ? "c" : "h")"
        guard key != loadedKey else { return }
        loadedKey = key
        let storedRate = UserDefaults.standard.double(forKey: "moumusic.bili.defaultRate")
        if storedRate > 0, abs(Float(storedRate) - userRate) > 0.001, !isLive {
            userRate = Float(storedRate)
            rate = userRate
        }
        usingHLS = dash != nil
        isLive = video?.absoluteString.lowercased().contains(".m3u8") == true
        player.automaticallyWaitsToMinimizeStalling = true
        fallbackVideo = video
        fallbackAudio = audio
        wasAutoplay = autoplay
        loadTask?.cancel()
        isReady = false
        resumeApplied = false
        lastSavedResume = 0
        currentTime = 0
        duration = fallbackDuration
        guard let video else {
            player.replaceCurrentItem(with: nil)
            isPreparing = false
            return
        }
        isPreparing = true
        loadTask = Task { [weak self] in
            let item = await Self.makeItem(video: video, audio: audio, dash: dash)
            guard let self, !Task.isCancelled else { return }
            self.install(item, autoplay: autoplay)
        }
    }

    private(set) var isLive = false
    private var lastLiveCatchUp = Date()
    private var usingHLS = false

    private var liveLaneFree = [Double](repeating: 0, count: 14)

    /// Adds one live-room chat message to the scrolling overlay.
    func pushLiveDanmaku(text: String, color: Int) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !BiliDanmakuSettings.blockWords.contains(where: { clean.localizedCaseInsensitiveContains($0) }) else { return }
        let now = player.currentTime().seconds
        guard now.isFinite, let lane = Self.pickLane(&liveLaneFree, at: now, hold: max(1.6, BiliDanmakuSettings.scrollDuration * 0.3)) else { return }
        placedDanmaku.append(PlacedDanmaku(text: clean, color: UInt32(truncatingIfNeeded: color), start: now, mode: 1, lane: lane))
        if placedDanmaku.count > 240 { placedDanmaku.removeFirst(placedDanmaku.count - 240) }
    }

    /// Community "skip this" ranges (sponsors, self-promotion); jumped over once each while playing.
    var skipSegments: [(start: Double, end: Double)] = []
    private var skippedSegments = Set<Int>()

    private func applySkipSegments() {
        guard player.timeControlStatus == .playing, !skipSegments.isEmpty else { return }
        for (index, segment) in skipSegments.enumerated()
        where !skippedSegments.contains(index) && currentTime >= segment.start && currentTime < segment.end - 0.5 {
            skippedSegments.insert(index)
            seek(to: segment.end)
            ToastCenter.shared.show("已跳过广告片段")
            return
        }
    }

    /// Jumps to the newest part of a live stream.
    func seekToLiveEdge() {
        guard let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let target = CMTimeSubtract(CMTimeRangeGetEnd(range), CMTime(seconds: 1.5, preferredTimescale: 600))
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        lastLiveCatchUp = Date()
    }
    private var fallbackVideo: URL?
    private var fallbackAudio: URL?
    private var wasAutoplay = true

    nonisolated private static func makeItem(video: URL, audio: URL?, dash: BiliDashSource?) async -> AVPlayerItem {
        // Live streams are HLS playlists: AVPlayer reads them itself (with the Referer the CDN wants).
        if video.absoluteString.lowercased().contains(".m3u8") {
            let asset = AVURLAsset(url: video, options: ["AVURLAssetHTTPHeaderFieldsKey": [
                "Referer": "https://live.bilibili.com/",
                "User-Agent": userAgent
            ]])
            let item = AVPlayerItem(asset: asset)
            item.automaticallyPreservesTimeOffsetFromLive = true
            // A few seconds behind the edge is what keeps live playback smooth; 2 s stuttered.
            item.configuredTimeOffsetFromLive = CMTime(seconds: 5, preferredTimescale: 600)
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            return item
        }
        if let dash {
            return AVPlayerItem(asset: BiliHLSLoader.asset(for: dash, userAgent: userAgent))
        }
        let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": [
            "Referer": "https://www.bilibili.com/",
            "User-Agent": userAgent
        ]]
        // DASH segments are `.m4s` and several CDN nodes answer `application/octet-stream`, which
        // AVFoundation refuses ("无法打开"). Every stream goes through the loader, which declares
        // the data as MPEG-4 (and re-tags hev1 HEVC as hvc1).
        _ = options
        let videoAsset = BiliHEVCLoader.asset(for: video, userAgent: userAgent, retag: video.fragment == "mou-hev1")
        guard let audio else { return AVPlayerItem(asset: videoAsset) }
        let audioAsset = BiliHEVCLoader.asset(for: audio, userAgent: userAgent, retag: false)
        do {
            // Load both streams at the same time instead of one after the other.
            async let videoTracksTask = videoAsset.loadTracks(withMediaType: .video)
            async let audioTracksTask = audioAsset.loadTracks(withMediaType: .audio)
            async let videoDurationTask = videoAsset.load(.duration)
            async let audioDurationTask = audioAsset.load(.duration)
            let videoTracks = try await videoTracksTask
            let audioTracks = try await audioTracksTask
            let videoDuration = try await videoDurationTask
            let audioDuration = try await audioDurationTask
            guard let sourceVideo = videoTracks.first, let sourceAudio = audioTracks.first else {
                return AVPlayerItem(asset: videoAsset)
            }
            // Keep each track's own start time: DASH segments often begin a few tens of
            // milliseconds apart, and forcing both to zero is what made sound and picture drift.
            let videoRange = try await sourceVideo.load(.timeRange)
            let audioRange = try await sourceAudio.load(.timeRange)
            let base = CMTimeMinimum(videoRange.start, audioRange.start)
            let available = CMTimeMinimum(videoRange.duration, audioRange.duration)
            let length = (audioDuration.isNumeric && audioDuration > .zero && videoDuration.isNumeric)
                ? CMTimeMinimum(CMTimeMinimum(videoDuration, audioDuration), available) : available
            let composition = AVMutableComposition()
            if let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try videoTrack.insertTimeRange(CMTimeRange(start: videoRange.start, duration: length), of: sourceVideo,
                                               at: CMTimeSubtract(videoRange.start, base))
                videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
            }
            if let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try audioTrack.insertTimeRange(CMTimeRange(start: audioRange.start, duration: length), of: sourceAudio,
                                               at: CMTimeSubtract(audioRange.start, base))
            }
            return AVPlayerItem(asset: composition)
        } catch {
            // Without the separate audio the picture still plays.
            let detail = error.localizedDescription
            Task { @MainActor in
                DiagnosticLogStore.shared.append(level: .warning, category: "哔哩哔哩播放", message: "音视频合成失败，仅播放画面", detail: detail)
            }
            return AVPlayerItem(asset: videoAsset)
        }
    }

    private func install(_ item: AVPlayerItem, autoplay: Bool) {
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.isPreparing = false
                    self.isReady = true
                    self.applyResumeIfNeeded()
                    self.watchForPicture(item)
                case .failed:
                    if self.usingHLS, let video = self.fallbackVideo {
                        // HLS could not open this stream: stitch the two files together instead.
                        self.usingHLS = false
                        let audio = self.fallbackAudio, autoplay = self.wasAutoplay
                        DiagnosticLogStore.shared.append(level: .warning, category: "哔哩哔哩播放", message: "HLS 播放失败，改用合成播放",
                                                         detail: message ?? "未知错误")
                        self.loadTask?.cancel()
                        self.loadTask = Task { [weak self] in
                            let item = await Self.makeItem(video: video, audio: audio, dash: nil)
                            guard let self, !Task.isCancelled else { return }
                            self.install(item, autoplay: autoplay)
                        }
                        return
                    }
                    self.isPreparing = false
                    self.onError?("B 站视频播放失败：\(message ?? "未知错误")")
                default:
                    break
                }
            }
        }
        videoOutput = nil
        frozenCount = 0
        lastFrameAt = Date()
        if expectsPicture {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output)
            videoOutput = output
        }
        player.replaceCurrentItem(with: item)
        rebuildPiP()
        guard autoplay else { return }
        play()
    }

    // MARK: Transport

    private func apply(_ status: AVPlayer.TimeControlStatus) {
        isPlaying = status != .paused
        isBuffering = status == .waitingToPlayAtSpecifiedRate
        publishNowPlaying(force: true)
    }

    /// Playback that should be running but has not advanced for a while gets nudged with a
    /// seek, which makes AVPlayer issue fresh range requests instead of hanging forever.
    private var lastAdvanceTime: Double = -1
    private var lastAdvanceAt = Date()

    @Published private(set) var isWaitingForPicture = false
    private var videoOutput: AVPlayerItemVideoOutput?
    private var lastFrameAt = Date()
    private var frozenCount = 0

    /// The clock can keep running on the audio while the video decoder has stopped producing
    /// pictures (undecodable stream, starved video segment). A video output on the item tells
    /// us whether new frames are still arriving.
    private func checkFrames() {
        guard expectsPicture, !isLive, let output = videoOutput, player.timeControlStatus == .playing,
              !isScrubbing, currentTime > 1 else {
            lastFrameAt = Date()
            if isWaitingForPicture { isWaitingForPicture = false }
            return
        }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time) {
            _ = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
            lastFrameAt = Date()
            if isWaitingForPicture { isWaitingForPicture = false }
            return
        }
        if Date().timeIntervalSince(lastFrameAt) > 1.2, !isWaitingForPicture { isWaitingForPicture = true }
        guard Date().timeIntervalSince(lastFrameAt) > 3 else { return }
        // Audio ran ahead of the still-buffering picture: re-sync both tracks at the current
        // position so playback waits for the video instead of running on blind. Only a stream
        // that never recovers is handed to the codec / CDN fallback.
        lastFrameAt = Date()
        frozenCount += 1
        DiagnosticLogStore.shared.append(level: .warning, category: "哔哩哔哩播放", message: "画面落后于声音，重新同步缓冲",
                                         detail: String(format: "%.1fs，第 %d 次", currentTime, frozenCount))
        if frozenCount >= 4 {
            frozenCount = 0
            onError?("画面卡住")
            return
        }
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func checkStall() {
        if isLive, player.timeControlStatus == .playing, Date().timeIntervalSince(lastLiveCatchUp) > 5,
           let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue {
            // Drifted more than 6 s behind the broadcaster (after buffering): catch up.
            let behind = CMTimeGetSeconds(CMTimeRangeGetEnd(range)) - CMTimeGetSeconds(item.currentTime())
            if behind > 14 { seekToLiveEdge() } else { lastLiveCatchUp = Date() }
        }
        checkFrames()
        guard player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
            lastAdvanceAt = Date()
            return
        }
        if abs(currentTime - lastAdvanceTime) > 0.05 {
            lastAdvanceTime = currentTime
            lastAdvanceAt = Date()
            return
        }
        guard Date().timeIntervalSince(lastAdvanceAt) > 8 else { return }
        lastAdvanceAt = Date()
        DiagnosticLogStore.shared.append(level: .warning, category: "哔哩哔哩播放", message: "播放卡住，已自动重新缓冲",
                                         detail: String(format: "%.1fs", currentTime))
        player.seek(to: CMTime(seconds: currentTime + 0.2, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .positiveInfinity) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.play()
                self.player.rate = self.isBoosting ? 2 : self.userRate
            }
        }
    }

    private func tick(_ time: CMTime) {
        if !isScrubbing, time.isNumeric { currentTime = max(0, time.seconds) }
        checkStall()
        if let item = player.currentItem, item.duration.isNumeric {
            let value = item.duration.seconds
            if value.isFinite, value > 0, abs(value - duration) > 0.5 { duration = value }
        } else if duration <= 0, fallbackDuration > 0 {
            duration = fallbackDuration
        }
        saveResumeIfNeeded()
        applySkipSegments()
        publishNowPlaying()
        if isPlaying, abs(currentTime - lastReported) >= 15 {
            lastReported = currentTime
            onProgressReport?(Int(currentTime))
        }
    }

    /// Sound but no picture (a codec this device cannot render): report it so the view can try
    /// the next codec / CDN of the same quality.
    var expectsPicture = true
    private func watchForPicture(_ item: AVPlayerItem) {
        Task { @MainActor [weak self, weak item] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, let item, self.expectsPicture, self.player.currentItem === item,
                  item.presentationSize == .zero, self.currentTime > 1 else { return }
            self.onError?("只有声音没有画面")
        }
    }

    // MARK: 续播

    private func applyResumeIfNeeded() {
        guard !resumeApplied, let key = resumeKey else { return }
        resumeApplied = true
        let store = UserDefaults.standard.dictionary(forKey: Self.resumeStoreKey) as? [String: Double] ?? [:]
        guard let saved = store[key], saved > 10, duration <= 0 || saved < duration - 15 else { return }
        seek(to: saved)
        let minutes = Int(saved) / 60, seconds = Int(saved) % 60
        ToastCenter.shared.show(String(format: "已从上次位置 %d:%02d 继续播放", minutes, seconds))
    }

    private func saveResumeIfNeeded() {
        guard let key = resumeKey, resumeApplied, abs(currentTime - lastSavedResume) >= 5 else { return }
        lastSavedResume = currentTime
        var store = UserDefaults.standard.dictionary(forKey: Self.resumeStoreKey) as? [String: Double] ?? [:]
        // Finished videos start from the beginning next time.
        if duration > 0, currentTime >= duration - 15 { store[key] = nil } else { store[key] = currentTime }
        if store.count > 300 { store = Dictionary(uniqueKeysWithValues: store.shuffled().prefix(250).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(store, forKey: Self.resumeStoreKey)
    }

    private func publishNowPlaying(force: Bool = false) {
        guard let meta = nowPlayingMeta else { return }
        guard force || abs(currentTime - lastNowPlayingPush) >= 1 else { return }
        lastNowPlayingPush = currentTime
        NowPlayingManager.shared.updateExternal(
            title: meta.title, artist: meta.author, coverURL: meta.cover,
            elapsed: currentTime, duration: duration, rate: isPlaying ? Double(player.rate) : 0,
            handler: .init(
                play: { [weak self] in self?.play() },
                pause: { [weak self] in self?.pause() },
                toggle: { [weak self] in self?.togglePlay() },
                seek: { [weak self] in self?.seek(to: $0) },
                skip: { [weak self] in self?.skip(by: $0) }
            ))
    }

    func play() {
        activateAudioSession()
        if PlayerService.shared.isPlaying { PlayerService.shared.pause() }
        if duration > 0, currentTime >= duration - 0.5 { seek(to: 0) }
        player.play()
        player.rate = isBoosting ? 2 : userRate
    }

    func pause() {
        player.pause()
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        if !isPiPActive { NowPlayingManager.shared.endExternal() }
        if currentTime > 1 { onProgressReport?(Int(currentTime)) }
        loadTask?.cancel()
        if !isPiPActive { player.pause() }
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, seconds)
    }

    func scrub(to seconds: Double) {
        currentTime = seconds
    }

    func skip(by delta: Double) {
        let limit = duration > 0 ? duration : .greatestFiniteMagnitude
        seek(to: min(max(0, currentTime + delta), limit))
    }

    func setRate(_ value: Float) {
        userRate = value
        rate = value
        if isPlaying, !isBoosting { player.rate = value }
    }

    func beginBoost() {
        guard !isBoosting, isPlaying else { return }
        isBoosting = true
        player.rate = 2
    }

    func endBoost() {
        guard isBoosting else { return }
        isBoosting = false
        if isPlaying { player.rate = userRate }
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // Keep the user's "与其他音频同时播放" choice: resetting the options here is what made the
        // setting stop working after a video had played.
        let mix: AVAudioSession.CategoryOptions = UserDefaults.standard.bool(forKey: "moumusic.mixWithOthers") ? [.mixWithOthers] : []
        try? session.setCategory(.playback, mode: .moviePlayback, options: mix)
        try? session.setActive(true)
    }

    // MARK: Picture in Picture

    func register(layer: AVPlayerLayer, fullscreen: Bool) {
        if fullscreen { fullscreenLayer = layer } else { inlineLayer = layer }
        rebuildPiP()
    }

    func unregister(fullscreen: Bool) {
        if fullscreen { fullscreenLayer = nil } else { inlineLayer = nil }
        rebuildPiP()
    }

    private func rebuildPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let layer = fullscreenLayer ?? inlineLayer else {
            pipController = nil
            return
        }
        if pipController?.playerLayer === layer { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
    }

    /// The button is shown whenever the device supports PiP; the controller is (re)built on
    /// demand so a layer registered before the item was ready no longer hides it for good.
    func togglePiP() {
        rebuildPiP()
        guard let pip = pipController else {
            ToastCenter.shared.show("画中画暂时不可用")
            return
        }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        } else {
            DiagnosticLogStore.shared.append(level: .warning, category: "哔哩哔哩播放", message: "画中画不可用",
                                             detail: "isPictureInPicturePossible=false")
            ToastCenter.shared.show("视频加载完成后才能开启画中画")
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        let detail = error.localizedDescription
        Task { @MainActor in
            DiagnosticLogStore.shared.append(level: .error, category: "哔哩哔哩播放", message: "画中画启动失败", detail: detail)
            ToastCenter.shared.show("画中画启动失败")
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.isPiPActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.isPiPActive = false
            self?.refreshDanmaku()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }

    // MARK: Danmaku

    func setDanmaku(_ cues: [BilibiliAPI.DanmakuCue]) {
        let sorted = cues.sorted { $0.start < $1.start }
        var scrollFree = [Double](repeating: 0, count: 14)
        var topFree = [Double](repeating: 0, count: 6)
        var bottomFree = [Double](repeating: 0, count: 6)
        var out: [PlacedDanmaku] = []
        out.reserveCapacity(sorted.count)
        let blocked = BiliDanmakuSettings.blockWords
        for cue in sorted {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !blocked.contains(where: { text.localizedCaseInsensitiveContains($0) }) else { continue }
            let lane: Int?
            switch cue.mode {
            case 4: lane = Self.pickLane(&bottomFree, at: cue.start, hold: 4)
            case 5: lane = Self.pickLane(&topFree, at: cue.start, hold: 4)
            default: lane = Self.pickLane(&scrollFree, at: cue.start, hold: max(1.6, BiliDanmakuSettings.scrollDuration * 0.3))
            }
            guard let lane else { continue }
            out.append(PlacedDanmaku(text: text, color: cue.color, start: cue.start, mode: cue.mode, lane: lane))
        }
        placedDanmaku = out
    }

    /// First free lane, or nil when every lane stays busy for too long (dense passages are thinned out).
    private static func pickLane(_ lanes: inout [Double], at time: Double, hold: Double) -> Int? {
        if let free = lanes.firstIndex(where: { $0 <= time }) {
            lanes[free] = time + hold
            return free
        }
        guard let soonest = lanes.indices.min(by: { lanes[$0] < lanes[$1] }),
              lanes[soonest] - time < 1.2 else { return nil }
        lanes[soonest] = max(lanes[soonest], time) + hold
        return soonest
    }

    nonisolated static func active(in list: [PlacedDanmaku], at time: Double) -> [PlacedDanmaku] {
        guard !list.isEmpty else { return [] }
        var low = 0
        var high = list.count
        let from = time - max(BiliDanmakuSettings.scrollDuration, 4)
        while low < high {
            let mid = (low + high) / 2
            if list[mid].start < from { low = mid + 1 } else { high = mid }
        }
        var result: [PlacedDanmaku] = []
        var index = low
        while index < list.count, list[index].start <= time, result.count < 120 {
            let item = list[index]
            let life: Double = (item.mode == 4 || item.mode == 5) ? 4 : BiliDanmakuSettings.scrollDuration
            if time - item.start <= life { result.append(item) }
            index += 1
        }
        return result
    }
}

// MARK: - Layer / route picker bridges

final class BiliPlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct BiliPlayerLayerView: UIViewRepresentable {
    let model: BiliPlayerModel
    let isFullscreen: Bool

    final class Coordinator {
        let model: BiliPlayerModel
        let isFullscreen: Bool
        init(model: BiliPlayerModel, isFullscreen: Bool) {
            self.model = model
            self.isFullscreen = isFullscreen
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, isFullscreen: isFullscreen) }

    func makeUIView(context: Context) -> BiliPlayerLayerUIView {
        let view = BiliPlayerLayerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = model.player
        view.playerLayer.videoGravity = .resizeAspect
        model.register(layer: view.playerLayer, fullscreen: isFullscreen)
        return view
    }

    func updateUIView(_ uiView: BiliPlayerLayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: BiliPlayerLayerUIView, coordinator: Coordinator) {
        let model = coordinator.model
        let fullscreen = coordinator.isFullscreen
        Task { @MainActor in model.unregister(fullscreen: fullscreen) }
    }
}

struct BiliRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemPink
        view.prioritizesVideoDevices = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Player view

struct BiliNativePlayer: View {
    @ObservedObject var model: BiliPlayerModel
    let cues: [BilibiliAPI.SubtitleCue]
    let danmaku: [BilibiliAPI.DanmakuCue]
    let danmakuEnabled: Bool
    let subtitles: [BilibiliAPI.Subtitle]
    let selectedSubtitleID: String?
    let onSelectSubtitle: (BilibiliAPI.Subtitle?) -> Void
    let posterURL: String?
    let audioOnly: Bool
    var title: String? = nil
    var isFullscreen = false
    var rotatesInFullscreen = true
    /// 0 none, 1 light (default), 2 strong: the dark fade behind the control bars.
    @AppStorage("moumusic.bili.controlScrim") private var scrimLevel = 1
    private var scrimTop: Double { [0, 0.28, 0.6][min(max(scrimLevel, 0), 2)] }
    private var scrimBottom: Double { [0, 0.34, 0.7][min(max(scrimLevel, 0), 2)] }
    var onFullscreen: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    /// Sends one danmaku; returns true when it was accepted. nil hides the 发弹幕 button.
    var onSendDanmaku: ((BiliDanmakuDraft) async -> Bool)? = nil

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// A vertical video follows the phone: a portrait full screen while upright, a landscape one (pillarboxed)
    /// when the phone is already on its side - forcing portrait there is what showed the picture sideways.
    private var landscapeLayout: Bool { rotatesInFullscreen || verticalSizeClass == .compact }

    @State private var showComposer = false
    @State private var composerText = ""
    @State private var draftMode = 1
    @State private var draftColor: UInt32 = 0xFFFFFF
    @State private var draftSize = 25
    @State private var sendingDanmaku = false
    @FocusState private var composerFocused: Bool

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showDanmaku = true
    /// Target time while the user drags horizontally on the picture to seek.
    @State private var swipeSeekTarget: Double?
    @State private var swipeSeekStart: Double = 0

    private var danmakuKey: String { "\(danmaku.count)-\(danmaku.first?.id ?? "")" }

    private var currentSubtitle: String? {
        guard selectedSubtitleID != nil else { return nil }
        let now = model.currentTime + 0.08
        return cues.first(where: { $0.start <= now && now <= $0.end })?.text
    }

    var body: some View {
        ZStack {
            Color.black
            BiliPlayerLayerView(model: model, isFullscreen: isFullscreen)
                .opacity(audioOnly ? 0 : 1)
            if audioOnly || !model.isReady {
                posterView
            }
            if showDanmaku, !audioOnly {
                danmakuCanvas
                    .id(model.danmakuRefreshToken)
            }
            if let text = currentSubtitle {
                VStack {
                    Spacer()
                    Text(text)
                        .font(.system(size: isFullscreen ? 20 : 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 24)
                        .padding(.bottom, controlsVisible ? 78 : 16)
                }
                .allowsHitTesting(false)
            }
            if model.isPreparing || model.isBuffering || model.isWaitingForPicture {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.3)
                    .allowsHitTesting(false)
            }
            if model.isBoosting {
                VStack {
                    Label("2× 快进中", systemImage: "forward.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.top, 14)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            if let target = swipeSeekTarget {
                Text("\(Self.format(target)) / \(Self.format(model.duration))")
                    .font(.system(size: isFullscreen ? 22 : 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.65), in: Capsule())
                    .allowsHitTesting(false)
            }
            gestureLayer
        }
        // An overlay, not a ZStack sibling: on narrow screens the controls row is wider than it wants to
        // be, and as a sibling it resized the picture every time the controls appeared.
        .overlay {
            if controlsVisible {
                // Full screen runs under the home indicator / rounded corners: keep the buttons
                // and the progress slider well inside the screen so they are easy to hit.
                controls
                    // Landscape: clear the rounded corners; portrait (vertical videos): clear the
                    // status bar / Dynamic Island and the home indicator instead.
                    .padding(.horizontal, isFullscreen ? (landscapeLayout ? 56 : 8) : 0)
                    .padding(.bottom, isFullscreen ? (landscapeLayout ? 26 : 10) : 0)
                    .padding(.top, isFullscreen ? (landscapeLayout ? 10 : 44) : 0)
                    .transition(.opacity)
            }
        }
        .clipped()
        // A sheet, not an overlay: the player frame clips anything taller than the picture, which hid
        // the position / size / colour options while typing.
        .sheet(isPresented: $showComposer, onDismiss: { scheduleHide() }) {
            danmakuComposer
                .presentationDetents([.height(250), .medium])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            showDanmaku = danmakuEnabled
            model.setDanmaku(danmaku)
            scheduleHide()
            if isFullscreen { Self.rotateReliably(landscape: rotatesInFullscreen ? true : nil) }
        }
        .onDisappear {
            hideTask?.cancel()
            if isFullscreen { Self.rotate(landscape: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            handleDeviceRotation()
        }
        .onChange(of: danmakuKey) { _ in model.setDanmaku(danmaku) }
        .onChange(of: danmakuEnabled) { showDanmaku = $0 }
        .onChange(of: model.isPlaying) { playing in
            if playing { scheduleHide() } else { revealControls() }
        }
        .statusBarHidden(isFullscreen)
    }

    /// Turning the phone sideways opens the full screen by itself; turning it back closes it.
    private func handleDeviceRotation() {
        guard UIDevice.current.userInterfaceIdiom == .phone, !audioOnly,
              UserDefaults.standard.object(forKey: "moumusic.bili.autoFullscreen") as? Bool ?? true else { return }
        let orientation = UIDevice.current.orientation
        if !isFullscreen, orientation.isLandscape, model.isReady, let onFullscreen {
            onFullscreen()
        } else if isFullscreen, rotatesInFullscreen, orientation == .portrait, let onClose {
            onClose()
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var posterView: some View {
        if let posterURL, let url = posterURL.resizedImageURL(768) {
            GeometryReader { proxy in
                CachedAsyncImage(url: url)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .opacity(audioOnly ? 1 : 0.7)
            }
            .allowsHitTesting(false)
        }
    }

    private var danmakuCanvas: some View {
        BiliDanmakuView(model: model, isFullscreen: isFullscreen, bottomInset: controlsVisible ? 70 : 12)
            .allowsHitTesting(false)
    }

    /// Tap shows/hides the controls, double-tap pauses, press-and-hold plays at 2x.
    private var gestureLayer: some View {
        GeometryReader { proxy in
            tapLayer
                .simultaneousGesture(
                    // Horizontal swipe on the picture scrubs: a full-width swipe moves up to
                    // two minutes (or the whole video when it is shorter).
                    DragGesture(minimumDistance: 14)
                        .onChanged { value in
                            guard model.duration > 0, !model.isBoosting else { return }
                            if swipeSeekTarget == nil {
                                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                swipeSeekStart = model.currentTime
                            }
                            let span = min(model.duration, 120)
                            let delta = Double(value.translation.width / max(proxy.size.width, 1)) * span
                            swipeSeekTarget = min(max(0, swipeSeekStart + delta), model.duration)
                            hideTask?.cancel()
                        }
                        .onEnded { _ in
                            if let target = swipeSeekTarget { model.seek(to: target) }
                            swipeSeekTarget = nil
                            scheduleHide()
                        }
                )
        }
    }

    private var tapLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.togglePlay()
                revealControls()
            }
            .onTapGesture {
                if controlsVisible {
                    hideTask?.cancel()
                    withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
                } else {
                    revealControls()
                }
            }
            .gesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        if case .second(true, _) = value { model.beginBoost() }
                    }
                    .onEnded { _ in model.endBoost() }
            )
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if isFullscreen {
                    Button { onClose?() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("退出全屏")
                }
                if let title, isFullscreen {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.black.opacity(isFullscreen ? scrimTop : 0), .clear], startPoint: .top, endPoint: .bottom))

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { model.currentTime },
                        set: { model.scrub(to: $0) }
                    ),
                    in: 0...max(model.duration, 1),
                    onEditingChanged: { editing in
                        model.isScrubbing = editing
                        if editing {
                            hideTask?.cancel()
                        } else {
                            model.seek(to: model.currentTime)
                            scheduleHide()
                        }
                    }
                )
                .tint(Theme.accent)
                .padding(.horizontal, 12)

                // Wide players show every button; narrow ones (vertical videos, small inline
                // players) keep the essentials and move speed / PiP / AirPlay into 更多.
                ViewThatFits(in: .horizontal) {
                    controlRow(compact: false)
                    controlRow(compact: true)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .padding(.top, 14)
            .background(LinearGradient(colors: [.clear, .black.opacity(scrimBottom)], startPoint: .top, endPoint: .bottom))
        }
    }

    @ViewBuilder
    private func controlRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 14) {
            Button { model.togglePlay(); scheduleHide() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(model.isPlaying ? "暂停" : "播放")

            Text("\(Self.format(model.currentTime)) / \(Self.format(model.duration))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 0)

            if !compact { rateMenu }
            subtitleMenu
            danmakuButton
            if onSendDanmaku != nil, showDanmaku { sendDanmakuButton }
            if !compact {
                if model.canPiP { pipButton }
                BiliRoutePicker().frame(width: 32, height: 32)
            } else {
                Menu {
                    Section("倍速") {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                            Button { model.setRate(Float(value)) } label: {
                                if Float(value) == model.rate {
                                    Label("\(Self.rateText(value))x", systemImage: "checkmark")
                                } else {
                                    Text("\(Self.rateText(value))x")
                                }
                            }
                        }
                    }
                    if model.canPiP {
                        Button { model.togglePiP() } label: { Label("画中画", systemImage: "pip.enter") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("更多")
            }
            fullscreenButton
        }
    }

    private var rateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                Button { model.setRate(Float(value)) } label: {
                    if Float(value) == model.rate {
                        Label("\(Self.rateText(value))x", systemImage: "checkmark")
                    } else {
                        Text("\(Self.rateText(value))x")
                    }
                }
            }
        } label: {
            Text("\(Self.rateText(Double(model.rate)))x")
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 32, minHeight: 32)
        }
    }

    private var subtitleMenu: some View {
        Menu {
            Button { onSelectSubtitle(nil) } label: {
                if selectedSubtitleID == nil { Label("关闭字幕", systemImage: "checkmark") } else { Text("关闭字幕") }
            }
            if subtitles.isEmpty { Text("该视频没有字幕") }
            ForEach(subtitles) { subtitle in
                Button { onSelectSubtitle(subtitle) } label: {
                    if subtitle.id == selectedSubtitleID {
                        Label(subtitle.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(subtitle.displayTitle)
                    }
                }
            }
        } label: {
            Image(systemName: selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 18))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("字幕")
    }

    private var sendDanmakuButton: some View {
        Button {
            composerText = ""
            showComposer = true
            hideTask?.cancel()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 18))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("发弹幕")
    }

    private static let draftColors: [UInt32] = [0xFFFFFF, 0xFE0302, 0xFF7204, 0xFFAA02, 0xFFFF00, 0x00CD00, 0x00FFFF, 0x4266BE, 0xCC0273]

    /// Bottom input panel like the Bilibili app: text field, send, then position / size / colour chips.
    private var danmakuComposer: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("发一条友善的弹幕", text: $composerText)
                        .focused($composerFocused)
                        .submitLabel(.send)
                        .onSubmit { submitDanmaku() }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.16), in: Capsule())
                    Button {
                        submitDanmaku()
                    } label: {
                        Text("发送")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Theme.accent.opacity(canSubmit ? 1 : 0.4), in: Capsule())
                    }
                    .disabled(!canSubmit)
                }
                HStack(spacing: 8) {
                    chip("滚动", selected: draftMode == 1) { draftMode = 1 }
                    chip("顶部", selected: draftMode == 5) { draftMode = 5 }
                    chip("底部", selected: draftMode == 4) { draftMode = 4 }
                    Spacer(minLength: 6)
                    chip("小", selected: draftSize == 18) { draftSize = 18 }
                    chip("中", selected: draftSize == 25) { draftSize = 25 }
                    chip("大", selected: draftSize == 36) { draftSize = 36 }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Self.draftColors, id: \.self) { value in
                            Circle()
                                .fill(Color(red: Double((value >> 16) & 0xFF) / 255,
                                            green: Double((value >> 8) & 0xFF) / 255,
                                            blue: Double(value & 0xFF) / 255))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(Color.white, lineWidth: draftColor == value ? 3 : 0.5))
                                .onTapGesture { draftColor = value }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.12).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear { composerFocused = true }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(selected ? .white : .white.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Theme.accent : Color.white.opacity(0.14), in: Capsule())
        }
    }

    private var canSubmit: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sendingDanmaku
    }

    private func closeComposer() {
        composerFocused = false
        showComposer = false
        scheduleHide()
    }

    private func submitDanmaku() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sendingDanmaku, let onSendDanmaku else { return }
        sendingDanmaku = true
        let draft = BiliDanmakuDraft(text: text, mode: draftMode, color: draftColor, fontSize: draftSize)
        Task { @MainActor in
            let sent = await onSendDanmaku(draft)
            sendingDanmaku = false
            if sent { composerText = ""; closeComposer() }
        }
    }

    private var danmakuButton: some View {
        Button {
            showDanmaku.toggle()
            scheduleHide()
        } label: {
            Image(systemName: showDanmaku ? "text.bubble.fill" : "text.bubble")
                .font(.system(size: 18))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel(showDanmaku ? "关闭弹幕" : "开启弹幕")
    }

    private var pipButton: some View {
        Button { model.togglePiP() } label: {
            Image(systemName: model.isPiPActive ? "pip.exit" : "pip.enter")
                .font(.system(size: 18))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("画中画")
    }

    private var fullscreenButton: some View {
        Button {
            if isFullscreen { onClose?() } else { onFullscreen?() }
        } label: {
            Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 18))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel(isFullscreen ? "退出全屏" : "全屏")
    }

    // MARK: Helpers

    private func revealControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, model.isPlaying, !model.isScrubbing else { return }
            withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
        }
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    private static func rateText(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.1f", value) : String(format: "%g", value)
    }

    /// The first rotation request is sometimes swallowed while the full-screen cover is still animating in
    /// (the window turns, the content stays portrait). Ask again until the scene really is in the wanted
    /// orientation, and nudge the presented views to lay out for the new size.
    /// `nil` follows the phone (portrait or landscape, never upside down).
    private static func rotateReliably(landscape: Bool?) {
        if let landscape { rotate(landscape: landscape) } else { rotateFollowingDevice() }
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        for delay in [0.2, 0.6, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
                if let landscape {
                    if scene.interfaceOrientation.isLandscape != landscape { rotate(landscape: landscape) }
                } else {
                    rotateFollowingDevice()
                }
                var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController
                while let current = controller {
                    current.view.setNeedsLayout()
                    current.view.layoutIfNeeded()
                    controller = current.presentedViewController
                }
            }
        }
    }

    /// Lets the scene turn with the phone (portrait or landscape, never upside down).
    private static func rotateFollowingDevice() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        if #available(iOS 16.0, *) {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .allButUpsideDown)) { _ in }
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    private static func rotate(landscape: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let mask: UIInterfaceOrientationMask = landscape ? .landscape : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}
// MARK: - Danmaku (Core Animation)

/// User preferences for danmaku, set in 哔哩哔哩设置 (modelled on PiliPlus' options).
enum BiliDanmakuSettings {
    static var opacity: Double { value("moumusic.bili.danmaku.opacity", 0.9) }
    static var fontScale: Double { value("moumusic.bili.danmaku.fontScale", 1.0) }
    /// Fraction of the picture height used by scrolling danmaku.
    static var area: Double { value("moumusic.bili.danmaku.area", 0.6) }
    /// Seconds a scrolling danmaku takes to cross the screen.
/// Fixed scroll speed in points per second: the same on every screen size and orientation
    /// (the old "seconds to cross" made landscape danmaku far faster than portrait). Slider: right = faster.
    static var speed: Double {
        // Five fixed steps (极慢…极快), points per second, identical on every screen size.
        let steps: [Double] = [40, 65, 90, 130, 180]
        let level = UserDefaults.standard.object(forKey: "moumusic.bili.danmaku.level") as? Int ?? 2
        return steps[min(max(level, 0), steps.count - 1)]
    }
    /// Upper bound of how long a scrolling danmaku stays on screen (widest picture + longest text).
    static var scrollDuration: Double { 1500 / max(speed, 20) }
    /// Words (comma / space separated) whose danmaku are hidden, like PiliPlus' 屏蔽词.
    static var blockWords: [String] {
        (UserDefaults.standard.string(forKey: "moumusic.bili.danmaku.blocklist") ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",，;； \n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    static var hideTop: Bool { UserDefaults.standard.bool(forKey: "moumusic.bili.danmaku.hideTop") }
    static var hideBottom: Bool { UserDefaults.standard.bool(forKey: "moumusic.bili.danmaku.hideBottom") }

    private static func value(_ key: String, _ fallback: Double) -> Double {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? stored : fallback
    }
}

/// Danmaku drawn as pre-rendered bitmaps in CALayers. Text is laid out once per item; each frame
/// only moves layers, so it runs at the display's full refresh rate without the per-frame text
/// layout the old Canvas did.
struct BiliDanmakuView: UIViewRepresentable {
    @ObservedObject var model: BiliPlayerModel
    let isFullscreen: Bool
    let bottomInset: CGFloat

    func makeUIView(context: Context) -> BiliDanmakuUIView {
        let view = BiliDanmakuUIView()
        view.player = model.player
        return view
    }

    func updateUIView(_ view: BiliDanmakuUIView, context: Context) {
        view.player = model.player
        view.isFullscreen = isFullscreen
        view.bottomInset = bottomInset
        view.setItems(model.placedDanmaku)
    }

    static func dismantleUIView(_ view: BiliDanmakuUIView, coordinator: ()) {
        view.stop()
    }
}

final class BiliDanmakuUIView: UIView {
    weak var player: AVPlayer?
    var isFullscreen = false
    var bottomInset: CGFloat = 12

    private var items: [PlacedDanmaku] = []
    private var itemsSignature = ""
    private var layersByIndex: [Int: CALayer] = [:]
    private let imageStore = DanmakuImageStore()
    private let renderQueue = DispatchQueue(label: "moumusic.danmaku.render", qos: .userInitiated)
    private var frameCounter = 0
    /// Playback position advanced by the display's own clock between the player's (frame-rate) updates.
    private var smoothTime: Double = 0
    private var lastHostTime: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var cachedFontSize: CGFloat = 0
    private var lastTime: Double = -1
    private var settingsTick = 0
    private var opacity: Float = 0.9
    private var fontScale: CGFloat = 1
    private var area: CGFloat = 0.6
    private var scrollDuration: Double = 8
    private var scrollSpeed: Double = 90
    private var hideTop = false
    private var hideBottom = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
        readSettings()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    func setItems(_ newItems: [PlacedDanmaku]) {
        let signature = "\(newItems.count)-\(newItems.first?.start ?? 0)-\(newItems.last?.text ?? "")"
        guard signature != itemsSignature else { return }
        itemsSignature = signature
        items = newItems
        clearAll()
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func clearAll() {
        layersByIndex.values.forEach { $0.removeFromSuperlayer() }
        layersByIndex.removeAll()
        imageStore.reset(fontSize: cachedFontSize)
        lastTime = -1
        lastHostTime = 0
    }

    private func readSettings() {
        opacity = Float(BiliDanmakuSettings.opacity)
        fontScale = CGFloat(BiliDanmakuSettings.fontScale)
        area = CGFloat(BiliDanmakuSettings.area)
        scrollDuration = BiliDanmakuSettings.scrollDuration
        scrollSpeed = BiliDanmakuSettings.speed
        hideTop = BiliDanmakuSettings.hideTop
        hideBottom = BiliDanmakuSettings.hideBottom
    }

    fileprivate func renderFrame(_ link: CADisplayLink) {
        settingsTick += 1
        if settingsTick % 60 == 0 {
            let oldScale = fontScale
            readSettings()
            if oldScale != fontScale { clearAll() }
        }
        guard let player, bounds.width > 0 else { return }
        let playerTime = player.currentTime().seconds
        guard playerTime.isFinite else { return }
        // The player reports its time once per video frame, which makes danmaku step in jumps on a 60 Hz
        // display. While playing, advance the time with the display clock and only nudge it toward the
        // player's value (a big gap means a seek: snap).
        let rate = Double(player.rate)
        var time = playerTime
        if rate > 0, lastHostTime > 0 {
            let predicted = smoothTime + (link.timestamp - lastHostTime) * rate
            let drift = playerTime - predicted
            time = abs(drift) > 0.5 ? playerTime : predicted + drift * 0.08
        }
        smoothTime = time
        lastHostTime = link.timestamp
        if rate == 0, time == lastTime { return }
        // A jump (seek) re-places everything.
        if lastTime >= 0, abs(time - lastTime) > 1.5 { layersByIndex.values.forEach { $0.removeFromSuperlayer() }; layersByIndex.removeAll() }
        lastTime = time

        let baseSize = max(13, min(isFullscreen ? 24 : 18, bounds.height / 15))
        let fontSize = baseSize * fontScale
        if fontSize != cachedFontSize { cachedFontSize = fontSize; imageStore.reset(fontSize: fontSize); clearLayersOnly() }
        frameCounter += 1
        if frameCounter % 15 == 1 { prefetchImages(from: time, fontSize: fontSize) }
        let laneHeight = fontSize * 1.5
        let scrollLanes = max(1, Int((bounds.height * area) / laneHeight))

        var visible = Set<Int>()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in activeIndices(at: time) {
            let item = items[index]
            if item.mode == 5, hideTop { continue }
            if item.mode == 4, hideBottom { continue }
            if item.mode != 4, item.mode != 5, item.lane >= scrollLanes { continue }
            visible.insert(index)
            let rendered = image(for: index, fontSize: fontSize)
            let layer: CALayer
            if let existing = layersByIndex[index] {
                layer = existing
            } else {
                layer = CALayer()
                layer.contents = rendered.image
                layer.contentsScale = UIScreen.main.scale
                layer.bounds = CGRect(origin: .zero, size: rendered.size)
                layer.anchorPoint = .zero
                self.layer.addSublayer(layer)
                layersByIndex[index] = layer
            }
            layer.opacity = opacity
            let width = rendered.size.width
            let origin: CGPoint
            switch item.mode {
            case 4:
                origin = CGPoint(x: (bounds.width - width) / 2,
                                 y: bounds.height - bottomInset - laneHeight * CGFloat(item.lane + 1))
            case 5:
                origin = CGPoint(x: (bounds.width - width) / 2, y: 8 + laneHeight * CGFloat(item.lane))
            default:
                let progress = CGFloat(time - item.start) * CGFloat(scrollSpeed)
                origin = CGPoint(x: bounds.width - progress,
                                 y: 8 + laneHeight * CGFloat(item.lane))
            }
            layer.position = origin
        }
        for (index, layer) in layersByIndex where !visible.contains(index) {
            layer.removeFromSuperlayer()
            layersByIndex[index] = nil
        }
        CATransaction.commit()
        imageStore.trim(keeping: visible)
    }

    /// Draws the text bitmaps of the danmaku that start within the next three seconds on a background queue,
    /// so a burst of new danmaku never costs the main thread a frame.
    private func prefetchImages(from time: Double, fontSize: CGFloat) {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].start < time { low = mid + 1 } else { high = mid }
        }
        let scale = UIScreen.main.scale
        let store = imageStore
        var queued = 0
        var index = low
        while index < items.count, items[index].start <= time + 3, queued < 80 {
            if store.claim(index) {
                queued += 1
                let item = items[index]
                let target = index
                renderQueue.async {
                    let entry = Self.render(item: item, fontSize: fontSize, scale: scale)
                    store.put(target, entry, fontSize: fontSize)
                }
            }
            index += 1
        }
    }

    private func clearLayersOnly() {
        layersByIndex.values.forEach { $0.removeFromSuperlayer() }
        layersByIndex.removeAll()
    }

    private func activeIndices(at time: Double) -> [Int] {
        guard !items.isEmpty else { return [] }
        let window = max(scrollDuration, 4)
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].start < time - window { low = mid + 1 } else { high = mid }
        }
        var result: [Int] = []
        var index = low
        while index < items.count, items[index].start <= time, result.count < 150 {
            let item = items[index]
            let life = (item.mode == 4 || item.mode == 5) ? 4 : scrollDuration
            if time - item.start <= life { result.append(index) }
            index += 1
        }
        return result
    }

    private static let danmakuShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.85)
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        shadow.shadowBlurRadius = 2
        return shadow
    }()

    private func image(for index: Int, fontSize: CGFloat) -> (image: CGImage, size: CGSize) {
        if let cached = imageStore.get(index) { return cached }
        let entry = Self.render(item: items[index], fontSize: fontSize, scale: UIScreen.main.scale)
        imageStore.put(index, entry, fontSize: fontSize)
        return entry
    }

    nonisolated private static func render(item: PlacedDanmaku, fontSize: CGFloat,
                                           scale: CGFloat) -> (image: CGImage, size: CGSize) {
        let color = UIColor(red: CGFloat((item.color >> 16) & 0xFF) / 255,
                            green: CGFloat((item.color >> 8) & 0xFF) / 255,
                            blue: CGFloat(item.color & 0xFF) / 255, alpha: 1)
        // Two passes like the official player: a thin dark outline first, then the coloured
        // glyphs on top, so the outline never eats into the fill.
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let outline = NSAttributedString(string: item.text, attributes: [
            .font: font,
            .foregroundColor: UIColor.clear,
            .strokeColor: UIColor.black.withAlphaComponent(0.7),
            .strokeWidth: 5
        ])
        let fill = NSAttributedString(string: item.text, attributes: [
            .font: font,
            .foregroundColor: color
        ])
        let textSize = fill.size()
        let size = CGSize(width: ceil(textSize.width) + 6, height: ceil(textSize.height) + 4)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            outline.draw(at: CGPoint(x: 3, y: 2))
            fill.draw(at: CGPoint(x: 3, y: 2))
        }
        return (rendered.cgImage!, size)
    }

    /// CADisplayLink retains its target; this weak proxy avoids a cycle.
    private final class Proxy: NSObject {
        weak var owner: BiliDanmakuUIView?
        init(_ owner: BiliDanmakuUIView) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.renderFrame(link) }
    }
}
// MARK: - HEVC tag fix

/// Bilibili's HEVC streams (4K / HDR / 杜比视界) are tagged `hev1`, which AVFoundation refuses
/// to decode; the bitstream itself is fine. This resource loader proxies the stream and renames
/// the sample-entry fourcc to `hvc1` in the file header, the same fix as ffmpeg's `-tag:v hvc1`.
final class BiliHEVCLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    private static let scheme = "mou-hevc"
    private static let queue = DispatchQueue(label: "moumusic.bili.stream-loader")
    /// Resource loaders keep only a weak delegate; keep each loader alive for its asset.
    private static var live: [ObjectIdentifier: BiliHEVCLoader] = [:]
    private static var order: [ObjectIdentifier] = []
    private static let lock = NSLock()

    private let origin: URL
    private let userAgent: String
    private let retagHEVC: Bool
    /// Data tasks in flight, keyed by task identifier; only touched on `queue`.
    private var requests: [Int: (loading: AVAssetResourceLoadingRequest, offset: Int64)] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 3600
        configuration.httpMaximumConnectionsPerHost = 6
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = Self.queue
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private init(origin: URL, userAgent: String, retag: Bool) {
        self.origin = origin
        self.userAgent = userAgent
        self.retagHEVC = retag
    }

    static func asset(for url: URL, userAgent: String, retag: Bool = true) -> AVURLAsset {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        let origin = parts?.url ?? url
        parts?.scheme = scheme
        let proxied = parts?.url ?? url
        let asset = AVURLAsset(url: proxied)
        let loader = BiliHEVCLoader(origin: origin, userAgent: userAgent, retag: retag)
        asset.resourceLoader.setDelegate(loader, queue: queue)
        lock.lock()
        let key = ObjectIdentifier(asset)
        live[key] = loader
        order.append(key)
        while order.count > 16 { live[order.removeFirst()] = nil }
        lock.unlock()
        return asset
    }

    // MARK: AVAssetResourceLoaderDelegate (on `queue`)

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        var start: Int64 = 0
        var end: Int64?
        if let dataRequest = loadingRequest.dataRequest {
            start = dataRequest.requestedOffset
            if dataRequest.requestsAllDataToEndOfResource {
                // Open-ended reads would hog the connection for the whole file and starve the
                // segment AVPlayer actually needs next; serve windows and let it ask again.
                end = start + 6 * 1024 * 1024 - 1
            } else {
                end = start + Int64(dataRequest.requestedLength) - 1
            }
        } else {
            end = 1
        }
        var request = URLRequest(url: origin)
        request.setValue("bytes=\(start)-\(end.map(String.init) ?? "")", forHTTPHeaderField: "Range")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        requests[task.taskIdentifier] = (loadingRequest, start)
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let ids = requests.filter { $0.value.loading === loadingRequest }.map(\.key)
        for id in ids { requests[id] = nil }
        session.getAllTasks { tasks in
            for task in tasks where ids.contains(task.taskIdentifier) { task.cancel() }
        }
    }

    // MARK: URLSessionDataDelegate (on `queue`)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let entry = requests[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            requests[dataTask.taskIdentifier] = nil
            entry.loading.finishLoading(with: NSError(domain: "BiliStream", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "视频节点返回 HTTP \(http.statusCode)"]))
            completionHandler(.cancel)
            return
        }
        if let info = entry.loading.contentInformationRequest, let http = response as? HTTPURLResponse {
            // .m4s / octet-stream nodes: declare MPEG-4 so AVFoundation opens the stream.
            info.contentType = "public.mpeg-4"
            info.isByteRangeAccessSupported = true
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                info.contentLength = total
            } else {
                info.contentLength = http.expectedContentLength
            }
        }
        if entry.loading.dataRequest == nil {
            requests[dataTask.taskIdentifier] = nil
            entry.loading.finishLoading()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let entry = requests[dataTask.taskIdentifier], let dataRequest = entry.loading.dataRequest else { return }
        var chunk = data
        // Only the file header (first 16 KB) can hold the HEVC sample entry.
        if retagHEVC, entry.offset < 16 * 1024 { Self.retag(&chunk) }
        dataRequest.respond(with: chunk)
        requests[dataTask.taskIdentifier] = (entry.loading, entry.offset + Int64(data.count))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = requests.removeValue(forKey: task.taskIdentifier) else { return }
        if let error {
            if (error as NSError).code != NSURLErrorCancelled { entry.loading.finishLoading(with: error) }
        } else {
            entry.loading.finishLoading()
        }
    }

    private static func retag(_ data: inout Data) {
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

/// One danmaku as typed in the composer.
struct BiliDanmakuDraft {
    let text: String
    /// 1 scrolling, 4 bottom, 5 top (the Bilibili modes).
    let mode: Int
    let color: UInt32
    let fontSize: Int
}

/// Thread-safe store of the pre-rendered danmaku bitmaps (filled from a background queue).
private final class DanmakuImageStore: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [Int: (image: CGImage, size: CGSize)] = [:]
    private var pending = Set<Int>()
    private var fontSize: CGFloat = 0

    func reset(fontSize: CGFloat) {
        lock.lock()
        images.removeAll()
        pending.removeAll()
        self.fontSize = fontSize
        lock.unlock()
    }

    func get(_ index: Int) -> (image: CGImage, size: CGSize)? {
        lock.lock(); defer { lock.unlock() }
        return images[index]
    }

    /// True when the caller should render this item (it is neither cached nor already being rendered).
    func claim(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if images[index] != nil || pending.contains(index) { return false }
        pending.insert(index)
        return true
    }

    func put(_ index: Int, _ entry: (image: CGImage, size: CGSize), fontSize: CGFloat) {
        lock.lock()
        if fontSize == self.fontSize { images[index] = entry }
        pending.remove(index)
        lock.unlock()
    }

    func trim(keeping visible: Set<Int>) {
        lock.lock()
        if images.count > 600 { images = images.filter { visible.contains($0.key) } }
        lock.unlock()
    }
}
