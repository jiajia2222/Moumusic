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
        let videoAsset = AVURLAsset(url: video, options: options)
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
            default: lane = Self.pickLane(&scrollFree, at: cue.start, hold: 2.4)
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
        let from = time - 8
        while low < high {
            let mid = (low + high) / 2
            if list[mid].start < from { low = mid + 1 } else { high = mid }
        }
        var result: [PlacedDanmaku] = []
        var index = low
        while index < list.count, list[index].start <= time, result.count < 90 {
            let item = list[index]
            let life: Double = (item.mode == 4 || item.mode == 5) ? 4 : 8
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
        let placed = model.placedDanmaku
        let player = model.player
        let fullscreen = isFullscreen
        let controlsShown = controlsVisible
        return TimelineView(.animation(paused: !model.isPlaying)) { _ in
            Canvas { context, size in
                let time = player.currentTime().seconds
                guard time.isFinite else { return }
                let fontSize = max(13, min(fullscreen ? 24 : 18, size.height / 15))
                let laneHeight = fontSize * 1.5
                let scrollLanes = max(1, Int((size.height * 0.62) / laneHeight))
                for item in BiliPlayerModel.active(in: placed, at: time) {
                    let red = Double((item.color >> 16) & 0xFF) / 255
                    let green = Double((item.color >> 8) & 0xFF) / 255
                    let blue = Double(item.color & 0xFF) / 255
                    let font = Font.system(size: fontSize, weight: .semibold)
                    let shadow = context.resolve(Text(item.text).font(font).foregroundColor(.black.opacity(0.75)))
                    let main = context.resolve(Text(item.text).font(font).foregroundColor(Color(red: red, green: green, blue: blue)))
                    let width = main.measure(in: CGSize(width: 2000, height: 200)).width
                    var x: CGFloat
                    var y: CGFloat
                    switch item.mode {
                    case 4:
                        x = (size.width - width) / 2
                        y = size.height - (controlsShown ? 70 : 12) - laneHeight * CGFloat(item.lane + 1)
                    case 5:
                        x = (size.width - width) / 2
                        y = 8 + laneHeight * CGFloat(item.lane)
                    default:
                        let progress = CGFloat((time - item.start) / 8.0)
                        x = size.width - progress * (size.width + width)
                        y = 8 + laneHeight * CGFloat(item.lane % scrollLanes)
                    }
                    context.draw(shadow, at: CGPoint(x: x + 1, y: y + 1), anchor: .topLeading)
                    context.draw(main, at: CGPoint(x: x, y: y), anchor: .topLeading)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Tap shows/hides the controls, double-tap pauses, press-and-hold plays at 2x.
    private var gestureLayer: some View {
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
#endif
