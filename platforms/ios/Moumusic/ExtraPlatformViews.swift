import SwiftUI

/// 酷我 / 咪咕 的主页内容：榜单、热门搜索、推荐歌单。点开后在半屏列表里播放。
struct ExtraPlatformHomeSection: View {
    let provider: SongSource

    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore

    @State private var playlists: [Playlist] = []
    @State private var hotKeywords: [String] = []
    @State private var loadingPlaylists = false
    @State private var errorText: String?
    @State private var presented: PresentedList?

    private struct PresentedList: Identifiable {
        let id = UUID()
        let title: String
        let loader: () async throws -> [Song]
    }

    private var charts: [ExtraChart] { ExtraPlatforms.charts(for: provider) }
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "排行榜")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(charts) { chart in
                            Button {
                                BeansHaptics.tap()
                                presented = PresentedList(title: chart.name) { try await ExtraPlatforms.chartSongs(chart) }
                            } label: {
                                Text(chart.name)
                                    .font(BeansFont.appFont(13, .semibold))
                                    .foregroundStyle(Color.beansLabel)
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .background { BeansGlass(shape: Capsule()) }
                            }
                            .buttonStyle(GlassPressButtonStyle(scale: 0.95))
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }

            if !hotKeywords.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "\(beansPlatformName(searchProvider))热搜")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(hotKeywords.prefix(20).enumerated()), id: \.offset) { index, word in
                                Button {
                                    BeansHaptics.tap()
                                    presented = PresentedList(title: word) { try await ExtraPlatforms.search(provider, keyword: word, limit: 30) }
                                } label: {
                                    Text("\(index + 1)  \(word)")
                                        .font(BeansFont.appFont(12, .medium))
                                        .foregroundStyle(Color.beansLabel)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(Color.beansLabel.opacity(0.06), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "推荐歌单")
                if loadingPlaylists && playlists.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                } else if playlists.isEmpty {
                    Text(errorText ?? "\(beansPlatformName(searchProvider))歌单暂时没有内容")
                        .font(BeansFont.appFont(13)).foregroundStyle(Color.beansComment)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(playlists.prefix(30)) { playlist in
                            Button {
                                BeansHaptics.tap()
                                presented = PresentedList(title: playlist.name) { try await ExtraPlatforms.playlistSongs(playlist) }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    CoverImage(url: playlist.coverURL, size: 104, cornerRadius: 14)
                                    Text(playlist.name)
                                        .font(BeansFont.appFont(12, .medium))
                                        .foregroundStyle(Color.beansLabel)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(width: 104, alignment: .leading)
                                }
                            }
                            .buttonStyle(GlassPressButtonStyle(scale: 0.96))
                        }
                    }
                }
            }
        }
        .task(id: provider.rawValue) { await load() }
        .sheet(item: $presented) { item in
            ExtraSongListSheet(title: item.title, loader: item.loader)
                .environmentObject(theme)
                .environmentObject(player)
                .environmentObject(auth)
        }
    }

    private var searchProvider: SearchProvider { provider == .migu ? .migu : .kuwo }

    @MainActor
    private func load() async {
        loadingPlaylists = true
        errorText = nil
        defer { loadingPlaylists = false }
        async let keywords = ExtraPlatforms.hotKeywords(for: provider)
        do {
            playlists = try await ExtraPlatforms.recommendedPlaylists(for: provider)
        } catch {
            playlists = []
            errorText = "歌单加载失败：下拉刷新可重试"
        }
        hotKeywords = await keywords
    }
}

/// 歌曲列表半屏：加载 → 点击播放整个列表。
struct ExtraSongListSheet: View {
    let title: String
    let loader: () async throws -> [Song]

    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @State private var songs: [Song] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if loading {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                        } else if let errorText {
                            Text(errorText).font(BeansFont.appFont(13)).foregroundStyle(Color.beansComment).padding(.top, 40)
                        } else if songs.isEmpty {
                            Text("没有找到歌曲").font(BeansFont.appFont(13)).foregroundStyle(Color.beansComment).padding(.top, 40)
                        }
                        ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                            SongCell(song: song, glassRow: true) {
                                player.play(songs: songs, startAt: index)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 120)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .batchDownloadToolbar(songs: songs, title: title)
        }
        .task {
            do {
                songs = try await loader()
                errorText = nil
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? "加载失败，请稍后重试"
            }
            loading = false
        }
    }
}
