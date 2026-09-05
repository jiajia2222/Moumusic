import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()

    @Published private(set) var entries: [String]

    private let key = "moumusic.searchHistory.v1"
    private let limit = 12

    private init() {
        entries = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ value: String) {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        entries.removeAll { $0.localizedCaseInsensitiveCompare(query) == .orderedSame }
        entries.insert(query, at: 0)
        entries = Array(entries.prefix(limit))
        UserDefaults.standard.set(entries, forKey: key)
    }

    func remove(_ value: String) {
        entries.removeAll { $0 == value }
        UserDefaults.standard.set(entries, forKey: key)
    }

    func clear() {
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case all = "综合"
        case songs = "单曲"
        case artists = "歌手"
        case albums = "专辑"
        case playlists = "歌单"

        var id: String { rawValue }
    }

    struct ArtistResult: Hashable, Identifiable {
        let id: String
        let name: String
        let neteaseID: Int?
        var avatarURL: String?
    }

    struct AlbumResult: Hashable, Identifiable {
        let id: String
        let name: String
        let artistName: String
        let coverURL: String?
        let neteaseID: Int?
    }

    var query: String
    @Published var tab: Tab = .all
    @Published var songs: [Track] = []
    @Published var artists: [ArtistResult] = []
    @Published var albums: [AlbumResult] = []
    @Published var playlists: [LXPlaylistSummary] = []
    @Published var isLoading = false
    @Published var loadedTabs: Set<Tab> = []
    @Published var platform: LXCatalogPlatform = .aggregate
    private var artistAvatarCache: [String: String] = [:]

    init(query: String) {
        self.query = query
    }

    func setQuery(_ newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        loadedTabs.removeAll()
        songs = []
        artists = []
        albums = []
        playlists = []
    }

    func setPlatform(_ newPlatform: LXCatalogPlatform) {
        guard newPlatform != platform else { return }
        platform = newPlatform
        loadedTabs.removeAll()
        songs = []
        artists = []
        albums = []
        playlists = []
    }

    func load(tab: Tab, force: Bool = false) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, force || !loadedTabs.contains(tab) else { return }

        isLoading = true
        defer { isLoading = false }

        var didLoad = false
        switch tab {
        case .all:
            async let songsTask = try? LXCatalogService.search(trimmed, platform: platform, limit: 12)
            async let playlistsTask = try? LXCatalogService.searchSonglists(trimmed, platform: platform, limit: 12)
            if let result = await songsTask {
                songs = result
                rebuildMetadata(from: result)
                await enrichArtistAvatars()
                didLoad = true
            }
            if let result = await playlistsTask {
                playlists = result
                didLoad = true
            }
        case .songs:
            if let result = try? await LXCatalogService.search(trimmed, platform: platform, limit: 100) {
                songs = result
                rebuildMetadata(from: result)
                await enrichArtistAvatars()
                didLoad = true
            }
        case .artists:
            songs = (try? await LXCatalogService.search(trimmed, platform: platform, limit: 100)) ?? songs
            rebuildMetadata(from: songs)
            await enrichArtistAvatars()
            didLoad = true
        case .albums:
            songs = (try? await LXCatalogService.search(trimmed, platform: platform, limit: 100)) ?? songs
            rebuildMetadata(from: songs)
            await enrichArtistAvatars()
            didLoad = true
        case .playlists:
            if let result = try? await LXCatalogService.searchSonglists(trimmed, platform: platform, limit: 100) {
                playlists = result
                didLoad = true
            }
        }

        if didLoad { loadedTabs.insert(tab) }
    }

    private func rebuildMetadata(from tracks: [Track]) {
        var artistResults: [ArtistResult] = []
        var albumResults: [AlbumResult] = []
        var seenArtists = Set<String>()
        var seenAlbums = Set<String>()

        for track in tracks {
            for artist in track.artists {
                let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let key = name.localizedLowercase
                if seenArtists.insert(key).inserted {
                    artistResults.append(ArtistResult(
                        id: key,
                        name: name,
                        neteaseID: artist.id > 0 && platform == .wy ? artist.id : nil,
                        avatarURL: artist.picUrl
                    ))
                } else if let avatarURL = artist.picUrl,
                          let index = artistResults.firstIndex(where: { $0.id == key }),
                          artistResults[index].avatarURL == nil {
                    artistResults[index].avatarURL = avatarURL
                }
            }

            let albumName = track.album.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !albumName.isEmpty else { continue }
            let albumKey = "\(albumName.localizedLowercase)|\(track.artistNames.localizedLowercase)"
            guard seenAlbums.insert(albumKey).inserted else { continue }
            albumResults.append(AlbumResult(
                id: albumKey,
                name: albumName,
                artistName: track.artistNames,
                coverURL: track.album.picUrl,
                neteaseID: track.album.id > 0 && platform == .wy ? track.album.id : nil
            ))
        }

        artists = artistResults
        albums = albumResults
    }

    /// LX search results do not consistently include artist artwork. Enrich
    /// only the visible artist cards with public NetEase artist metadata. The
    /// selected catalogue still owns the actual song and playback results.
    private func enrichArtistAvatars() async {
        let targets = artists.compactMap { artist -> (String, Int?)? in
            guard artist.avatarURL == nil, artistAvatarCache[artist.id] == nil else { return nil }
            return (artist.id, artist.neteaseID)
        }
        guard !targets.isEmpty else {
            applyCachedArtistAvatars()
            return
        }

        let responses = await withTaskGroup(of: (String, String?).self, returning: [(String, String?)].self) { group in
            for (key, neteaseID) in targets.prefix(8) {
                group.addTask {
                    if let neteaseID, neteaseID > 0 {
                        let response = try? await NeteaseAPI.artist(id: neteaseID)
                        return (key, response?.artist.picUrl)
                    }

                    // Non-NetEase LX sources expose artist names but often
                    // omit a portrait. Resolve only the metadata card, never
                    // the track itself, so the chosen source remains intact.
                    let result = try? await NeteaseAPI.search(key, type: .artists, limit: 5)
                    let match = result?.artists?.first {
                        $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame
                    } ?? result?.artists?.first
                    return (key, match?.picUrl)
                }
            }

            var values: [(String, String?)] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        for (key, avatarURL) in responses {
            if let avatarURL, !avatarURL.isEmpty {
                artistAvatarCache[key] = avatarURL
            }
        }
        applyCachedArtistAvatars()
    }

    private func applyCachedArtistAvatars() {
        artists = artists.map { artist in
            var updated = artist
            if let avatarURL = artistAvatarCache[artist.id] {
                updated.avatarURL = avatarURL
            }
            return updated
        }
    }
}

struct SearchView: View {
    @StateObject private var model: SearchViewModel
    @StateObject private var history = SearchHistoryStore.shared
    @State private var searchText: String = ""

    init(query: String) {
        _model = StateObject(wrappedValue: SearchViewModel(query: query))
        _searchText = State(initialValue: query)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                }
                PlayerClearanceSpacer()
            }
            .padding(.top, 8)
        }
        // On iOS 26 this searchable modifier is rendered by the system search
        // tab as the bottom Liquid Glass capsule shown in Kumone. Older iOS
        // versions get the normal native navigation search presentation.
        .searchable(text: $searchText, placement: .automatic,
                    prompt: "搜索歌曲、歌手、专辑、歌单")
        .onSubmit(of: .search) {
            submitSearchAfterInputMethodCommits()
        }
        .onChange(of: searchText) { newValue in
            model.setQuery(newValue)
        }
        .navigationTitle(searchText.isEmpty ? "搜索" : searchText)
        .task(id: "\(model.tab.rawValue)-\(model.platform.rawValue)") {
            await model.load(tab: model.tab)
        }
        .onDisappear {
            resignSearchInput()
        }
    }

    private func performSearch(_ submittedText: String? = nil) {
        let query = (submittedText ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchText = query
        history.add(query)
        model.setQuery(query)
        Task { await model.load(tab: model.tab, force: true) }
    }

    /// Some third-party IMEs submit before SwiftUI has copied marked text into
    /// the binding. Waiting one main-loop turn lets Chinese composition commit.
    private func submitSearchAfterInputMethodCommits() {
        Task { @MainActor in
            await Task.yield()
            performSearch()
        }
    }

    private var tabPicker: some View {
        Picker("搜索类型", selection: $model.tab) {
            ForEach(SearchViewModel.Tab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private var platformPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("搜索平台")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.platform.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, Theme.Layout.contentInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LXCatalogPlatform.allCases) { platform in
                        Button {
                            model.setPlatform(platform)
                            resignSearchInput()
                        } label: {
                            HStack(spacing: 5) {
                                if model.platform == platform {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                }
                                Text(platform.displayName)
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(model.platform == platform ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                model.platform == platform
                                    ? Theme.accent
                                    : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
        }
    }

    private var emptySearchPrompt: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 44)
                Text("搜索歌曲、歌手、专辑或歌单")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("使用底部搜索框开始，聚合搜索也可以切换到单个平台。")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            if !history.entries.isEmpty {
                HStack {
                    Label("搜索历史", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Spacer()
                    Button("清空") { history.clear() }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                    ForEach(history.entries, id: \.self) { item in
                        HStack(spacing: 6) {
                            Button {
                                searchText = item
                                performSearch(item)
                            } label: {
                                Text(item)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)

                            Button {
                                history.remove(item)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除搜索记录")
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(.quaternary.opacity(0.45), in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private var currentEmpty: Bool {
        switch model.tab {
        case .all: return model.songs.isEmpty && model.artists.isEmpty && model.albums.isEmpty && model.playlists.isEmpty
        case .songs: return model.songs.isEmpty
        case .artists: return model.artists.isEmpty
        case .albums: return model.albums.isEmpty
        case .playlists: return model.playlists.isEmpty
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .all:
            if !model.songs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "单曲") { model.tab = .songs }
                        .padding(.horizontal, Theme.Layout.contentInset)
                    TrackListView(tracks: Array(model.songs.prefix(6)))
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
            }
            if !model.artists.isEmpty {
                Shelf(title: "歌手", seeAll: { model.tab = .artists }) {
                    artistCards(model.artists.prefix(8))
                }
            }
            if !model.albums.isEmpty {
                Shelf(title: "专辑", seeAll: { model.tab = .albums }) {
                    albumCards(model.albums.prefix(8))
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
        case .artists:
            CardGrid(minWidth: 140) {
                artistCards(model.artists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .albums:
            CardGrid {
                albumCards(model.albums)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .playlists:
            CardGrid {
                playlistCards(model.playlists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private func artistCards(_ items: some Collection<SearchViewModel.ArtistResult>) -> some View {
        ForEach(Array(items)) { artist in
            if let neteaseID = artist.neteaseID {
                NavigationLink(value: Destination.artist(neteaseID)) {
                    artistCard(artist)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    model.tab = .songs
                    searchText = artist.name
                    performSearch(artist.name)
                } label: {
                    artistCard(artist)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func artistCard(_ artist: SearchViewModel.ArtistResult) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.quaternary.opacity(0.35))
                if let url = artist.avatarURL?.resizedImageURL(384) {
                    CachedAsyncImage(url: url) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 52, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
                .frame(width: 128, height: 128)
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
            Text(artist.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: 140)
        .contentShape(Rectangle())
    }

    private func resignSearchInput() {
        #if os(iOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
        #endif
    }

    private func albumCards(_ items: some Collection<SearchViewModel.AlbumResult>) -> some View {
        ForEach(Array(items)) { album in
            if let neteaseID = album.neteaseID {
                NavigationLink(value: Destination.album(neteaseID)) {
                    albumCard(album)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    model.tab = .songs
                    searchText = album.name
                    performSearch(album.name)
                } label: {
                    albumCard(album)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func albumCard(_ album: SearchViewModel.AlbumResult) -> some View {
        CoverCardBody(
            coverURL: album.coverURL?.resizedImageURL(384),
            title: album.name,
            subtitle: album.artistName
        )
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

private struct SearchSkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .frame(width: 44, height: 44)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .frame(height: 14)
            Spacer()
        }
        .redacted(reason: .placeholder)
        .frame(maxWidth: .infinity, minHeight: 50)
    }
}
