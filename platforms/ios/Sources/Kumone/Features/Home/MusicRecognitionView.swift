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
    case identified(title: String, artist: String)
    case noMatch
    case failed(String)
}

/// Captures a short microphone sample with the system recognition catalog and
/// then resolves the title through the enabled catalogue adapters. Audio is
/// not uploaded by the app and playback remains owned by the selected LX source.
final class MusicRecognitionService: NSObject, ObservableObject {
    @Published private(set) var state: MusicRecognitionState = .idle
    @Published private(set) var recognizedTrack: Track?

#if os(iOS)
    private let audioEngine = AVAudioEngine()
    private var recognitionSession: SHSession?
    private var hasInputTap = false
    private var finishTask: Task<Void, Never>?
    private var recognitionGeneration = 0
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
            self?.recognitionGeneration += 1
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

        recognitionGeneration += 1
        let generation = recognitionGeneration
        recognizedTrack = nil
        state = .requestingPermission
        let granted = await requestMicrophonePermission()
        guard generation == recognitionGeneration else { return }
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
                guard let self, self.recognitionGeneration == generation else { return }
                self.finishWithoutMatch()
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
        try audioSession.setCategory(.playAndRecord, mode: .measurement,
                                     options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        if hasInputTap {
            inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecognitionError.microphoneUnavailable
        }

        // ShazamKit accepts the microphone's native PCM format. Tapping the
        // input directly avoids a mixer/output graph that can fail on some
        // Bluetooth and iOS 27 routes, while also preserving the real sample
        // timestamps needed by streaming recognition.
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, time in
            self?.recognitionSession?.matchStreamingBuffer(buffer, at: time)
        }
        audioEngine.prepare()
        hasInputTap = true
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
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
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
        let generation = recognitionGeneration
        stopCapture()
        state = .matching

        Task { [weak self] in
            let selected = await Self.resolveTrack(title: title, artist: artist)
            await MainActor.run {
                guard let self else { return }
                guard self.recognitionGeneration == generation, self.state == .matching else { return }
                if let selected {
                    self.recognizedTrack = selected
                    self.state = .matched
                } else {
                    // Shazam has already identified the song. Keep that fact
                    // visible instead of collapsing a catalogue miss into a
                    // misleading microphone-recognition failure.
                    self.state = .identified(title: title, artist: artist)
                }
            }
        }
    }

    private static func resolveTrack(title: String, artist: String) async -> Track? {
        let queries = [
            [title, artist].filter { !$0.isEmpty }.joined(separator: " "),
            title,
        ].filter { !$0.isEmpty }

        for query in queries {
            let candidates = (try? await LXCatalogService.search(query, platform: .aggregate,
                                                                   page: 1, limit: 20)) ?? []
            if let match = bestMatch(candidates, title: title, artist: artist) {
                return match
            }
        }
        return nil
    }

    private static func bestMatch(_ tracks: [Track], title: String, artist: String) -> Track? {
        guard !tracks.isEmpty else { return nil }
        let normalizedTitle = normalize(title)
        let normalizedArtist = normalize(artist)

        guard let best = tracks.max(by: { lhs, rhs in
            score(lhs, title: normalizedTitle, artist: normalizedArtist)
                < score(rhs, title: normalizedTitle, artist: normalizedArtist)
        }), score(best, title: normalizedTitle, artist: normalizedArtist) > 0 else {
            return nil
        }
        return best
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
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
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
        case .matching: return "正在匹配可播放版本"
        case .matched: return "找到歌曲了"
        case .identified: return "已识别到歌曲"
        case .noMatch: return "没有找到匹配"
        case .failed: return "识别暂时不可用"
        case .idle: return "听歌识曲"
        }
    }

    private var message: String {
        switch service.state {
        case .requestingPermission: return "允许后，Moumusic 会聆听约 8 秒并匹配可播放版本。"
        case .listening: return "请把手机靠近正在播放的音乐。"
        case .matching: return "正在用歌曲名称和歌手匹配已启用的平台。"
        case .matched: return "已找到可播放版本，播放会使用当前 LX 音源。"
        case let .identified(title, artist):
            let detail = artist.isEmpty ? "《\(title)》" : "《\(title)》—\(artist)"
            return "已识别到\(detail)，但当前可用音源暂时没有可播放版本。"
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
                Text(sourceName(for: track))
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("识别结果：\(track.name)，\(track.artistNames)，\(sourceName(for: track))")
    }

    private func sourceName(for track: Track) -> String {
        let rawSource = track.source ?? track.sourceMetadata["source"] ?? ""
        return LXCatalogPlatform(rawValue: rawSource)?.displayName ?? rawSource
    }
}
