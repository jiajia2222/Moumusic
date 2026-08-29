import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case all
        case songs
        case artists
        case albums
        case playlists

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .all: return "??"
            case .songs: return "??"
            case .artists: return "??"
            case .albums: return "??"
            case .playlists: return "??"
            }
        }
    }

    var query: String
    @Published var tab: Tab = .all
    @Published var songs: [Track] = []
    @Published var artists: [ArtistSummary] = []
    @Published var albums: [AlbumSummary] = []
    @Published var playlists: [PlaylistSummary] = []
    @Published var isLoading = false
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
        artists = []
        albums = []
        playlists = []
    }

    func setPlatform(_ newPlatform: LXCatalogPlatform) {
        guard newPlatform != platform else { return }
        platform = newPlatform
        loadedTabs.remove(.all)
        loadedTabs.remove(.songs)
        songs = []
    }

    func load(tab: Tab) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !loadedTabs.contains(tab) else { return }
        isLoading = true
        defer { isLoading = false }
        loadedTabs.insert(tab)

        switch tab {
        case .all:
            async let songsTask = try? LXCatalogService.search(trimmed, platform: platform, limit: 12)
            async let artistsTask = try? NeteaseAPI.search(trimmed, type: .artists, limit: 10)
            async let albumsTask = try? NeteaseAPI.search(trimmed, type: .albums, limit: 10)
            async let playlistsTask = try? NeteaseAPI.search(trimmed, type: .playlists, limit: 10)
            songs = await songsTask ?? []
            artists = (await artistsTask)?.artists ?? []
            albums = (await albumsTask)?.albums ?? []
            playlists = (await playlistsTask)?.playlists ?? []
        case .songs:
            songs = (try? await LXCatalogService.search(trimmed, platform: platform, limit: 100)) ?? songs
        case .artists:
            artists = (try? await NeteaseAPI.search(trimmed, type: .artists, limit: 50))?.artists ?? artists
        case .albums:
            albums = (try? await NeteaseAPI.search(trimmed, type: .albums, limit: 50))?.albums ?? albums
        case .playlists:
            playlists = (try? await NeteaseAPI.search(trimmed, type: .playlists, limit: 50))?.playlists ?? playlists
        }
    }
}

struct SearchView: View {
    let initialQuery: String

    @StateObject private var model: SearchViewModel
    @State private var searchText: String = ""
    @EnvironmentObject private var player: PlayerService

    init(query: String) {
        self.initialQuery = query
        _model = StateObject(wrappedValue: SearchViewModel(query: query))
        _searchText = State(initialValue: query)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    platformPicker

                    Picker("", selection: $model.tab) {
                        ForEach(SearchViewModel.Tab.allCases) { tab in
                            Text(tab.displayName).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, Theme.Layout.contentInset)
                    .padding(.top, 12)

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
        }
        .searchable(text: $searchText, prompt: "?????????????")
        .onSubmit(of: .search) {
            model.setQuery(searchText)
            Task { await model.load(tab: model.tab) }
        }
        .onChange(of: searchText) { newValue in
            model.setQuery(newValue)
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if searchText == newValue {
                    await model.load(tab: model.tab)
                }
            }
        }
        .navigationTitle(searchText.isEmpty ? "??" : String(localized: "???\(searchText)"))
        .task(id: "\(model.tab.rawValue)-\(model.platform.rawValue)") {
            await model.load(tab: model.tab)
        }
    }

    private var platformPicker: some View {
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
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
        .padding(.top, 12)
    }

    private var emptySearchPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 60)
            Text("?????????????")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("????????????????????")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var currentEmpty: Bool {
        switch model.tab {
        case .all: return model.songs.isEmpty && model.artists.isEmpty
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
                    SectionHeader(title: "??") {
                        model.tab = .songs
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                    TrackListView(tracks: Array(model.songs.prefix(6)))
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
            }
            if !model.artists.isEmpty {
                Shelf(title: "??", seeAll: { model.tab = .artists }) {
                    artistCards(model.artists.prefix(8))
                }
            }
            if !model.albums.isEmpty {
                Shelf(title: "??", seeAll: { model.tab = .albums }) {
                    albumCards(model.albums.prefix(8))
                }
            }
            if !model.playlists.isEmpty {
                Shelf(title: "??", seeAll: { model.tab = .playlists }) {
                    playlistCards(model.playlists.prefix(8))
                }
            }
            if currentEmpty, !model.isLoading {
                EmptyStateView(icon: "magnifyingglass", title: "????????")
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

    private func artistCards(_ items: some Collection<ArtistSummary>) -> some View {
        ForEach(Array(items)) { artist in
            NavigationLink {
                ArtistDetailView(artistID: artist.id)
            } label: {
                VStack(spacing: 10) {
                    CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                        .frame(width: 128, height: 128)
                        .clipShape(Circle())
                    Text(artist.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(width: 140)
            }
            .buttonStyle(.plain)
        }
    }

    private func albumCards(_ items: some Collection<AlbumSummary>) -> some View {
        ForEach(Array(items)) { album in
            NavigationLink {
                AlbumDetailView(albumID: album.id)
            } label: {
                CoverCardBody(
                    coverURL: album.picUrl?.resizedImageURL(384),
                    title: album.name,
                    subtitle: album.artistName
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func playlistCards(_ items: some Collection<PlaylistSummary>) -> some View {
        ForEach(Array(items)) { playlist in
            NavigationLink {
                PlaylistDetailView(playlistID: playlist.id)
            } label: {
                CoverCardBody(
                    coverURL: playlist.coverURL?.resizedImageURL(384),
                    title: playlist.name,
                    playCount: playlist.playCount
                )
            }
            .buttonStyle(.plain)
        }
    }
}
