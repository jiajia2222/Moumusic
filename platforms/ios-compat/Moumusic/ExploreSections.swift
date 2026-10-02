import SwiftUI

/// 网易云主页的「新碟上架」与「歌手」板块；点击进入专辑详情 / 歌手主页。
@MainActor
struct NetEaseExploreSections: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore

    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var selectedAlbum: Album?
    @State private var selectedArtist: Artist?
    @ObservedObject private var favoriteArtists = FavoriteArtistsStore.shared

    private static var cache: (date: Date, albums: [Album], artists: [Artist])?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !albums.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "新碟上架")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(albums) { album in
                                Button {
                                    BeansHaptics.tap()
                                    selectedAlbum = album
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CoverImage(url: album.coverURL, size: 130, cornerRadius: 14)
                                        Text(album.name)
                                            .font(BeansFont.appFont(13, .semibold))
                                            .foregroundStyle(Color.beansLabel)
                                            .lineLimit(1)
                                        Text(album.artistName)
                                            .font(BeansFont.appFont(11))
                                            .foregroundStyle(Color.beansComment)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 130, alignment: .leading)
                                }
                                .buttonStyle(GlassPressButtonStyle(scale: 0.96))
                            }
                        }
                    }
                }
            }
            if !favoriteArtists.items.isEmpty {
                artistRow(title: "收藏歌手", list: favoriteArtists.artists)
            }
            if !artists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "歌手")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 16) {
                            ForEach(artists) { artist in
                                Button {
                                    BeansHaptics.tap()
                                    selectedArtist = artist
                                } label: {
                                    VStack(spacing: 6) {
                                        CoverImage(url: artist.coverURL, size: 76, cornerRadius: 38)
                                        Text(artist.name)
                                            .font(BeansFont.appFont(12, .medium))
                                            .foregroundStyle(Color.beansLabel)
                                            .lineLimit(1)
                                            .frame(width: 80)
                                    }
                                }
                                .buttonStyle(GlassPressButtonStyle(scale: 0.95))
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
                .environmentObject(player)
                .environmentObject(auth)
                .environmentObject(theme)
        }
        .sheet(item: $selectedArtist) { artist in
            ArtistHomeSheet(artist: artist)
                .environmentObject(player)
                .environmentObject(auth)
                .environmentObject(theme)
        }
    }

    private func artistRow(title: String, list: [Artist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(list) { artist in
                        Button {
                            BeansHaptics.tap()
                            selectedArtist = artist
                        } label: {
                            VStack(spacing: 6) {
                                CoverImage(url: artist.coverURL, size: 76, cornerRadius: 38)
                                Text(artist.name)
                                    .font(BeansFont.appFont(12, .medium))
                                    .foregroundStyle(Color.beansLabel)
                                    .lineLimit(1)
                                    .frame(width: 80)
                            }
                        }
                        .buttonStyle(GlassPressButtonStyle(scale: 0.95))
                    }
                }
            }
        }
    }

    private func load() async {
        if let cache = Self.cache, Date().timeIntervalSince(cache.date) < 1800 {
            albums = cache.albums
            artists = cache.artists
            return
        }
        async let a = try? NetEaseAPI.shared.newAlbums(limit: 12)
        async let b = try? NetEaseAPI.shared.topArtists(limit: 18)
        let loadedAlbums = await a ?? []
        let loadedArtists = await b ?? []
        albums = loadedAlbums
        artists = loadedArtists
        if !loadedAlbums.isEmpty || !loadedArtists.isEmpty {
            Self.cache = (Date(), loadedAlbums, loadedArtists)
        }
    }
}
