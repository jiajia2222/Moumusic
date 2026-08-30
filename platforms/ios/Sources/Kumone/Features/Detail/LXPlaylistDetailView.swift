import SwiftUI

@MainActor
final class LXPlaylistDetailViewModel: ObservableObject {
    @Published private(set) var detail: LXPlaylistDetail?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func load(source: LXCatalogPlatform, playlistID: String) async {
        guard detail == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            detail = try await LXCatalogService.playlistDetail(source: source, id: playlistID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Detail page for an LX catalogue songlist. It never converts the ID to a
/// NetEase integer; the source and source-owned ID stay attached all the way
/// to the tracks and their User API resolver.
struct LXPlaylistDetailView: View {
    let source: LXCatalogPlatform
    let playlistID: String

    @StateObject private var model = LXPlaylistDetailViewModel()
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        ScrollView {
            if model.isLoading && model.detail == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else if let errorMessage = model.errorMessage, model.detail == nil {
                ErrorStateView(message: errorMessage) {
                    Task { await model.load(source: source, playlistID: playlistID) }
                }
                .frame(minHeight: 360)
            } else if let detail = model.detail {
                detailBody(detail)
            }
            PlayerClearanceSpacer()
        }
        .navigationTitle(model.detail?.name ?? "歌单")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load(source: source, playlistID: playlistID)
        }
    }

    private func detailBody(_ detail: LXPlaylistDetail) -> some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                CachedAsyncImage(url: detail.coverURL?.resizedImageURL(512))
                    .frame(width: 142, height: 142)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(3)
                    Text([detail.source.displayName, detail.author].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if detail.trackCount > 0 {
                        Text("\(detail.tracks.count) / \(detail.trackCount) 首")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Layout.contentInset)

            if let description = detail.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.horizontal, Theme.Layout.contentInset)
            }

            if detail.tracks.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "歌单暂无歌曲")
                    .frame(minHeight: 240)
            } else {
                HStack {
                    Text("歌曲")
                        .font(.headline)
                    Spacer()
                    Button {
                        player.play(tracks: detail.tracks, source: .none,
                                    context: .recents)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                }
                .padding(.horizontal, Theme.Layout.contentInset)

                TrackListView(tracks: detail.tracks)
                    .padding(.horizontal, Theme.Layout.contentInset - 10)
            }
        }
        .padding(.vertical, Theme.Layout.contentInset)
    }
}
