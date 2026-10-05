import SwiftUI

@MainActor
final class ExploreViewModel: ObservableObject {
    static let shared = ExploreViewModel()

    static let categories = [
        "推荐", "最热", "最新", "华语", "流行", "摇滚", "民谣", "电子",
        "轻音乐", "说唱", "古典", "影视原声", "ACG", "古风", "怀旧", "治愈",
    ]

    @Published var platform: LXCatalogPlatform = .kw
    @Published var selectedCategory = "推荐"
    /// Platform-native recommendation playlists are rendered separately from
    /// category results so the first section can stay horizontal.
    @Published var officialPlaylists: [LXPlaylistSummary] = []
    @Published var playlists: [LXPlaylistSummary] = []
    @Published var tracks: [Track] = []
    @Published var toplists: [ToplistItem] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var errorMessage: String?

    private var page = 1
    private var loadTask: Task<Void, Never>?
    private var requestGeneration = 0

    func prepare(platform: LXCatalogPlatform) {
        guard platform != self.platform else { return }
        self.platform = platform
        requestGeneration += 1
        loadTask?.cancel()
        isLoading = false
        officialPlaylists = []
        playlists = []
        tracks = []
        toplists = []
        page = 1
        hasMore = true
        errorMessage = nil
    }

    func selectPlatform(_ platform: LXCatalogPlatform) {
        guard platform != self.platform else { return }
        prepare(platform: platform)
        loadTask?.cancel()
        loadTask = Task { await loadMore() }
    }

    func select(_ category: String) {
        requestGeneration += 1
        loadTask?.cancel()
        isLoading = false
        selectedCategory = category
        officialPlaylists = []
        playlists = []
        tracks = []
        toplists = []
        page = 1
        hasMore = true
        errorMessage = nil
        loadTask = Task { await loadMore() }
    }

    /// Re-entering the Featured tab is an explicit refresh. Keep the source
    /// and category, but discard the previous page so the user sees a fresh
    /// recommendation request instead of the cached first page.
    func refreshCurrent() {
        requestGeneration += 1
        loadTask?.cancel()
        isLoading = false
        officialPlaylists = []
        playlists = []
        tracks = []
        toplists = []
        page = 1
        hasMore = true
        errorMessage = nil
        loadTask = Task { await loadMore() }
    }

    /// Set by `refresh()`: the request of that generation replaces the shown content when it arrives (the page is
    /// not emptied first, so there is no flash and an empty/failed answer leaves what the user is looking at).
    private var replaceGeneration: Int?

    /// Pull-to-refresh and the error screen's retry: reload the current platform and category.
    func refresh() async {
        requestGeneration += 1
        loadTask?.cancel()
        isLoading = false
        page = 1
        hasMore = true
        errorMessage = nil
        replaceGeneration = requestGeneration
        // The request runs in its own task. SwiftUI cancels the task that drives `.refreshable` whenever the page
        // content changes, and a cancelled request surfaced as "已取消" / "加载失败".
        let work = Task { [weak self] in
            guard let self else { return }
            await self.loadMore()
        }
        loadTask = work
        // The pull gesture only holds the page pulled down while this function runs: give it a moment of feedback
        // and let it spring back; the new content swaps in by itself when the request finishes.
        for _ in 0..<7 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !isLoading { break }
        }
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        let generation = requestGeneration
        isLoading = true
        defer {
            if generation == requestGeneration { isLoading = false }
        }

        do {
            let result: [LXPlaylistSummary]
            if selectedCategory == "推荐" && page == 1 {
                // A request that comes back empty right after a platform switch is usually a transient miss:
                // try again a couple of times before showing an error.
                // A pull-to-refresh asks for variety: another batch of songs instead of the same top 30 again.
                let variety = replaceGeneration == generation
                var content = await LXCatalogService.recommendedContent(platform: platform, limit: 30, variety: variety)
                var attempt = 0
                while content.playlists.isEmpty, content.tracks.isEmpty, attempt < 2 {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard generation == requestGeneration else { return }
                    content = await LXCatalogService.recommendedContent(platform: platform, limit: 30, variety: variety)
                }
                guard generation == requestGeneration else { return }
                var newPlaylists = content.playlists
                var newTracks = content.tracks
                if platform == .wy {
                    if newPlaylists.isEmpty {
                        let personalized = (try? await NeteaseAPI.personalizedPlaylists(limit: 30)) ?? []
                        newPlaylists = personalized.map {
                            LXPlaylistSummary(id: String($0.id), name: $0.name, coverURL: $0.coverURL,
                                              playCount: $0.playCount, trackCount: $0.trackCount,
                                              description: $0.copywriter, author: $0.creator?.nickname, source: .wy)
                        }
                    }
                    // NetEase's official hot chart. On a refresh take a different 30 of its top 100.
                    var liveTracks = (try? await NeteaseAPI.hotSongs(limit: variety ? 100 : 30))?
                        .map { $0.normalizedForLXPlayback() } ?? []
                    if variety { liveTracks = Array(liveTracks.shuffled().prefix(30)) }
                    if !liveTracks.isEmpty { newTracks = liveTracks }
                    // Every await above can outlive this request: a stale answer must never overwrite a newer one.
                    guard generation == requestGeneration else { return }
                }
                // Only now is anything shown, once, so there is no flash of one list replaced by another.
                let emptyAnswer = newPlaylists.isEmpty && newTracks.isEmpty
                DiagnosticLogStore.shared.append(
                    level: .info, category: "发现页",
                    message: "\(platform.displayName) 推荐\(variety ? "（刷新，换一批）" : "")：歌单 \(newPlaylists.count)、歌曲 \(newTracks.count)",
                    detail: "前几首：" + newTracks.prefix(4).map(\.name).joined(separator: "、"))
                if !(replaceGeneration == generation && emptyAnswer) {
                    officialPlaylists = newPlaylists
                    tracks = newTracks
                }
                // The recommendation shelf owns these cards; keeping them out
                // of the grid avoids rendering the same playlists twice.
                result = []
            } else if (selectedCategory == "最热" || selectedCategory == "最新") && platform != .wy {
                result = try await LXCatalogService.sortedSonglists(platform: platform,
                                                                     category: selectedCategory,
                                                                     page: page, limit: 30)
            } else {
                let keyword: String
                switch selectedCategory {
                case "最热": keyword = "热门"
                case "最新": keyword = "最新"
                default: keyword = selectedCategory
                }
                result = try await LXCatalogService.searchSonglists(keyword, platform: platform,
                                                                     page: page, limit: 30)
            }

            guard generation == requestGeneration else { return }
            if replaceGeneration == generation {
                playlists = []
                replaceGeneration = nil
            }
            var seen = Set(playlists.map { "\($0.source.rawValue)|\($0.id)" })
            playlists += result.filter { seen.insert("\($0.source.rawValue)|\($0.id)").inserted }
            page += 1
            hasMore = selectedCategory != "推荐" && result.count >= 30 && page <= 6
            errorMessage = officialPlaylists.isEmpty && playlists.isEmpty && tracks.isEmpty
                ? "当前平台暂时没有歌单，请切换平台或稍后重试"
                : nil
        } catch {
            guard generation == requestGeneration else { return }
            // A cancelled request is not a failure the user can act on: no error screen for it.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            errorMessage = officialPlaylists.isEmpty && playlists.isEmpty && tracks.isEmpty
                ? error.localizedDescription
                : nil
            hasMore = false
        }
    }
}

struct ExploreView: View {
    @StateObject private var model = ExploreViewModel.shared
    @EnvironmentObject private var settings: SettingsManager
#if os(iOS)
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @State private var showBilibili = false
#endif

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
#if !os(iOS)
                platformPicker
#endif
                categoryChips

                if model.isLoading && model.officialPlaylists.isEmpty && model.playlists.isEmpty && model.tracks.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if let errorMessage = model.errorMessage,
                          model.officialPlaylists.isEmpty && model.playlists.isEmpty && model.tracks.isEmpty {
                    ErrorStateView(message: errorMessage) {
                        Task { await model.refresh() }
                    }
                    .frame(minHeight: 300)
                } else {
                    if !model.officialPlaylists.isEmpty {
                        Shelf(title: "官方推荐歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                            ForEach(model.officialPlaylists.prefix(12)) { playlist in
                                NavigationLink(value: Destination.lxPlaylist(source: playlist.source, id: playlist.id)) {
                                    CoverCardBody(
                                        coverURL: playlist.coverURL?.resizedImageURL(384),
                                        title: playlist.name,
                                        subtitle: playlist.author ?? "",
                                        playCount: playlist.playCount
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !model.tracks.isEmpty {
                        SectionHeader(title: "\(model.platform.displayName) 热门歌曲")
                            .padding(.horizontal, Theme.Layout.contentInset)
                        TrackListView(tracks: model.tracks)
                            .padding(.horizontal, Theme.Layout.contentInset - 10)
                    }

                    CardGrid {
                        ForEach(Array(model.playlists.enumerated()), id: \.element.id) { index, playlist in
                            NavigationLink(value: Destination.lxPlaylist(source: playlist.source, id: playlist.id)) {
                                CoverCardBody(
                                    coverURL: playlist.coverURL?.resizedImageURL(384),
                                    title: playlist.name,
                                    subtitle: playlist.author ?? "",
                                    playCount: playlist.playCount
                                )
                            }
                            .buttonStyle(.plain)
                            .staggeredAppearance(index: index % 10, id: "explore-\(playlist.source.rawValue)-\(playlist.id)")
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)

                    if model.isLoading {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if model.hasMore {
                        Color.clear
                            .frame(height: 1)
                            .onAppear { Task { await model.loadMore() } }
                    }
                }

                PlayerClearanceSpacer()
            }
        }
        .refreshable { await model.refresh() }
        .navigationTitle("精选")
#if os(iOS)
        // Same liquid-glass platform switch as the home page (top-left).
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Section("发现平台") {
                        ForEach(LXCatalogPlatform.catalogueCases.filter { $0 != .aggregate }) { platform in
                            Button {
                                model.selectPlatform(platform)
                            } label: {
                                if model.platform == platform {
                                    Label(platform.displayName, systemImage: "checkmark")
                                } else {
                                    Text(platform.displayName)
                                }
                            }
                        }
                    }
                    if settings.bilibiliMode != .disabled {
                        Section {
                            Button { showBilibili = true } label: { Label("哔哩哔哩", systemImage: "play.rectangle.fill") }
                        }
                    }
                } label: {
                    HomePlatformBadge(platform: model.platform)
                }
                .accessibilityLabel("当前发现平台：\(model.platform.displayName)，点击切换")
            }
        }
#endif
        .task(id: "\(settings.homeRecommendationMode.rawValue)-\(settings.homeRecommendationPlatform.rawValue)") {
            model.prepare(platform: settings.homeRecommendationPlatform)
            await model.loadMore()
        }
        .onAppear {
            guard !model.officialPlaylists.isEmpty || !model.playlists.isEmpty || !model.tracks.isEmpty else { return }
            model.refreshCurrent()
        }
#if os(iOS)
        .fullScreenCover(isPresented: $showBilibili) {
            NavigationStack {
                BilibiliContentView()
                    .environmentObject(bilibili)
            }
        }
#endif
    }

    private var platformPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("发现平台")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Theme.Layout.contentInset)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LXCatalogPlatform.catalogueCases.filter { $0 != .aggregate }) { platform in
                        Button { model.selectPlatform(platform) } label: {
                            Text(platform.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(model.platform == platform ? .white : .primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(model.platform == platform ? Theme.accent : Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                    }
#if os(iOS)
                    // Bilibili sits in the same chip row instead of floating at the far right.
                    if settings.bilibiliMode != .disabled {
                        Button { showBilibili = true } label: {
                            HStack(spacing: 5) {
                                BrandIconView(name: "BrandBilibili").frame(width: 16, height: 16)
                                Text("哔哩哔哩")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                    }
#endif
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Spacer().frame(width: Theme.Layout.contentInset - 8)
                ForEach(ExploreViewModel.categories, id: \.self) { category in
                    Button { model.select(category) } label: {
                        Text(category)
                    }
                    .buttonStyle(.chip(isSelected: model.selectedCategory == category))
                }
                Spacer().frame(width: Theme.Layout.contentInset - 8)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - NetEase ranking page kept for the account/sidebar entry point.

struct ToplistGrid: View {
    let toplists: [ToplistItem]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20)],
            alignment: .leading, spacing: 20
        ) {
            ForEach(toplists) { toplist in
                NavigationLink(value: Destination.playlist(toplist.id)) {
                    HStack(spacing: 14) {
                        CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(256))
                            .frame(width: 110, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(toplist.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(toplist.updateFrequency ?? "")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(toplist.tracks.prefix(3).enumerated()), id: \.offset) { i, preview in
                                    Text("\(i + 1). \(preview.first) - \(preview.second)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ToplistsView: View {
    @State private var toplists: [ToplistItem] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ToplistGrid(toplists: toplists)
                    .padding(Theme.Layout.contentInset)
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("排行榜")
        .task {
            if toplists.isEmpty {
                toplists = (try? await NeteaseAPI.toplists()) ?? []
            }
        }
    }
}
