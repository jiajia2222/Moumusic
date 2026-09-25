#if os(iOS)
import Foundation
import SwiftUI

private enum BilibiliDownloadMode: String, CaseIterable, Identifiable {
    case video
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "视频"
        case .audio: return "音频"
        }
    }
}

struct BilibiliDownloadSheet: View {
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloads = BilibiliDownloadManager.shared

    let video: BilibiliAPI.Video
    @State private var mode: BilibiliDownloadMode = .video
    @State private var videoQualities: [BilibiliAPI.VideoQuality]
    @State private var audioQualities: [BilibiliAPI.BilibiliAudioQuality] = []
    @State private var selectedVideoQuality: Int?
    @State private var selectedAudioQuality: Int?
    @State private var isLoadingOptions = false
    @State private var isStarting = false
    @State private var message: String?

    init(video: BilibiliAPI.Video, videoQualities: [BilibiliAPI.VideoQuality]) {
        self.video = video
        _videoQualities = State(initialValue: videoQualities)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("下载内容") {
                    Text(video.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(video.author) · \(video.bvid)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("下载类型") {
                    Picker("下载类型", selection: $mode) {
                        ForEach(BilibiliDownloadMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: 44)
                }

                if mode == .video {
                    videoQualitySection
                } else {
                    audioQualitySection
                }

                Section {
                    Button {
                        Task { await startDownload() }
                    } label: {
                        HStack {
                            Spacer()
                            if isStarting {
                                ProgressView().tint(.white)
                            } else {
                                Label("开始下载", systemImage: "arrow.down.circle.fill")
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isStarting || isLoadingOptions || (mode == .video
                        ? selectedVideoQuality == nil
                        : selectedAudioQuality == nil))

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                activeDownloadsSection
                completedDownloadsSection
            }
            .navigationTitle("B站下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            await loadVideoQualitiesIfNeeded()
        }
        .onChange(of: mode) { value in
            guard value == .audio, audioQualities.isEmpty else { return }
            Task { await loadAudioQualities() }
        }
        .presentationDetents([.medium, .large])
    }

    private var videoQualitySection: some View {
        Section("视频规格") {
            if videoQualities.isEmpty && isLoadingOptions {
                ProgressView("读取可用视频规格")
            } else if videoQualities.isEmpty {
                Text("暂时没有读取到视频规格，请稍后重试")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(videoQualities) { quality in
                    qualityButton(title: quality.title,
                                  subtitle: "B站返回的可用画质",
                                  isSelected: selectedVideoQuality == quality.code) {
                        selectedVideoQuality = quality.code
                    }
                }
            }
            Text("只显示本条视频实际可用的画质；如果账号权限不足，下载时会以接口返回的实际画质为准。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var audioQualitySection: some View {
        Section("音频音质") {
            if isLoadingOptions && audioQualities.isEmpty {
                ProgressView("读取可用音质")
            } else if audioQualities.isEmpty {
                Text("这条视频没有返回可用的 DASH 音频")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(audioQualities) { quality in
                    qualityButton(title: quality.title,
                                  subtitle: "B站实际返回的音频流",
                                  isSelected: selectedAudioQuality == quality.code) {
                        selectedAudioQuality = quality.code
                    }
                }
            }
            Text("音频按 B 站接口返回的 DASH 音频流保存，文件扩展名可能是 .m4s。不会把低码率音频标成无损。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func qualityButton(title: String, subtitle: String,
                               isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var activeDownloadsSection: some View {
        if !downloads.activeDownloads.isEmpty {
            Section("正在下载") {
                ForEach(Array(downloads.activeDownloads.values).sorted { $0.id < $1.id }) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.kind == .video ? "video" : "waveform")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).lineLimit(1)
                            Text("\(item.kind.displayName) · \(item.quality)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let fraction = item.fraction {
                                ProgressView(value: fraction)
                            } else {
                                ProgressView()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let fraction = item.fraction {
                            Text("\(Int(fraction * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            downloads.cancel(item)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("取消下载")
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder private var completedDownloadsSection: some View {
        if !downloads.records.isEmpty {
            Section("已下载") {
                ForEach(downloads.records.prefix(8)) { record in
                    HStack(spacing: 12) {
                        Image(systemName: record.kind == .video ? "video.fill" : "waveform")
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title).lineLimit(1)
                            Text("\(record.kind.displayName) · \(record.quality)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(record.createdAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ShareLink(item: record.fileURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(!FileManager.default.fileExists(atPath: record.fileURL.path))
                        .accessibilityLabel("分享下载文件")
                    }
                    .frame(minHeight: 44)
                }
                .onDelete { offsets in
                    let visible = Array(downloads.records.prefix(8))
                    for index in offsets where index < visible.count {
                        downloads.delete(visible[index])
                    }
                }
            }
        }
    }

    @MainActor private func loadVideoQualitiesIfNeeded() async {
        if !videoQualities.isEmpty {
            selectedVideoQuality = videoQualities.first?.code
            return
        }
        isLoadingOptions = true
        defer { isLoadingOptions = false }
        do {
            let playback = try await BilibiliAPI.shared.playback(for: video, cookie: bilibili.cookie)
            videoQualities = playback.qualities
            selectedVideoQuality = playback.quality
        } catch {
            message = "读取视频规格失败：\(error.localizedDescription)"
        }
    }

    @MainActor private func loadAudioQualities() async {
        guard audioQualities.isEmpty else { return }
        isLoadingOptions = true
        message = nil
        defer { isLoadingOptions = false }
        do {
            audioQualities = try await BilibiliAPI.shared.audioQualities(for: video, cookie: bilibili.cookie)
            selectedAudioQuality = audioQualities.first?.code
        } catch {
            message = "读取音频音质失败：\(error.localizedDescription)"
        }
    }

    @MainActor private func startDownload() async {
        isStarting = true
        message = nil
        defer { isStarting = false }

        do {
            switch mode {
            case .video:
                let playback = try await BilibiliAPI.shared.playback(
                    for: video, quality: selectedVideoQuality, cookie: bilibili.cookie
                )
                let qualityTitle = playback.qualities.first(where: { $0.code == playback.quality })?.title
                    ?? "\(playback.quality)p"
                BilibiliDownloadManager.shared.enqueue(
                    source: playback.url,
                    bvid: video.bvid,
                    title: video.title,
                    author: video.author,
                    kind: .video,
                    quality: qualityTitle,
                    fileExtension: sourceExtension(playback.url, kind: .video),
                    cookie: bilibili.cookie
                )
                message = selectedVideoQuality == playback.quality
                    ? "已加入视频下载"
                    : "请求画质不可用，已按 B 站实际返回的 \(qualityTitle) 下载"
            case .audio:
                let playback = try await BilibiliAPI.shared.audioPlayback(
                    for: video, quality: selectedAudioQuality, cookie: bilibili.cookie
                )
                BilibiliDownloadManager.shared.enqueue(
                    source: playback.url,
                    bvid: video.bvid,
                    title: video.title,
                    author: video.author,
                    kind: .audio,
                    quality: playback.quality.title,
                    fileExtension: sourceExtension(playback.url, kind: .audio),
                    cookie: bilibili.cookie
                )
                message = "已加入音频下载"
            }
        } catch {
            message = "无法开始下载：\(error.localizedDescription)"
        }
    }

    private func sourceExtension(_ url: URL, kind: BilibiliDownloadManager.Kind) -> String {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        return kind == .audio ? "m4s" : "mp4"
    }
}
#endif
