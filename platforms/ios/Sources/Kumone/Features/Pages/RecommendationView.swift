#if os(iOS)
import SwiftUI

/// Source-only recommendation surface.
///
/// The LX User API bridge deliberately does not invent a catalogue API. This
/// page therefore recommends tracks the user has actually imported locally,
/// while playback, lyrics and artwork still come from the selected LX source.
struct RecommendationView: View {
    @StateObject private var sourceStore = LXSourceStore.shared
    @StateObject private var sourceAPI = LXUserAPIService.shared
    @StateObject private var playlists = LocalPlaylistStore.shared
    @EnvironmentObject private var player: PlayerService
    @State private var showSourceManager = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let track = player.currentTrack {
                    nowPlayingCard(track)
                }

                Text("本地推荐")
                    .font(.title3.weight(.bold))

                if playlists.playlists.isEmpty {
                    emptyRecommendations
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(playlists.playlists.prefix(6)) { playlist in
                            NavigationLink(value: Destination.localPlaylist(playlist.id)) {
                                playlistRow(playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                sourceExplanation
                PlayerClearanceSpacer()
            }
            .padding(Theme.Layout.contentInset)
        }
        .navigationTitle("推荐")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSourceManager = true
                } label: {
                    Label("管理音源", systemImage: "waveform.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showSourceManager) {
            NavigationStack { LXSourceManagerView() }
        }
        .task {
            sourceAPI.ensureSelectedSourceLoaded()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("欢迎回来")
                .font(.largeTitle.weight(.bold))
            Text("来自你的歌单和当前 LX 音源")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func nowPlayingCard(_ track: Track) -> some View {
        Button {
            player.showNowPlaying = true
        } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(160), animated: false)
                    .frame(width: 58, height: 58)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("正在播放")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                    Text(track.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .compatGlass(interactive: true, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var emptyRecommendations: some View {
        VStack(spacing: 12) {
            EmptyStateView(
                icon: "sparkles",
                title: "还没有推荐内容",
                subtitle: "导入歌单后，这里会显示你的本地推荐"
            )
            NavigationLink(value: Destination.localPlaylists) {
                Label("导入或创建歌单", systemImage: "music.note.list.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 16)
    }

    private func playlistRow(_ playlist: LocalPlaylist) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(160), animated: false)
                .frame(width: 62, height: 62)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    if playlist.coverURL == nil {
                        Image(systemName: "music.note.list")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(playlist.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("\(playlist.tracks.count) 首歌曲")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sourceExplanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("播放音源", systemImage: "waveform")
                .font(.headline)
            Text(sourceStore.selectedSource?.name ?? "尚未选择 LX 音源")
                .font(.subheadline.weight(.semibold))
            Text(sourceAPI.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
#endif
