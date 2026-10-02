#if os(iOS)
import SwiftUI

extension Track {
    /// A Bilibili video as a playable "song": its audio stream goes through the
    /// regular player (see PlayerService.resolveAndLoad, source "bili").
    static func bilibili(_ video: BilibiliAPI.Video) -> Track {
        Track(
            id: video.aid,
            name: video.title,
            artists: [ArtistRef(id: video.authorID, name: video.author, picUrl: video.authorAvatarURL)],
            album: AlbumRef(id: 0, name: "哔哩哔哩", picUrl: video.coverURL),
            durationMS: Int(video.duration * 1000),
            source: "bili",
            sourceMetadata: [
                "source": "bili",
                "songmid": video.bvid,
                "bvid": video.bvid,
                "aid": String(video.aid),
            ]
        )
    }
}

/// Bilibili results shown inside the normal search page (platform chip 哔哩哔哩).
struct BilibiliSearchResults: View {
    let keyword: String

    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var player: PlayerService
    @State private var videos: [BilibiliAPI.Video] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selected: BilibiliAPI.Video?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading && videos.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            } else if let errorMessage, videos.isEmpty {
                ErrorStateView(message: errorMessage) { Task { await load() } }
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if videos.isEmpty {
                EmptyStateView(icon: "play.rectangle", title: "没有找到相关视频")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                modeHint
                ForEach(videos) { video in
                    Button {
                        open(video)
                    } label: {
                        row(video)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .task(id: keyword) { await load() }
        .sheet(item: $selected) { video in
            NavigationStack {
                BilibiliVideoDetailView(video: video)
                    .environmentObject(bilibili)
                    .environmentObject(settings)
            }
        }
    }

    private var modeHint: some View {
        Picker("播放方式", selection: $settings.bilibiliMode) {
            Text("听视频").tag(BilibiliMode.listen)
            Text("看视频").tag(BilibiliMode.watch)
        }
        .pickerStyle(.segmented)
    }

    private func row(_ video: BilibiliAPI.Video) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: video.coverURL?.resizedImageURL(240), animated: false) {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 112, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(video.author) · \(video.durationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: settings.bilibiliMode == .listen ? "headphones" : "play.rectangle")
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .contentShape(Rectangle())
    }

    private func open(_ video: BilibiliAPI.Video) {
        if settings.bilibiliMode == .listen {
            let tracks = videos.map(Track.bilibili)
            player.play(tracks: tracks, source: .none, startAt: Track.bilibili(video))
        } else {
            selected = video
        }
    }

    @MainActor
    private func load() async {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await BilibiliAPI.shared.searchVideos(keyword: query, cookie: bilibili.cookie)
            videos = BilibiliContentFilter.videos(page.videos)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
