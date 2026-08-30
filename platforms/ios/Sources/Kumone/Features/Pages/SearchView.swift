import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case all
        case songs
        case playlists

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return "综合"
            case .songs: return "歌曲"
            case .playlists: return "歌单"
            }
        }
    }

    var query: String
    @Published var tab: Tab = .all
    @Published var songs: [Track] = []
    @Published var playlists: [LXPlaylistSummary] = []
    @Published var hotKeywords: [String] = []
    @Published var isLoading = false
    @Published var isLoadingHot = false
    @Published var loadedTabs: Set<Tab> = []
    @Published var platform: LXCatalogPlatform = .aggregate

    init(query: String) {
        self.query = query
    }

    func setQuery(_ newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        loadedTabs.removeAll()
        songs = []
        playlists = []
    }

    func setPlatform(_ newPlatform: LXCatalogPlatform) {
        guard newPlatform != platform else { return }
        platform = newPlatform
        loadedTabs.removeAll()
        songs = []
        playlists = []
        hotKeywords = []
        Task { await loadHotKeywords() }
    }

    func load(tab: Tab, force: Bool = false) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, force || !loadedTabs.contains(tab) else { return }
        isLoading = true
        defer { isLoading = false }

        switch tab {
        case .all:
            async let songsTask = try? LXCatalogService.search(trimmed, platform: platform, limit: 12)
            async let playlistsTask = try? LXCatalogService.searchSonglists(trimmed, platform: platform, limit: 12)
            songs = await songsTask ?? []
            playlists = await playlistsTask ?? []
        case .songs:
            songs = (try? await LXCatalogService.search(trimmed, platform: platform, limit: 100)) ?? songs
        case .playlists:
            playlists = (try? await LXCatalogService.searchSonglists(trimmed, platform: platform, limit: 100)) ?? playlists
        }
        loadedTabs.insert(tab)
    }

    func loadHotKeywords() async {
        guard hotKeywords.isEmpty else { return }
        isLoadingHot = true
        defer { isLoadingHot = false }
        hotKeywords = (try? await LXCatalogService.hotKeywords(platform: platform)) ?? []
    }
}

struct SearchView: View {
    let initialQuery: String

    @StateObject private var model: SearchViewModel
    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool

    init(query: String) {
        self.initialQuery = query
        _model = StateObject(wrappedValue: SearchViewModel(query: query))
        _searchText = State(initialValue: query)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                searchBar

                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    platformPicker
                    tabPicker

                    if model.isLoading && currentEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        tabContent
                    }
                } else {
                    emptySearchPrompt
                    hotSearches
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("搜索")
        .task(id: "\(model.tab.rawValue)-\(model.platform.rawValue)") {
            await model.load(tab: model.tab)
        }
        .task {
            if !initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.setQuery(initialQuery)
                await model.load(tab: model.tab, force: true)
            }
            await model.loadHotKeywords()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索歌曲、歌手或歌单", text: $searchText)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { performSearch() }
                .accessibilityLabel("搜索关键词")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    model.setQuery("")
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .accessibilityLabel("清除搜索关键词")
            }

            Button("搜索") { performSearch() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("提交搜索")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, 12)
    }

    private func performSearch(_ submittedText: String? = nil) {
        let query = (submittedText ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchFocused = false
        model.setQuery(query)
        Task { await model.load(tab: model.tab, force: true) }
    }

    private var tabPicker: some View {
        Picker("搜索类型", selection: $model.tab) {
            ForEach(SearchViewModel.Tab.allCases) { tab in
                Text(tab.displayName).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private var platformPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("搜索平台")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LXCatalogPlatform.allCases) { platform in
                        Button {
                            model.setPlatform(platform)
                        } label: {
                            Text(platform.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(model.platform == platform ? .white : .primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(model.platform == platform ? Color.accentColor : Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
        }
        .padding(.top, 12)
    }

    private var emptySearchPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 44)
            Text("搜索歌曲和歌单")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("聚合搜索只在搜索页使用；首页推荐按你设置的平台单独加载。")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var hotSearches: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("热门搜索")
                .font(.headline)
                .padding(.horizontal, Theme.Layout.contentInset)
            if model.isLoadingHot && model.hotKeywords.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                    ForEach(Array(model.hotKeywords.prefix(20)), id: \.self) { keyword in
                        Button(keyword) {
                            searchText = keyword
                            performSearch(keyword)
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
        }
    }

    private var currentEmpty: Bool {
        switch model.tab {
        case .all: return model.songs.isEmpty && model.playlists.isEmpty
        case .songs: return model.songs.isEmpty
        case .playlists: return model.playlists.isEmpty
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .all:
            if !model.songs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "歌曲") { model.tab = .songs }
                        .padding(.horizontal, Theme.Layout.contentInset)
                    TrackListView(tracks: Array(model.songs.prefix(6)))
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
            }
            if !model.playlists.isEmpty {
                Shelf(title: "歌单", seeAll: { model.tab = .playlists }) {
                    playlistCards(model.playlists.prefix(8))
                }
            }
            if currentEmpty, !model.isLoading {
                EmptyStateView(icon: "magnifyingglass", title: "没有找到相关结果")
                    .frame(minHeight: 300)
            }
        case .songs:
            TrackListView(tracks: model.songs)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        case .playlists:
            CardGrid {
                playlistCards(model.playlists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private func playlistCards(_ items: some Collection<LXPlaylistSummary>) -> some View {
        ForEach(Array(items)) { playlist in
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
    }
}
