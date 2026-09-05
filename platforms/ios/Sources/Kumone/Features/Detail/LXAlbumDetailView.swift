import SwiftUI

@MainActor
private final class LXAlbumDetailViewModel: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?

    func load(source: LXCatalogPlatform, albumID: String?, albumName: String,
              artistName: String, force: Bool = false) async {
        guard !isLoading, force || !hasLoaded else { return }
        if force { hasLoaded = false }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            tracks = try await LXCatalogService.albumTracks(
                source: source,
                albumID: albumID,
                name: albumName,
                artistName: artistName
            )
        } catch {
            tracks = []
            errorMessage = "暂时无法读取此平台的专辑歌曲"
        }
    }
}

/// Source-native album detail for Kuwo, KuGou, QQ and Migu. The source ID is
/// kept separate from NetEase's album integer so clicking an aggregate result
/// never sends a provider-specific ID to the wrong API.
struct LXAlbumDetailView: View {
    let source: LXCatalogPlatform
    let albumID: String?
    let albumName: String
    let artistName: String
    let coverURL: String?

    @StateObject private var model = LXAlbumDetailViewModel()
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                albumHeader

                if model.isLoading && !model.hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 280)
                } else if let errorMessage = model.errorMessage, model.tracks.isEmpty {
                    ErrorStateView(message: errorMessage) {
                        Task {
                            await model.load(source: source, albumID: albumID,
                                             albumName: albumName, artistName: artistName,
                                             force: true)
                        }
                    }
                    .frame(minHeight: 280)
                } else if model.tracks.isEmpty {
                    EmptyStateView(icon: "square.stack", title: "此专辑暂时没有歌曲")
                        .frame(minHeight: 280)
                } else {
                    HStack {
                        Text("歌曲")
                            .font(.headline)
                        Spacer()
                        Button {
                            player.play(tracks: model.tracks, source: .none,
                                        context: .recents)
                        } label: {
                            Label("播放全部", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)

                    TrackListView(tracks: model.tracks)
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }

                PlayerClearanceSpacer()
            }
            .padding(.vertical, Theme.Layout.contentInset)
        }
        .navigationTitle(albumName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(source.rawValue)-\(albumID ?? "")-\(albumName)-\(artistName)") {
            await model.load(source: source, albumID: albumID,
                             albumName: albumName, artistName: artistName)
        }
    }

    private var albumHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            CachedAsyncImage(url: coverURL?.resizedImageURL(512))
                .frame(width: 142, height: 142)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large,
                                             style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(albumName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                if !artistName.isEmpty {
                    Text(artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(source.displayName)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }
}
