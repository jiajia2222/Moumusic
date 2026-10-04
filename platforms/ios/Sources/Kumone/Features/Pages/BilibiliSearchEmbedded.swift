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
    private enum Kind: String, CaseIterable, Identifiable {
        case videos = "视频"
        case users = "用户"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .videos
    @State private var users: [BilibiliAPI.User] = []
    @State private var videos: [BilibiliAPI.Video] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selected: BilibiliAPI.Video?
    @State private var selectedUser: BilibiliAPI.User?

    private var isEmpty: Bool { kind == .videos ? videos.isEmpty : users.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Listen / watch is a global setting; here the user only picks what to search.
            Picker("搜索类型", selection: $kind) {
                ForEach(Kind.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)

            if isLoading && isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            } else if let errorMessage, isEmpty {
                ErrorStateView(message: errorMessage) { Task { await load() } }
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if isEmpty {
                EmptyStateView(icon: kind == .videos ? "play.rectangle" : "person.2",
                               title: kind == .videos ? "没有找到相关视频" : "没有找到相关用户")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if kind == .videos {
                ForEach(videos) { video in
                    Button {
                        open(video)
                    } label: {
                        row(video)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ForEach(users) { user in
                    Button { selectedUser = user } label: { userRow(user).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .task(id: "\(keyword)|\(kind.rawValue)") { await load() }
        .sheet(item: $selected) { video in
            NavigationStack {
                BilibiliVideoDetailView(video: video)
                    .environmentObject(bilibili)
                    .environmentObject(settings)
            }
        }
        .sheet(item: $selectedUser) { user in
            NavigationStack {
                BilibiliUserVideosView(user: user)
                    .environmentObject(bilibili)
                    .environmentObject(settings)
                    .environmentObject(player)
            }
        }
    }

    private func userRow(_ user: BilibiliAPI.User) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: user.avatarURL?.resizedImageURL(160), animated: false)
                .frame(width: 54, height: 54)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(user.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(user.signature.isEmpty ? "UP 主" : user.signature)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if user.followerCount > 0 {
                Text("粉丝 \(Formatters.playCount(user.followerCount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
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
            switch kind {
            case .videos:
                let page = try await BilibiliAPI.shared.searchVideos(keyword: query, cookie: bilibili.cookie)
                videos = BilibiliContentFilter.videos(page.videos)
            case .users:
                users = try await BilibiliAPI.shared.searchUsers(keyword: query, cookie: bilibili.cookie)
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
/// One uploader's videos, opened from a user search result.
struct BilibiliUserVideosView: View {
    let user: BilibiliAPI.User

    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss
    @State private var videos: [BilibiliAPI.Video] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selected: BilibiliAPI.Video?
    @State private var selectedUser: BilibiliAPI.User?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    CachedAsyncImage(url: user.avatarURL?.resizedImageURL(160), animated: false)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name).font(.headline)
                        if !user.signature.isEmpty {
                            Text(user.signature).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else if let errorMessage, videos.isEmpty {
                    ErrorStateView(message: errorMessage) { Task { await load() } }
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if videos.isEmpty {
                    EmptyStateView(icon: "play.rectangle", title: "这个用户还没有公开视频")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(videos) { video in
                        Button { open(video) } label: {
                            HStack(spacing: 12) {
                                CachedAsyncImage(url: video.coverURL?.resizedImageURL(240), animated: false) {
                                    Color.secondary.opacity(0.15)
                                }
                                .frame(width: 112, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text("\(Formatters.playCount(video.playCount)) 播放 · \(video.durationText)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: settings.bilibiliMode == .listen ? "headphones" : "play.rectangle")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
            .padding(.top, 8)
            PlayerClearanceSpacer()
        }
        .refreshable { await load() }
        .navigationTitle(user.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .task { await load() }
        .sheet(item: $selected) { video in
            NavigationStack {
                BilibiliVideoDetailView(video: video)
                    .environmentObject(bilibili)
                    .environmentObject(settings)
            }
        }
    }

    private func open(_ video: BilibiliAPI.Video) {
        if settings.bilibiliMode == .listen {
            player.play(tracks: videos.map(Track.bilibili), source: .none, startAt: Track.bilibili(video))
        } else {
            selected = video
        }
    }

    @MainActor private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            videos = BilibiliContentFilter.videos(try await BilibiliAPI.shared.userVideos(user: user, cookie: bilibili.cookie))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}#endif
