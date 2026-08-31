#if os(iOS)
import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloads = DownloadManager.shared

    var body: some View {
        NavigationStack {
            Group {
                if downloads.records.isEmpty {
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
