import SwiftUI

/// Provider subscriptions remain in the first two tabs. The saved tab is a
/// local Beans-style collection shelf and works for both remote and imported
/// LX collections without requiring an account.
struct CollectionsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case albums = "专辑"
        case artists = "歌手"
        case saved = "收藏"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .saved
    @State private var isLoading = true

    @EnvironmentObject private var account: AccountStore
    @StateObject private var favorites = FavoritesStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("收藏内容", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if isLoading, tab != .saved,
                   account.likedAlbums.isEmpty, account.likedArtists.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    switch tab {
                    case .albums:
                        subscribedAlbums
                    case .artists:
                        followedArtists
                    case .saved:
                        savedCollections
                    }
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("我的收藏")
        .task {
            await account.refreshSublists()
            isLoading = false
        }
    }

    @ViewBuilder
    private var subscribedAlbums: some View {
        if account.likedAlbums.isEmpty {
            EmptyStateView(icon: "square.stack", title: "还没有收藏专辑")
                .frame(minHeight: 300)
        } else {
            CardGrid {
                ForEach(account.likedAlbums) { album in
                    NavigationLink(value: Destination.album(album.id)) {
                        CoverCardBody(
                            coverURL: album.picUrl?.resizedImageURL(384),
                            title: album.name,
                            subtitle: album.artistName
                        )
                    }
                    .buttonStyle(.interactiveCard)
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    @ViewBuilder
    private var followedArtists: some View {
        if account.likedArtists.isEmpty {
            EmptyStateView(icon: "music.microphone", title: "还没有关注歌手")
                .frame(minHeight: 300)
        } else {
            CardGrid(minWidth: 140) {
                ForEach(account.likedArtists) { artist in
                    NavigationLink(value: Destination.artist(artist.id)) {
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.interactiveCard)
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    @ViewBuilder
    private var savedCollections: some View {
        if favorites.items.isEmpty && favorites.tracks.isEmpty {
            EmptyStateView(icon: "heart", title: "还没有收藏内容")
                .frame(minHeight: 300)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if !favorites.tracks.isEmpty {
                    Text("红心歌曲")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, Theme.Layout.contentInset)

                    TrackListView(
                        tracks: favorites.tracks,
                        source: .none,
                        context: .recents
                    )
                    .padding(.horizontal, Theme.Layout.contentInset - 10)
                }

                if !favorites.items.isEmpty {
                    Text("收藏的歌单与专辑")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, Theme.Layout.contentInset)

                    LazyVStack(spacing: 10) {
                        ForEach(favorites.items) { item in
                            if let destination = destination(for: item) {
                                NavigationLink(value: destination) {
                                    savedCollectionRow(item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                }
            }
        }
    }

    private func savedCollectionRow(_ item: FavoriteCollection) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: item.coverURL?.resizedImageURL(160))
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text([item.kind.displayName, item.subtitle, sourceName(item.source)]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }

    private func sourceName(_ source: String) -> String? {
        guard let platform = LXCatalogPlatform(rawValue: source) else {
            return source == "wy" ? "网易云" : nil
        }
        return platform.displayName
    }

    private func destination(for item: FavoriteCollection) -> Destination? {
        switch item.kind {
        case .playlist:
            if item.source == "wy", let id = Int(item.providerID) {
                return .playlist(id)
            }
            guard let source = LXCatalogPlatform(rawValue: item.source) else { return nil }
            return .lxPlaylist(source: source, id: item.providerID)
        case .album:
            if item.source == "wy", let id = Int(item.providerID) {
                return .album(id)
            }
            guard let source = LXCatalogPlatform(rawValue: item.source) else { return nil }
            let parts = item.subtitle?.split(separator: "|", maxSplits: 1).map(String.init) ?? []
            let artist = parts.first ?? item.subtitle ?? ""
            let id = item.providerID.hasPrefix("name:") ? nil : item.providerID
            return .lxAlbum(source: source, id: id, name: item.name,
                            artistName: artist, coverURL: item.coverURL)
        }
    }
}
