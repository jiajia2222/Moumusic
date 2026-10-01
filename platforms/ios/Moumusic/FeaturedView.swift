import SwiftUI

/// 精选：歌单广场（顶部平台切换 + 搜索歌单 + 分类 + 双列大封面）。
@MainActor
struct FeaturedView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @AppStorage("beans.homeSource") private var homeSourceRaw = SearchProvider.netease.rawValue
    @AppStorage("beans.uiStyle") private var uiStyleRaw = BeansUIStyle.liquid.rawValue

    @State private var category = "全部"
    @State private var categories: [String] = ["全部", "推荐歌单", "精品歌单", "官方", "华语", "流行", "摇滚", "民谣", "电子", "ACG", "影视原声"]
    @State private var playlists: [Playlist] = []
    @State private var query = ""
    @State private var isSearchResult = false
    @State private var loading = false
    @State private var errorText: String?
    @State private var extraPresented: Playlist?

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    private var provider: SearchProvider {
        let saved = SearchProvider(rawValue: homeSourceRaw) ?? .netease
        let visible = platformPrefs.ensureVisible(saved)
        return visible.isVideoPlatform ? .netease : visible
    }

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.customBackground, homeMode: true)
                VStack(spacing: 12) {
                    PlatformHeaderBar { searchPill }
                        .padding(.horizontal, 16)
                    if provider == .netease && !isSearchResult {
                        categoryRow
                    }
                    ScrollView {
                        content
                            .padding(.horizontal, 16)
                            .padding(.bottom, 190)
                            .frame(maxWidth: 860)
                            .frame(maxWidth: .infinity)
                    }
                    .beansScrollIndicatorsHidden()
                    .refreshable { await load(force: true) }
                }
                .padding(.top, 6)
            }
            .navigationBarHidden(true)
        }
        .task(id: "\(provider.rawValue)|\(category)") { await load(force: false) }
        .sheet(item: $extraPresented) { playlist in
            ExtraSongListSheet(title: playlist.name) { try await ExtraPlatforms.playlistSongs(playlist) }
                .environmentObject(theme)
                .environmentObject(player)
                .environmentObject(auth)
        }
    }

    // MARK: 顶部

    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.beansComment)
            TextField("搜索歌单", text: $query)
                .font(BeansFont.appFont(16))
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
            if !query.isEmpty {
                Button {
                    query = ""
                    isSearchResult = false
                    Task { await load(force: false) }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.beansComment)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background { BeansGlass(shape: Capsule(), forceLiquid: true) }
        .clipShape(Capsule())
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { cat in
                    let selected = category == cat
                    Button {
                        BeansHaptics.select()
                        category = cat
                    } label: {
                        Text(cat)
                            .font(BeansFont.appFont(15, .semibold))
                            .foregroundStyle(selected ? Color.white : Color.beansLabel)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background {
                                if selected { Capsule().fill(Color.beansAmber) } else { BeansGlass(shape: Capsule(), forceLiquid: true) }
                            }
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if loading && playlists.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        } else if playlists.isEmpty {
            Text(errorText ?? (isSearchResult ? "没有找到相关歌单" : "\(beansPlatformName(provider))歌单暂时没有内容"))
                .font(BeansFont.appFont(14)).foregroundStyle(Color.beansComment)
                .frame(maxWidth: .infinity).padding(.top, 60)
        } else {
            if isSearchResult {
                Text("歌单搜索结果")
                    .font(BeansFont.appFont(18, .bold)).foregroundStyle(Color.beansLabel)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
            }
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(playlists) { playlist in
                    cell(playlist)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ playlist: Playlist) -> some View {
        let label = VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                CoverImage(url: playlist.coverURL, size: geo.size.width, cornerRadius: 24)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(playlist.name)
                .font(BeansFont.appFont(16, .bold))
                .foregroundStyle(Color.beansLabel)
                .lineLimit(1)
            Text(subtitle(for: playlist))
                .font(BeansFont.appFont(13))
                .foregroundStyle(Color.beansComment)
                .lineLimit(1)
        }

        if playlist.source == .kuwo || playlist.source == .migu {
            Button { extraPresented = playlist } label: { label }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
        } else {
            NavigationLink {
                PlaylistView(playlist: playlist)
                    .environmentObject(player)
                    .environmentObject(auth)
            } label: { label }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
        }
    }

    private func subtitle(for playlist: Playlist) -> String {
        let platform = beansPlatformName(provider).replacingOccurrences(of: "音乐", with: "")
        return playlist.creatorName.isEmpty ? platform : "\(platform) · \(playlist.creatorName)"
    }

    // MARK: 加载

    private var cacheKey: String { "featured|\(provider.rawValue)|\(category)" }

    private func load(force: Bool) async {
        guard !isSearchResult else { return }
        if !force, let cached = PlaylistSquareCache.shared.list(for: cacheKey) {
            playlists = cached
            return
        }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let list: [Playlist]
            switch provider {
            case .netease:
                let extra = await NetEaseAPI.shared.playlistCatlist()
                if !extra.isEmpty, categories.count <= 11 {
                    categories = ["全部", "推荐歌单", "精品歌单", "官方"] + Array(extra.prefix(24))
                }
                switch category {
                case "推荐歌单": list = await NetEaseAPI.shared.recommendedHomePlaylists(loggedIn: auth.isLoggedIn, limit: 40)
                case "精品歌单": list = try await NetEaseAPI.shared.highQualityPlaylists(cat: "全部", limit: 40)
                default: list = try await NetEaseAPI.shared.playlistSquare(cat: category, order: "hot", limit: 48)
                }
            case .qq: list = try await QQMusicAPI.shared.hotPlaylists(limit: 40)
            case .kugou: list = try await KugouMusicAPI.shared.recommendPlaylists(limit: 40)
            case .kuwo: list = try await KuwoMusicAPI.recommendedPlaylists()
            case .migu: list = try await MiguMusicAPI.recommendedPlaylists()
            case .bilibili: list = []
            }
            playlists = list
            PlaylistSquareCache.shared.save(list, for: cacheKey)
        } catch {
            if playlists.isEmpty { errorText = "歌单加载失败：下拉刷新可重试" }
        }
    }

    private func runSearch() async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        isSearchResult = true
        loading = true
        errorText = nil
        playlists = []
        defer { loading = false }
        if provider == .kuwo || provider == .migu {
            errorText = "该平台暂不支持歌单搜索"
            return
        }
        do {
            playlists = try await PlaylistSearchAPI.search(provider, keyword: keyword)
        } catch {
            errorText = "搜索失败，请稍后重试"
        }
    }
}
