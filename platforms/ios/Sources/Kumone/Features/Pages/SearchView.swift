import SwiftUI

/// Search is intentionally local in source-only mode. LX User API exposes
/// playback, lyric, and artwork actions; it is not a catalogue/search API.
struct SearchView: View {
    private struct Match: Identifiable {
        let playlist: LocalPlaylist
        let track: Track
        let index: Int

        var id: String { "\(playlist.id.uuidString)-\(index)" }
    }

    let initialQuery: String
    @State private var searchText: String
    @FocusState private var searchFocused: Bool
    @StateObject private var playlists = LocalPlaylistStore.shared
    @EnvironmentObject private var player: PlayerService

    init(query: String) {
        initialQuery = query
        _searchText = State(initialValue: query)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchBar

                if query.isEmpty {
                    emptyPrompt
                } else if matches.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "本地歌单中没有匹配歌曲",
                        subtitle: "导入歌单后，可按歌名、歌手、专辑或歌单名称搜索。"
                    )
                    .frame(minHeight: 320)
                } else {
                    Text("本地歌曲 · \(matches.count) 首")
                        .font(.headline)
                        .padding(.horizontal, Theme.Layout.contentInset)
                    LazyVStack(spacing: 0) {
                        ForEach(matches) { match in
                            Button {
                                player.play(tracks: match.playlist.tracks, source: .none, startAt: match.track)
                            } label: {
                                songRow(match)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                }

                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("搜索")
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matches: [Match] {
        guard !query.isEmpty else { return [] }
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return playlists.playlists.flatMap { playlist in
            playlist.tracks.enumerated().compactMap { index, track in
                let haystack = [track.name, track.artistNames, track.album.name, playlist.name]
                    .joined(separator: " ")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return haystack.contains(needle) ? Match(playlist: playlist, track: track, index: index) : nil
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索本地歌曲、歌手或歌单", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .submitLabel(.search)
                .accessibilityLabel("搜索本地歌曲")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, 12)
    }

    private var emptyPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 44)
            Text("搜索本地歌单")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("此页面不会访问网易云或其他软件预置音乐接口。")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private func songRow(_ match: Match) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(match.track.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text([match.track.artistNames, match.playlist.name].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "play.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 44)
        }
        .contentShape(Rectangle())
    }
}
