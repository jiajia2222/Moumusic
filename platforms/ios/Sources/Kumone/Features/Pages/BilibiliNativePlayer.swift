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
    @Published private(set) var canPiP = false
    @Published private(set) var placedDanmaku: [PlacedDanmaku] = []
    @Published var isScrubbing = false

    let player = AVPlayer()
    var onError: ((String) -> Void)?
    /// Catalogue length of the video; keeps the seek bar usable while the stream reports no duration.
    var fallbackDuration: Double = 0
    /// Per-video key for 续播 (resume where you left off); nil disables it.
    var resumeKey: String?
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
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in self?.tick(time) }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in self?.apply(status) }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    // MARK: Loading

    func load(video: URL?, audio: URL?, autoplay: Bool) {
        let key = "\(video?.absoluteString ?? "")|\(audio?.absoluteString ?? "")"
        guard key != loadedKey else { return }
        loadedKey = key
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
            let item = await Self.makeItem(video: video, audio: audio)
            guard let self, !Task.isCancelled else { return }
            self.install(item, autoplay: autoplay)
        }
    }

    nonisolated private static func makeItem(video: URL, audio: URL?) async -> AVPlayerItem {
        let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": [
            "Referer": "https://www.bilibili.com/",
            "User-Agent": userAgent
        ]]
        let videoAsset = video.fragment == "mou-hev1"
            ? BiliHEVCLoader.asset(for: video, userAgent: userAgent)
            : AVURLAsset(url: video, options: options)
        guard let audio else { return AVPlayerItem(asset: videoAsset) }
        let audioAsset = AVURLAsset(url: audio, options: options)
        do {
            let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
            let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            let videoDuration = try await videoAsset.load(.duration)
            let audioDuration = try await audioAsset.load(.duration)
            guard let sourceVideo = videoTracks.first, let sourceAudio = audioTracks.first else {
                return AVPlayerItem(asset: videoAsset)
            }
            let length = (audioDuration.isNumeric && audioDuration > .zero)
                ? CMTimeMinimum(videoDuration, audioDuration) : videoDuration
            let composition = AVMutableComposition()
            if let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: sourceVideo, at: .zero)
                videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
            }
            if let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: sourceAudio, at: .zero)
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
                case .failed:
                    self.isPreparing = false
                    self.onError?("B 站视频播放失败：\(message ?? "未知错误")")
                default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        guard autoplay else { return }
        play()
    }

    // MARK: Transport

    private func apply(_ status: AVPlayer.TimeControlStatus) {
        isPlaying = status != .paused
        isBuffering = status == .waitingToPlayAtSpecifiedRate
    }

    private func tick(_ time: CMTime) {
        if !isScrubbing, time.isNumeric { currentTime = max(0, time.seconds) }
        if let item = player.currentItem, item.duration.isNumeric {
            let value = item.duration.seconds
            if value.isFinite, value > 0, abs(value - duration) > 0.5 { duration = value }
        } else if duration <= 0, fallbackDuration > 0 {
            duration = fallbackDuration
        }
        saveResumeIfNeeded()
        if isPlaying, abs(currentTime - lastReported) >= 15 {
            lastReported = currentTime
            onProgressReport?(Int(currentTime))
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
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
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
            canPiP = false
            return
        }
        if pipController?.playerLayer === layer { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
        canPiP = controller != nil
    }

    func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.isPiPActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.isPiPActive = false }
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
        for cue in sorted {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
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
    var onFullscreen: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showDanmaku = true
    /// Target time while the user drags horizontally on the picture to seek.
    @State private var swipeSeekTarget: Double?
    @State private var swipeSeekStart: Double = 0

    private var danmakuKey: String { "\(danmaku.count)-\(danmaku.first?.id ?? "")" }

    private var currentSubtitle: String? {
        guard selectedSubtitleID != nil else { return nil }
        let now = model.currentTime
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
            if model.isPreparing || model.isBuffering {
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
            if controlsVisible {
                // Full screen runs under the home indicator / rounded corners: keep the buttons
                // and the progress slider well inside the screen so they are easy to hit.
                controls
                    .padding(.horizontal, isFullscreen ? 56 : 0)
                    .padding(.bottom, isFullscreen ? 26 : 0)
                    .padding(.top, isFullscreen ? 10 : 0)
                    .transition(.opacity)
            }
        }
        .clipped()
        .onAppear {
            showDanmaku = danmakuEnabled
            model.setDanmaku(danmaku)
            scheduleHide()
            if isFullscreen { Self.rotate(landscape: rotatesInFullscreen) }
        }
        .onDisappear {
            hideTask?.cancel()
            if isFullscreen { Self.rotate(landscape: false) }
        }
        .onChange(of: danmakuKey) { _ in model.setDanmaku(danmaku) }
        .onChange(of: danmakuEnabled) { showDanmaku = $0 }
        .onChange(of: model.isPlaying) { playing in
            if playing { scheduleHide() } else { revealControls() }
        }
        .statusBarHidden(isFullscreen)
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
            .background(LinearGradient(colors: [.black.opacity(isFullscreen ? 0.6 : 0), .clear], startPoint: .top, endPoint: .bottom))

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

                HStack(spacing: 14) {
                    Button { model.togglePlay(); scheduleHide() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(model.isPlaying ? "暂停" : "播放")

                    Text("\(Self.format(model.currentTime)) / \(Self.format(model.duration))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))

                    Spacer(minLength: 0)

                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                            Button {
                                model.setRate(Float(value))
                            } label: {
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

                    Menu {
                        Button { onSelectSubtitle(nil) } label: {
                            if selectedSubtitleID == nil {
                                Label("关闭字幕", systemImage: "checkmark")
                            } else {
                                Text("关闭字幕")
                            }
                        }
                        if subtitles.isEmpty {
                            Text("该视频没有字幕")
                        }
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

                    Button {
                        showDanmaku.toggle()
                        scheduleHide()
                    } label: {
                        Image(systemName: showDanmaku ? "text.bubble.fill" : "text.bubble")
                            .font(.system(size: 18))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(showDanmaku ? "关闭弹幕" : "开启弹幕")

                    if model.canPiP {
                        Button { model.togglePiP() } label: {
                            Image(systemName: model.isPiPActive ? "pip.exit" : "pip.enter")
                                .font(.system(size: 18))
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("画中画")
                    }

                    BiliRoutePicker()
                        .frame(width: 32, height: 32)

                    Button {
                        if isFullscreen { onClose?() } else { onFullscreen?() }
                    } label: {
                        Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 18))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(isFullscreen ? "退出全屏" : "全屏")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .padding(.top, 14)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
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
    static var scrollDuration: Double { value("moumusic.bili.danmaku.duration", 8) }
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
    private var imageCache: [Int: (image: CGImage, size: CGSize)] = [:]
    private var displayLink: CADisplayLink?
    private var cachedFontSize: CGFloat = 0
    private var lastTime: Double = -1
    private var settingsTick = 0
    private var opacity: Float = 0.9
    private var fontScale: CGFloat = 1
    private var area: CGFloat = 0.6
    private var scrollDuration: Double = 8
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
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
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
        imageCache.removeAll()
        lastTime = -1
    }

    private func readSettings() {
        opacity = Float(BiliDanmakuSettings.opacity)
        fontScale = CGFloat(BiliDanmakuSettings.fontScale)
        area = CGFloat(BiliDanmakuSettings.area)
        scrollDuration = BiliDanmakuSettings.scrollDuration
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
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        if time == lastTime { return }
        // A jump (seek) re-places everything.
        if lastTime >= 0, abs(time - lastTime) > 1.5 { layersByIndex.values.forEach { $0.removeFromSuperlayer() }; layersByIndex.removeAll() }
        lastTime = time

        let baseSize = max(13, min(isFullscreen ? 24 : 18, bounds.height / 15))
        let fontSize = baseSize * fontScale
        if fontSize != cachedFontSize { cachedFontSize = fontSize; imageCache.removeAll(); clearLayersOnly() }
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
                let progress = CGFloat((time - item.start) / scrollDuration)
                origin = CGPoint(x: bounds.width - progress * (bounds.width + width),
                                 y: 8 + laneHeight * CGFloat(item.lane))
            }
            layer.position = origin
        }
        for (index, layer) in layersByIndex where !visible.contains(index) {
            layer.removeFromSuperlayer()
            layersByIndex[index] = nil
        }
        CATransaction.commit()
        if imageCache.count > 600 { imageCache = imageCache.filter { visible.contains($0.key) } }
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

    private func image(for index: Int, fontSize: CGFloat) -> (image: CGImage, size: CGSize) {
        if let cached = imageCache[index] { return cached }
        let item = items[index]
        let color = UIColor(red: CGFloat((item.color >> 16) & 0xFF) / 255,
                            green: CGFloat((item.color >> 8) & 0xFF) / 255,
                            blue: CGFloat(item.color & 0xFF) / 255, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
            .strokeColor: UIColor.black.withAlphaComponent(0.8),
            .strokeWidth: -2.5
        ]
        let text = NSAttributedString(string: item.text, attributes: attributes)
        let textSize = text.size()
        let size = CGSize(width: ceil(textSize.width) + 4, height: ceil(textSize.height) + 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            text.draw(at: CGPoint(x: 2, y: 1))
        }
        let entry = (rendered.cgImage!, size)
        imageCache[index] = entry
        return entry
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
final class BiliHEVCLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let scheme = "mou-hevc"
    private static let queue = DispatchQueue(label: "moumusic.bili.hevc-loader")
    /// Resource loaders keep only a weak delegate; keep each loader alive for its asset.
    private static var live: [ObjectIdentifier: BiliHEVCLoader] = [:]
    private static let lock = NSLock()

    private let origin: URL
    private let userAgent: String
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 3600
        return URLSession(configuration: configuration)
    }()

    private init(origin: URL, userAgent: String) {
        self.origin = origin
        self.userAgent = userAgent
    }

    static func asset(for url: URL, userAgent: String) -> AVURLAsset {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        let origin = parts?.url ?? url
        parts?.scheme = scheme
        let proxied = parts?.url ?? url
        let asset = AVURLAsset(url: proxied)
        let loader = BiliHEVCLoader(origin: origin, userAgent: userAgent)
        asset.resourceLoader.setDelegate(loader, queue: queue)
        lock.lock(); live[ObjectIdentifier(asset)] = loader; lock.unlock()
        if live.count > 8 {
            lock.lock(); live = live.filter { _ in true }.suffix(8).reduce(into: [:]) { $0[$1.key] = $1.value }; lock.unlock()
        }
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.serve(loadingRequest)
        }
        tasks[key] = task
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    private func serve(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        let start: Int64
        var end: Int64?
        if let dataRequest = loadingRequest.dataRequest {
            start = dataRequest.requestedOffset
            if !dataRequest.requestsAllDataToEndOfResource {
                end = start + Int64(dataRequest.requestedLength) - 1
            }
        } else {
            start = 0
            end = 1
        }
        var request = URLRequest(url: origin)
        request.setValue("bytes=\(start)-\(end.map(String.init) ?? "")", forHTTPHeaderField: "Range")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let info = loadingRequest.contentInformationRequest, let http = response as? HTTPURLResponse {
                info.contentType = "public.mpeg-4"
                info.isByteRangeAccessSupported = true
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                    info.contentLength = total
                } else {
                    info.contentLength = http.expectedContentLength
                }
            }
            guard let dataRequest = loadingRequest.dataRequest else {
                loadingRequest.finishLoading()
                return
            }
            // Only the header (first 16 KB of the file) can hold the sample entry.
            let patchLimit: Int64 = 16 * 1024
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            var offset = start
            var patched = start >= patchLimit
            for try await byte in bytes {
                if Task.isCancelled { return }
                buffer.append(byte)
                let flushSize = patched ? 64 * 1024 : Int(max(0, patchLimit - start)) + 8
                if buffer.count >= flushSize {
                    if !patched { Self.retag(&buffer); patched = true }
                    dataRequest.respond(with: buffer)
                    offset += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                if !patched { Self.retag(&buffer) }
                dataRequest.respond(with: buffer)
            }
            loadingRequest.finishLoading()
        } catch {
            if !Task.isCancelled { loadingRequest.finishLoading(with: error) }
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