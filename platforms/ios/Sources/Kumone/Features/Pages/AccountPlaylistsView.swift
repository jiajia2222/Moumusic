#if os(iOS)
import SwiftUI

/// Playlists of the signed-in Kugou and QQ Music accounts.
struct AccountPlaylistsView: View {
    @EnvironmentObject private var qqMusic: QQMusicSessionStore
    @EnvironmentObject private var kugou: KugouSessionStore

    @State private var kugouLists: [KugouAPI.CloudPlaylist] = []
    @State private var qqLists: [QQMusicAPI.AccountPlaylist] = []
    @State private var isLoading = false
    @State private var kugouError: String?
    @State private var qqError: String?

    var body: some View {
        List {
            if !kugou.isLoggedIn && !qqMusic.isLoggedIn {
                Text("登录酷狗音乐或 QQ 音乐后，这里会显示你的歌单。")
                    .foregroundStyle(.secondary)
            }
            if kugou.isLoggedIn {
                Section {
                    if let kugouError, kugouLists.isEmpty {
                        Text(kugouError).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(kugouLists) { list in
                        NavigationLink {
                            AccountPlaylistTracksView(title: list.name) {
                                let rows = try await KugouAPI.shared.cloudPlaylistSongs(
                                    id: list.id, cookie: kugou.cookie ?? "")
                                return rows.compactMap { Self.kugouTrack($0) }
                            }
                        } label: {
                            row(name: list.name, count: list.count, cover: list.coverURL)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        BrandIconView(name: "BrandKugou").frame(width: 20, height: 20)
                        Text("酷狗音乐")
                    }
                }
            }
            if qqMusic.isLoggedIn {
                Section {
                    if let qqError, qqLists.isEmpty {
                        Text(qqError).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(qqLists) { list in
                        NavigationLink {
                            AccountPlaylistTracksView(title: list.name) {
                                try await Self.qqTracks(of: list, cookie: qqMusic.cookie)
                            }
                        } label: {
                            row(name: list.name, count: list.count, cover: list.coverURL)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        BrandIconView(name: "BrandQQ").frame(width: 20, height: 20)
                        Text("QQ 音乐")
                    }
                }
            }
        }
        .navigationTitle("账号歌单")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && kugouLists.isEmpty && qqLists.isEmpty { ProgressView() }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(name: String, count: Int, cover: String?) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: cover?.resizedImageURL(160), animated: false) {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.semibold)).lineLimit(1)
                if count > 0 {
                    Text("\(count) 首").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if kugou.isLoggedIn, let cookie = await kugou.cookieWithDevice() {
            do {
                kugouLists = try await KugouAPI.shared.userPlaylists(cookie: cookie)
                kugouError = kugouLists.isEmpty ? "没有读取到歌单，详情见 设置 → 诊断日志" : nil
            } catch {
                kugouError = "酷狗歌单读取失败：\(error.localizedDescription)"
                DiagnosticLogStore.shared.append(level: .error, category: "Kugou", message: "云歌单读取失败", detail: "\(error)")
            }
        }
        if qqMusic.isLoggedIn, let cookie = qqMusic.cookie {
            do {
                qqLists = try await QQMusicAPI.shared.userPlaylists(cookie: cookie)
                qqError = qqLists.isEmpty ? "没有读取到歌单，详情见 设置 → 诊断日志" : nil
            } catch {
                qqError = "QQ 音乐歌单读取失败：\(error.localizedDescription)"
                DiagnosticLogStore.shared.append(level: .error, category: "QQ 音乐", message: "账号歌单读取失败", detail: "\(error)")
            }
        }
    }

    /// The songs of one of the account's own QQ playlists: asked as the signed-in user first (the public endpoint cannot read
    /// private lists such as "我喜欢"), the public one after that.
    static func qqTracks(of list: QQMusicAPI.AccountPlaylist, cookie: String?) async throws -> [Track] {
        if let cookie, !cookie.isEmpty {
            let own = await QQMusicAPI.shared.accountPlaylistTracks(cookie: cookie, id: list.id)
            if !own.isEmpty { return own }
        }
        return try await LXCatalogService.playlistDetail(source: .tx, id: list.id).tracks
    }

    /// Cloud-playlist rows name the song "歌手 - 歌名"; split it for the shared track parser.
    static func kugouTrack(_ raw: [String: Any]) -> Track? {
        var item = raw
        if item["songname"] == nil, let full = (raw["name"] ?? raw["filename"]) as? String {
            let parts = full.components(separatedBy: " - ")
            if parts.count >= 2 {
                item["singername"] = item["singername"] ?? parts[0]
                item["songname"] = parts.dropFirst().joined(separator: " - ")
            } else {
                item["songname"] = full
            }
        }
        if item["timelength"] == nil, let seconds = raw["timelen"] as? Int { item["timelength"] = seconds }
        return LXCatalogService.parseTrack(item, source: .kg)
    }
}

struct AccountPlaylistTracksView: View {
    let title: String
    let load: () async throws -> [Track]

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isSearching = false
    @State private var query = ""

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            } else if let errorMessage, tracks.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                if isSearching {
                    TrackSearchField(text: $query, isSearching: $isSearching)
                        .padding(.vertical, 8)
                }
                let shown = tracks.matching(query)
                if shown.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "没有匹配的歌曲", subtitle: "试试搜索歌曲名、歌手或专辑")
                        .frame(minHeight: 200)
                } else {
                    TrackListView(tracks: shown)
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .trackSearchButton(isSearching: $isSearching, text: $query)
        .task {
            do {
                tracks = try await load()
                if tracks.isEmpty { errorMessage = "这个歌单暂时读取不到歌曲" }
            } catch {
                errorMessage = "读取失败：\(error.localizedDescription)"
            }
            isLoading = false
        }
    }
}

/// "我的歌单" shelf shown at the top of a platform's own home page (Kugou / QQ Music).
struct PlatformAccountPlaylists: View {
    let platform: LXCatalogPlatform

    @EnvironmentObject private var qqMusic: QQMusicSessionStore
    @EnvironmentObject private var kugou: KugouSessionStore
    @State private var kugouLists: [KugouAPI.CloudPlaylist] = []
    @State private var qqLists: [QQMusicAPI.AccountPlaylist] = []
    @State private var showAll = false

    private var isLoggedIn: Bool {
        (platform == .kg && kugou.isLoggedIn) || (platform == .tx && qqMusic.isLoggedIn)
    }

    private var platformTitle: String { platform == .kg ? "酷狗音乐" : "QQ 音乐" }

    private var cloudSource: (key: String, name: String) {
        platform == .kg ? ("kugou", "酷狗音乐") : ("qq", "QQ 音乐")
    }

    private var cloudItems: [CloudPlaylistItem] {
        if platform == .kg {
            let cookie = kugou.cookie ?? ""
            return kugouLists.map { list in
                CloudPlaylistItem(id: list.id, name: list.name, coverURL: list.coverURL, count: list.count) {
                    let rows = try await KugouAPI.shared.cloudPlaylistSongs(id: list.id, cookie: cookie)
                    return rows.compactMap { AccountPlaylistsView.kugouTrack($0) }
                }
            }
        }
        return qqLists.map { list in
            CloudPlaylistItem(id: list.id, name: list.name, coverURL: list.coverURL, count: list.count) {
                try await LXCatalogService.playlistDetail(source: .tx, id: list.id).tracks
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if isLoggedIn, !(kugouLists.isEmpty && qqLists.isEmpty) {
                Shelf(title: "我的歌单", seeAll: { showAll = true }, rowHeight: Theme.Layout.coverShelfHeight) {
                    if platform == .kg {
                        ForEach(kugouLists) { list in kugouCard(list) }
                    } else {
                        ForEach(qqLists) { list in qqCard(list) }
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showAll) {
            ScrollView {
                PlatformCloudPlaylistsCard(source: cloudSource.key, sourceName: cloudSource.name, items: cloudItems)
                    .padding(.top, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .top)], spacing: 18) {
                    if platform == .kg {
                        ForEach(kugouLists) { list in kugouCard(list) }
                    } else {
                        ForEach(qqLists) { list in qqCard(list) }
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 8)
                PlayerClearanceSpacer()
            }
            .navigationTitle("\(platformTitle)歌单")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: "\(platform.rawValue)-\(kugou.sessionRevision)-\(qqMusic.sessionRevision)") {
            if platform == .kg, kugou.isLoggedIn, let cookie = await kugou.cookieWithDevice() {
                kugouLists = Self.unique((try? await KugouAPI.shared.userPlaylists(cookie: cookie)) ?? [], by: \.id)
            } else if platform == .tx, qqMusic.isLoggedIn, let cookie = qqMusic.cookie {
                qqLists = Self.unique((try? await QQMusicAPI.shared.userPlaylists(cookie: cookie)) ?? [], by: \.id)
            }
            // Keep playlists the user already added up to date every time the page opens.
            await CloudPlaylistSync.refreshMirrored(source: cloudSource.key, sourceName: cloudSource.name, items: cloudItems)
        }
    }

    /// Duplicate ids make lazy SwiftUI containers misbehave; keep the first of each.
    private static func unique<T>(_ items: [T], by key: KeyPath<T, String>) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert($0[keyPath: key]).inserted }
    }

    private func kugouCard(_ list: KugouAPI.CloudPlaylist) -> some View {
        NavigationLink {
            AccountPlaylistTracksView(title: list.name) {
                let rows = try await KugouAPI.shared.cloudPlaylistSongs(
                    id: list.id, cookie: kugou.cookie ?? "")
                return rows.compactMap { AccountPlaylistsView.kugouTrack($0) }
            }
        } label: {
            CoverCardBody(coverURL: list.coverURL?.resizedImageURL(384),
                          title: list.name, subtitle: "\(list.count) 首")
        }
        .buttonStyle(.plain)
    }

    private func qqCard(_ list: QQMusicAPI.AccountPlaylist) -> some View {
        NavigationLink {
            AccountPlaylistTracksView(title: list.name) {
                try await AccountPlaylistsView.qqTracks(of: list, cookie: qqMusic.cookie)
            }
        } label: {
            CoverCardBody(coverURL: list.coverURL?.resizedImageURL(384),
                          title: list.name, subtitle: "\(list.count) 首")
        }
        .buttonStyle(.plain)
    }
}#endif