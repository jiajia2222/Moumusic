import SwiftUI

#if os(iOS)
import AVFoundation
import ShazamKit
#endif

enum MusicRecognitionState: Equatable {
    case idle
    case requestingPermission
    case listening
    case matching
    case matched
    case noMatch
    case failed(String)
}

/// Captures a short microphone sample with the system recognition catalog and
/// then resolves the title through QQ Music's catalogue adapter. Audio is not
/// uploaded by the app and playback remains owned by the selected LX source.
final class MusicRecognitionService: NSObject, ObservableObject {
    @Published private(set) var state: MusicRecognitionState = .idle
    @Published private(set) var recognizedTrack: Track?

#if os(iOS)
    private let audioEngine = AVAudioEngine()
    private let mixerNode = AVAudioMixerNode()
    private var recognitionSession: SHSession?
    private var isAudioConfigured = false
    private var finishTask: Task<Void, Never>?
#endif

    func start() {
#if os(iOS)
        Task { @MainActor [weak self] in
            await self?.beginListening()
        }
#else
        state = .failed("听歌识曲仅支持 iPhone、iPad 和 Mac Catalyst")
#endif
    }

    func cancel() {
#if os(iOS)
        Task { @MainActor [weak self] in
            self?.stopCapture()
            self?.recognizedTrack = nil
            self?.state = .idle
        }
#else
        state = .idle
#endif
    }

#if os(iOS)
    @MainActor
    private func beginListening() async {
        guard state != .listening, state != .matching,
              state != .requestingPermission else { return }

        recognizedTrack = nil
        state = .requestingPermission
        let granted = await requestMicrophonePermission()
        guard granted else {
            state = .failed("请在“设置 > 隐私与安全性 > 麦克风”中允许 Moumusic 使用麦克风")
            return
        }

        do {
            try configureAudioSession()
            try configureAudioEngine()

            let session = SHSession()
            session.delegate = self
            recognitionSession = session
            try audioEngine.start()
            state = .listening

            finishTask?.cancel()
            finishTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.finishWithoutMatch()
            }
        } catch {
            stopCapture()
            state = .failed("麦克风暂时不可用，请稍后重试")
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioEngine() throws {
        guard !isAudioConfigured else { return }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        else {
            throw RecognitionError.microphoneUnavailable
        }

        audioEngine.attach(mixerNode)
        audioEngine.connect(inputNode, to: mixerNode, format: inputFormat)
        audioEngine.connect(mixerNode, to: audioEngine.outputNode, format: outputFormat)
        mixerNode.installTap(onBus: 0, bufferSize: 8_192, format: outputFormat) { [weak self] buffer, time in
            self?.recognitionSession?.matchStreamingBuffer(buffer, at: time)
        }
        isAudioConfigured = true
    }

    @MainActor
    private func finishWithoutMatch() {
        guard state == .listening else { return }
        stopCapture()
        state = .noMatch
    }

    @MainActor
    private func stopCapture() {
        finishTask?.cancel()
        finishTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        recognitionSession = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @MainActor
    private func handleMatch(_ match: SHMatch) {
        guard state == .listening,
              let item = match.mediaItems.first,
              let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }

        let artist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        stopCapture()
        state = .matching

        Task { [weak self] in
            let query = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
            let candidates = (try? await LXCatalogService.search(query, platform: .tx,
                                                                   page: 1, limit: 12)) ?? []
            let selected = Self.bestQQMatch(candidates, title: title, artist: artist)
            await MainActor.run {
                guard let self else { return }
                if let selected {
                    self.recognizedTrack = selected
                    self.state = .matched
                } else {
                    self.state = .noMatch
                }
            }
        }
    }

    private static func bestQQMatch(_ tracks: [Track], title: String, artist: String) -> Track? {
        guard !tracks.isEmpty else { return nil }
        let normalizedTitle = normalize(title)
        let normalizedArtist = normalize(artist)

        return tracks.max { lhs, rhs in
            score(lhs, title: normalizedTitle, artist: normalizedArtist)
                < score(rhs, title: normalizedTitle, artist: normalizedArtist)
        }
    }

    private static func score(_ track: Track, title: String, artist: String) -> Int {
        let trackTitle = normalize(track.name)
        let trackArtist = normalize(track.artistNames)
        var value = 0
        if trackTitle == title { value += 100 }
        else if trackTitle.contains(title) || title.contains(trackTitle) { value += 45 }
        if !artist.isEmpty {
            if trackArtist == artist { value += 80 }
            else if trackArtist.contains(artist) || artist.contains(trackArtist) { value += 35 }
        }
        return value
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "·", with: "")
    }
#endif

    private enum RecognitionError: Error {
        case microphoneUnavailable
    }
}

#if os(iOS)
extension MusicRecognitionService: SHSessionDelegate {
    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        Task { @MainActor [weak self] in
            self?.handleMatch(match)
        }
    }

    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature,
                             error: Error?) {
        // Streaming sessions can report several intermediate no-match results
        // before a later buffer matches. The bounded timer owns the final empty
        // state; only a real match or the timeout changes the UI.
    }
}
#endif

struct MusicRecognitionView: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = MusicRecognitionService()

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)

            Image(systemName: iconName)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 92, height: 92)
                .background(Theme.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if let track = service.recognizedTrack,
               service.state == .matched {
                resultCard(track)
            }

            actionButton
            Spacer()
        }
        .padding(.horizontal, 24)
        .navigationTitle("听歌识曲")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .onDisappear { service.cancel() }
    }

    private var iconName: String {
        switch service.state {
        case .listening: return "waveform"
        case .matching: return "sparkles"
        case .matched: return "checkmark"
        case .failed, .noMatch: return "exclamationmark"
        default: return "waveform.badge.mic"
        }
    }

    private var title: String {
        switch service.state {
        case .requestingPermission: return "需要麦克风权限"
        case .listening: return "正在聆听"
        case .matching: return "正在匹配 QQ 音乐"
        case .matched: return "找到歌曲了"
        case .noMatch: return "没有找到匹配"
        case .failed: return "识别暂时不可用"
        case .idle: return "听歌识曲"
        }
    }

    private var message: String {
        switch service.state {
        case .requestingPermission: return "允许后，Moumusic 会聆听约 8 秒并匹配 QQ 音乐歌曲。"
        case .listening: return "请把手机靠近正在播放的音乐。"
        case .matching: return "正在用歌曲名称和歌手匹配 QQ 音乐目录。"
        case .matched: return "结果来自 QQ 音乐目录，播放会使用当前 LX 音源。"
        case .noMatch: return "请靠近音源后再试，或换一段更清晰的副歌。"
        case .failed(let text): return text
        case .idle: return "识别身边正在播放的歌曲。"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch service.state {
        case .listening:
            Button("停止识别") { service.cancel() }
                .buttonStyle(.bordered)
                .frame(minWidth: 160, minHeight: 44)
        case .matching, .requestingPermission:
            ProgressView()
                .controlSize(.regular)
                .frame(minWidth: 160, minHeight: 44)
        case .matched:
            Button {
                if let track = service.recognizedTrack {
                    player.playTrack(track)
                    dismiss()
                }
            } label: {
                Label("播放这首歌", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .frame(minWidth: 160, minHeight: 44)
        default:
            Button(service.state == .idle ? "开始识别" : "再试一次") {
                service.start()
            }
            .buttonStyle(.borderedProminent)
            .frame(minWidth: 160, minHeight: 44)
        }
    }

    private func resultCard(_ track: Track) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(256))
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(track.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(track.artistNames)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("QQ 音乐")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("识别结果：\(track.name)，\(track.artistNames)，QQ 音乐")
    }
}
