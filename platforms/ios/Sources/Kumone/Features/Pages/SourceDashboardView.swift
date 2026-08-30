#if os(iOS)
import SwiftUI

/// The iOS landing page deliberately contains no provider catalogue.  Tracks
/// come from a user-imported local playlist and are resolved only by the
/// selected LX User API source.
struct SourceDashboardView: View {
    @StateObject private var sourceStore = LXSourceStore.shared
    @StateObject private var sourceAPI = LXUserAPIService.shared
    @StateObject private var playlists = LocalPlaylistStore.shared
    @State private var showSourceManager = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceStatusCard
                workflowCard

                if !playlists.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("本地歌单")
                            .font(.headline)
                        ForEach(playlists.playlists.prefix(4)) { playlist in
                            NavigationLink(value: Destination.localPlaylist(playlist.id)) {
                                HStack(spacing: 12) {
                                    Image(systemName: "music.note.list")
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 34, height: 34)
                                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(playlist.name)
                                            .foregroundStyle(.primary)
                                        Text("\(playlist.tracks.count) 首歌曲")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(12)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                PlayerClearanceSpacer()
            }
            .padding(Theme.Layout.contentInset)
        }
        .navigationTitle("音源")
        .sheet(isPresented: $showSourceManager) {
            NavigationStack { LXSourceManagerView() }
        }
        .task {
            sourceAPI.ensureSelectedSourceLoaded()
        }
    }

    private var sourceStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(sourceStore.selectedSource?.name ?? "尚未选择 LX 音源")
                        .font(.title3.weight(.semibold))
                    Text(sourceAPI.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 12)
                Image(systemName: sourceStore.selectedSource == nil ? "waveform.badge.plus" : "checkmark.seal")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
            }

            Button {
                showSourceManager = true
            } label: {
                Label(sourceStore.selectedSource == nil ? "导入 LX 音源" : "管理 LX 音源", systemImage: "waveform.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.quaternary.opacity(0.52), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("纯音源播放", systemImage: "lock.shield")
                .font(.headline)
            Text("不会登录网易云，也不会请求软件预置的网易云、QQ、酷我、酷狗或咪咕目录接口。导入歌曲 JSON 后，播放地址、歌词和封面只由你选择的 LX 音源返回。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("路径：导入 LX 音源 → 导入本地歌单 → 搜索本地歌曲 → 播放。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
#endif
