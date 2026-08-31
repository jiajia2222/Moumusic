import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    /// Shared so the loaded page survives sidebar switches (no skeleton flash).
    static let shared = HomeViewModel()

    enum State {
        case idle, loading, loaded
        case error(String)
    }

    /// The personalized radar family — global playlist IDs whose content is
    /// generated per logged-in account (same list YesPlayMusic special-cases).
    static let radarPlaylistIDs = [
        3_136_952_023, // 私人雷达
        2_829_883_282, // 华语私人雷达
        2_829_816_518, // 欧美私人雷达
        2_829_896_389, // 日系私人雷达
    ]

    struct RadarPlaylist: Identifiable, Hashable {
        let id: Int
        let title: String
        let subtitle: String?
        let coverURL: String?
    }

    @Published var state: State = .idle
    @Published var recommendPlaylists: [PlaylistSummary] = []
    @Published var radarPlaylists: [RadarPlaylist] = []
    @Published var toplists: [ToplistItem] = []
    @Published var newAlbums: [AlbumSummary] = []
    @Published var topArtists: [ArtistSummary] = []
    @Published var dailyFirstCover: String?
    @Published private(set) var activeMode: HomeRecommendationMode = .netease
    @Published private(set) var activePlatform: LXCatalogPlatform = .wy
    @Published var recommendTracks: [Track] = []
    @Published var lxRecommendPlaylists: [LXPlaylistSummary] = []
    private var loadedMode: HomeRecommendationMode?
    private var loadedPlatform: LXCatalogPlatform?

    func load(loggedIn: Bool, mode: HomeRecommendationMode,
              platform: LXCatalogPlatform) async {
        if loadedMode == mode, loadedPlatform == platform, case .loaded = state { return }
        activeMode = mode
        activePlatform = mode == .netease ? .wy : platform
        loadedMode = mode
        loadedPlatform = platform
        state = .loading

        if mode == .lx {
            // LX recommendations are catalogue-only. The selected source is
            // still the only component allowed to resolve audio on iOS.
            let content = await LXCatalogService.recommendedContent(platform: platform, limit: 30)
            lxRecommendPlaylists = content.playlists
            recommendTracks = content.tracks
            state = recommendTracks.isEmpty && lxRecommendPlaylists.isEmpty
                ? .error("LX 暂无推荐结果，请检查网络或切换推荐平台")
                : .loaded
            return
        }

        // Public NetEase recommendations are restored as a catalogue family.
        // No account or NetEase audio URL is used here; queued tracks are
        // resolved by the selected LX User API in PlayerService.
        async let playlistsTask = fetchRecommendPlaylists(loggedIn: loggedIn)
        async let toplistsTask = try? NeteaseAPI.toplists()
        async let albumsTask = try? NeteaseAPI.newAlbums(limit: 20)
        async let artistsTask = try? NeteaseAPI.topArtists()

        recommendPlaylists = await playlistsTask
        toplists = Array((await toplistsTask ?? []).prefix(12))
        newAlbums = await albumsTask ?? []
        topArtists = Array((await artistsTask ?? []).prefix(12))
        if loggedIn {
            if let daily = try? await NeteaseAPI.dailyRecommendSongs() {
                dailyFirstCover = daily.first?.album.picUrl
            }
            await loadRadarPlaylists()
        }
        state = recommendPlaylists.isEmpty && newAlbums.isEmpty && toplists.isEmpty
            ? .error("网易云推荐暂时不可用，请检查网络后重试")
            : .loaded
    }

    func reload(loggedIn: Bool, mode: HomeRecommendationMode,
                platform: LXCatalogPlatform) async {
        state = .idle
        loadedMode = nil
        loadedPlatform = nil
        await load(loggedIn: loggedIn, mode: mode, platform: platform)
    }

    private func loadRadarPlaylists() async {
        let briefs = await withTaskGroup(of: (Int, NeteaseAPI.PlaylistBrief.Body?).self) { group in
            for id in Self.radarPlaylistIDs {
                group.addTask {
                    (id, try? await NeteaseAPI.playlistBrief(id: id))
                }
            }
            var byID: [Int: NeteaseAPI.PlaylistBrief.Body] = [:]
            for await (id, brief) in group {
                if let brief { byID[id] = brief }
            }
            return byID
        }
        radarPlaylists = Self.radarPlaylistIDs.compactMap { id in
            guard let brief = briefs[id] else { return nil }
            // Names arrive as "今天从《…》听起|私人雷达" — split into title/subtitle.
            let parts = (brief.name ?? "").components(separatedBy: "|")
            let title = parts.count > 1 ? parts.last! : (brief.name ?? String(localized: "雷达歌单"))
            let subtitle = parts.count > 1 ? parts.dropLast().joined(separator: "|") : nil
            return RadarPlaylist(id: id, title: title, subtitle: subtitle, coverURL: brief.coverImgUrl)
        }
    }

    private func fetchRecommendPlaylists(loggedIn: Bool) async -> [PlaylistSummary] {
        if loggedIn {
            async let recommend = try? NeteaseAPI.recommendResource()
            async let personalized = try? NeteaseAPI.personalizedPlaylists(limit: 30)
            let head = await recommend ?? []
            let tail = await personalized ?? []
            var seen = Set<Int>()
            return (head + tail).filter { seen.insert($0.id).inserted }
        }
        return (try? await NeteaseAPI.personalizedPlaylists(limit: 30)) ?? []
    }
}

struct HomeView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @StateObject private var model = HomeViewModel.shared

    var body: some View {
        ScrollView {
            switch model.state {
            case .idle, .loading:
                loadingBody
            case .error(let message):
                ErrorStateView(message: message) {
                    Task {
                        await model.reload(loggedIn: account.isLoggedIn,
                                           mode: settings.homeRecommendationMode,
                                           platform: settings.homeRecommendationPlatform)
                    }
                }
                .frame(minHeight: 400)
            case .loaded:
                if model.activeMode == .lx {
                    lxLoadedBody
                } else {
                    loadedBody
                }
            }
        }
        .navigationTitle("推荐")
        .task(id: "\(account.isLoggedIn)-\(settings.homeRecommendationMode.rawValue)-\(settings.homeRecommendationPlatform.rawValue)") {
            await model.load(loggedIn: account.isLoggedIn,
                             mode: settings.homeRecommendationMode,
                             platform: settings.homeRecommendationPlatform)
        }
    }

    private var lxLoadedBody: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            homePlatformPicker

            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .foregroundStyle(Theme.accent)
                Text("\(model.activePlatform.displayName) 推荐")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, Theme.Layout.contentInset)

            if !model.lxRecommendPlaylists.isEmpty {
                Shelf(title: "推荐歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.lxRecommendPlaylists.prefix(12)) { playlist in
                        lxPlaylistCard(playlist)
                    }
                }
            }

            if !model.recommendTracks.isEmpty {
                SectionHeader(title: "推荐歌曲")
                    .padding(.horizontal, Theme.Layout.contentInset)
                TrackListView(tracks: model.recommendTracks)
                    .padding(.horizontal, Theme.Layout.contentInset - 10)
            }
            PlayerClearanceSpacer()
        }
        .padding(.vertical, Theme.Layout.contentInset - 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var homePlatformPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("首页推荐平台")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(homePlatforms) { platform in
                        Button {
                            selectHomePlatform(platform)
                        } label: {
                            Text(platform.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(isHomePlatform(platform) ? .white : .primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(isHomePlatform(platform) ? Theme.accent : Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
        }
        .padding(.top, 4)
    }

    private var homePlatforms: [LXCatalogPlatform] {
        LXCatalogPlatform.allCases.filter { $0 != .aggregate }
    }

    private func isHomePlatform(_ platform: LXCatalogPlatform) -> Bool {
        if platform == .wy { return settings.homeRecommendationMode == .netease }
        return settings.homeRecommendationMode == .lx
            && settings.homeRecommendationPlatform == platform
    }

    private func selectHomePlatform(_ platform: LXCatalogPlatform) {
        settings.homeRecommendationPlatform = platform
        settings.homeRecommendationMode = platform == .wy ? .netease : .lx
    }

    private func lxPlaylistCard(_ playlist: LXPlaylistSummary) -> some View {
        NavigationLink(value: Destination.lxPlaylist(source: playlist.source, id: playlist.id)) {
            CoverCardBody(
                coverURL: playlist.coverURL?.resizedImageURL(384),
                title: playlist.name,
                subtitle: [playlist.source.displayName, playlist.author].compactMap { $0 }.joined(separator: " · "),
                playCount: playlist.playCount
            )
        }
        .buttonStyle(.plain)
    }

    private var loadingBody: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonView(cornerRadius: Theme.Radius.large)
                        .frame(width: 230, height: 132)
                }
            }
            SkeletonShelf()
            SkeletonShelf()
        }
        .padding(Theme.Layout.contentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadedBody: some View {
        LazyVStack(alignment: .leading, spacing: 34) {
            homePlatformPicker
            featureCards
                .padding(.top, 8)

            if !model.recommendPlaylists.isEmpty {
                Shelf(title: "推荐歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(Array(model.recommendPlaylists.prefix(12).enumerated()), id: \.element.id) { index, playlist in
                        playlistCard(playlist)
                            .staggeredAppearance(index: index, id: "home-rec-\(playlist.id)")
                    }
                }
            }

            if !model.radarPlaylists.isEmpty {
                Shelf(title: "雷达歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.radarPlaylists) { radar in
                        NavigationLink(value: Destination.playlist(radar.id)) {
                            CoverCardBody(
                                coverURL: radar.coverURL?.resizedImageURL(384),
                                title: radar.title,
                                subtitle: radar.subtitle
                            ) {
                                playPlaylist(radar.id)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !model.toplists.isEmpty {
                Shelf(title: "排行榜", seeAll: nil, rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.toplists) { toplist in
                        NavigationLink(value: Destination.playlist(toplist.id)) {
                            toplistCard(toplist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !model.newAlbums.isEmpty {
                Shelf(title: "新碟上架", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.newAlbums) { album in
                        albumCard(album)
                    }
                }
            }

            if !model.topArtists.isEmpty {
                Shelf(title: "推荐歌手", rowHeight: Theme.Layout.artistShelfHeight) {
                    ForEach(model.topArtists) { artist in
                        artistCard(artist)
                    }
                }
            }

            PlayerClearanceSpacer()
        }
        .padding(.vertical, Theme.Layout.contentInset - 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Feature cards

    private var featureCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Color.clear.frame(width: max(0, Theme.Layout.contentInset - 16), height: 1)
                if account.isLoggedIn {
                    NavigationLink(value: Destination.daily) {
                        FeatureCard(
                            title: "每日推荐",
                            subtitle: "根据你的口味生成",
                            icon: "calendar",
                            coverURL: model.dailyFirstCover?.resizedImageURL(512),
                            showsDate: true
                        )
                    }
                    .buttonStyle(.plain)

                }

                Button {
                    player.startFM()
                } label: {
                    FeatureCard(
                        title: "LX 漫游",
                        subtitle: "按首页平台生成漫游队列",
                        icon: "wave.3.right.circle.fill",
                        gradient: [Color(red: 0.16, green: 0.20, blue: 0.42),
                                   Color(red: 0.36, green: 0.24, blue: 0.62)]
                    )
                }
                .buttonStyle(.interactiveCard)

                if account.isLoggedIn {
                    Button {
                        startHeartbeatMode()
                    } label: {
                        FeatureCard(
                            title: "心动模式",
                            subtitle: "你的红心歌曲和相似推荐",
                            icon: "heart.circle.fill",
                            gradient: [Color(red: 0.85, green: 0.19, blue: 0.41),
                                       Color(red: 0.98, green: 0.42, blue: 0.34)]
                        )
                    }
                    .buttonStyle(.interactiveCard)
                }
                Color.clear.frame(width: max(0, Theme.Layout.contentInset - 16), height: 1)
            }
            .padding(.vertical, 6)
        }
        .compatScrollClipDisabled()
    }

    private func startHeartbeatMode() {
        guard let likedList = account.likedSongsPlaylist else { return }
        Task {
            guard let seed = account.likedTrackIDs.randomElement() else {
                ToastCenter.shared.show(String(localized: "先收藏一些喜欢的歌曲吧"))
                return
            }
            do {
                let tracks = try await NeteaseAPI.intelligenceList(songID: seed, playlistID: likedList.id)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "心动模式暂时不可用"))
                    return
                }
                player.play(tracks: tracks, source: .playlist(likedList.id),
                            context: .heartbeat)
                ToastCenter.shared.show(String(localized: "已开启心动模式"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    // MARK: - Cards

    private func playlistCard(_ playlist: PlaylistSummary) -> some View {
        NavigationLink(value: Destination.playlist(playlist.id)) {
            CoverCardBody(
                coverURL: playlist.coverURL?.resizedImageURL(384),
                title: playlist.name,
                subtitle: playlist.copywriter,
                playCount: playlist.playCount
            ) {
                playPlaylist(playlist.id)
            }
        }
        .buttonStyle(.plain)
    }

    private func albumCard(_ album: AlbumSummary) -> some View {
        NavigationLink(value: Destination.album(album.id)) {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.artistName
            ) {
                Task {
                    if let detail = try? await NeteaseAPI.album(id: album.id) {
                        player.play(tracks: detail.songs, source: .album(album.id),
                                    context: .album(id: album.id, name: album.name))
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func artistCard(_ artist: ArtistSummary) -> some View {
        NavigationLink(value: Destination.artist(artist.id)) {
            VStack(spacing: 10) {
                CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                    .frame(width: 128, height: 128)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                Text(artist.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
    }

    private func toplistCard(_ toplist: ToplistItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(384))
                    .frame(width: Theme.Layout.cardSize, height: Theme.Layout.cardSize)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                Text(toplist.updateFrequency ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(8)
            }
            .frame(width: Theme.Layout.cardSize, height: Theme.Layout.cardSize)
            Text(toplist.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: Theme.Layout.cardSize, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func playPlaylist(_ id: Int) {
        Task {
            guard let detail = try? await NeteaseAPI.playlistDetail(id: id) else { return }
            var tracks = detail.playlist.tracks
            if tracks.isEmpty {
                let ids = detail.playlist.trackIds.map(\.id)
                tracks = (try? await NeteaseAPI.songDetails(ids: Array(ids.prefix(500))))?.songs ?? []
            }
            player.play(tracks: tracks, source: .playlist(id),
                        context: .playlist(id: id, name: detail.playlist.name))
        }
    }
}

// MARK: - Feature card

struct FeatureCard: View {
    let title: String
    let subtitle: String
    let icon: String
    var coverURL: URL?
    var gradient: [Color] = [Color(red: 0.75, green: 0.16, blue: 0.22),
                             Color(red: 0.95, green: 0.35, blue: 0.28)]
    var showsDate = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let coverURL {
                CachedAsyncImage(url: coverURL)
                    .frame(width: 230, height: 132)
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.68)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.18), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 220)
            }

            VStack(alignment: .leading, spacing: 3) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                    if showsDate {
                        Text("\(Calendar.current.component(.day, from: .now))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(y: 3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(14)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .frame(width: 230, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

/// Card body without its own Button wrapper (for use inside NavigationLink).
struct CoverCardBody: View {
    let coverURL: URL?
    let title: String
    var subtitle: String?
    var playCount: Int = 0
    var size: CGFloat = Theme.Layout.cardSize
    var onPlay: (() -> Void)?

    @State private var isHovering = false
    @Environment(\.flexibleCardWidth) private var flexibleWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                artwork
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                    )
                if playCount > 0 {
                    PlayCountBadge(count: playCount)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                if let onPlay {
                    PlayOverlayButton(visible: isHovering, action: onPlay)
                        .padding(8)
                }
            }

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
            }
        }
        .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
    }

    @ViewBuilder
    private var artwork: some View {
        if flexibleWidth {
            CachedAsyncImage(url: coverURL)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            CachedAsyncImage(url: coverURL)
                .frame(width: size, height: size)
        }
    }
}
