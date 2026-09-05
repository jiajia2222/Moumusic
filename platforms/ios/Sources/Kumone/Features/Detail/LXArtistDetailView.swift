import SwiftUI

@MainActor
private final class LXArtistDetailViewModel: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?

    func load(source: LXCatalogPlatform, artistName: String) async {
        guard !isLoading else { return }
        isLoading = true
        hasLoaded = false
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            let results = try await LXCatalogService.search(artistName, platform: source, limit: 100)
            let target = Self.normalized(artistName)
            let exactMatches = results.filter { track in
                track.artists.contains { artist in
                    let value = Self.normalized(artist.name)
                    return value == target || value.contains(target) || target.contains(value)
                }
            }
            if !exactMatches.isEmpty {
                tracks = exactMatches
            } else {
                // QQ/KuGou/Kuwo sometimes return artist aliases or omit the
                // artist field on part of a valid result. Keeping the
                // provider-ranked response is preferable to a blank artist
                // page, and it still stays inside the selected source.
                let relevantMatches = results.filter { track in
                    let searchable = Self.normalized("\(track.name) \(track.artistNames)")
                    return !target.isEmpty && searchable.contains(target)
                }
                tracks = relevantMatches.isEmpty ? results : relevantMatches
            }
        } catch {
            tracks = []
            errorMessage = "暂时无法读取该音源的歌手歌曲"
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { !$0.isWhitespace }
    }
}

/// Source-native artist results. Unlike the NetEase artist page, this view
/// keeps the selected LX catalogue attached to both search and playback.
struct LXArtistDetailView: View {
    let source: LXCatalogPlatform
    let artistName: String
    let avatarURL: String?

    @StateObject private var model = LXArtistDetailViewModel()
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                artistHeader

                if model.isLoading && !model.hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 280)
                } else if let errorMessage = model.errorMessage, model.tracks.isEmpty {
                    ErrorStateView(message: errorMessage) {
                        Task { await model.load(source: source, artistName: artistName) }
                    }
                    .frame(minHeight: 280)
                } else if model.tracks.isEmpty {
                    EmptyStateView(icon: "person.crop.circle", title: "该音源没有返回此歌手的歌曲")
                        .frame(minHeight: 280)
                } else {
                    HStack {
                        Text("歌曲")
                            .font(.headline)
                        Spacer()
                        Button {
                            player.play(tracks: model.tracks, source: .none)
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
        .navigationTitle(artistName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(source.rawValue)-\(artistName)") {
            await model.load(source: source, artistName: artistName)
        }
    }

    private var artistHeader: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(url: avatarURL?.resizedImageURL(384)) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 92, height: 92)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 1))

            VStack(alignment: .leading, spacing: 6) {
                Text(artistName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(source.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }
}
