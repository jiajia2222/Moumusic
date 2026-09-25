#if os(iOS)
import Foundation
import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var bilibiliDownloads = BilibiliDownloadManager.shared

    var body: some View {
        NavigationStack {
            Group {
                if downloads.records.isEmpty && downloads.activeDownloads.isEmpty
                    && bilibiliDownloads.records.isEmpty && bilibiliDownloads.activeDownloads.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("暂无下载")
                            .font(.headline)
                        Text("在歌曲列表或播放页的“更多操作”中选择下载")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List {
                        if !bilibiliDownloads.activeDownloads.isEmpty {
                            Section("B站正在下载") {
                                ForEach(Array(bilibiliDownloads.activeDownloads.values).sorted { $0.id < $1.id }) { item in
                                    HStack(spacing: 12) {
                                        Image(systemName: item.kind == .video ? "video" : "waveform")
                                            .foregroundStyle(Theme.accent)
                                            .frame(width: 32)
                                        VStack(alignment: .leading, spacing: 5) {
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
                                            bilibiliDownloads.cancel(item)
                                        } label: {
                                            Image(systemName: "xmark.circle")
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("取消 B站下载")
                                    }
                                    .frame(minHeight: 44)
                                }
                            }
                        }

                        if !bilibiliDownloads.records.isEmpty {
                            Section("已下载的 B站文件") {
                                ForEach(bilibiliDownloads.records) { record in
                                    HStack(spacing: 12) {
                                        Image(systemName: record.kind == .video ? "video.fill" : "waveform")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 32)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(record.title).lineLimit(1)
                                            Text("\(record.kind.displayName) · \(record.quality)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(record.fileName)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        ShareLink(item: record.fileURL) {
                                            Image(systemName: "square.and.arrow.up")
                                        }
                                        .disabled(!FileManager.default.fileExists(atPath: record.fileURL.path))
                                        .accessibilityLabel("分享 B站文件")
                                    }
                                    .frame(minHeight: 44)
                                }
                                .onDelete { offsets in
                                    for index in offsets { bilibiliDownloads.delete(bilibiliDownloads.records[index]) }
                                }
                            }
                        }

                        if !downloads.activeDownloads.isEmpty {
                            Section("正在下载") {
                                ForEach(Array(downloads.activeDownloads.values)) { item in
                                    HStack(spacing: 12) {
                                        CachedAsyncImage(url: item.track.album.picUrl?.resizedImageURL(128))
                                            .frame(width: 52, height: 52)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(item.track.name)
                                                .lineLimit(1)
                                            Text("请求音质：\(item.requestedQuality.displayName)")
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
                                    }
                                }
                            }
                        }

                        ForEach(downloads.records) { record in
                            Button {
                                player.playTrack(record.track)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    CachedAsyncImage(url: record.track.album.picUrl?.resizedImageURL(128))
                                        .frame(width: 52, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.track.name)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(record.track.artistNames) · \(AudioQuality(lxType: record.quality)?.displayName ?? record.quality)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            for index in offsets { downloads.delete(downloads.records[index]) }
                        }
                    }
                }
            }
            .navigationTitle("下载管理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
#endif
