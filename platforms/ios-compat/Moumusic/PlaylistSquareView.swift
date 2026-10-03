import SwiftUI

/// 歌单搜索（网易云 / QQ 音乐 / 酷狗）：使用各平台公开的网页搜索接口。
enum PlaylistSearchAPI {
    static func search(_ provider: SearchProvider, keyword: String) async throws -> [Playlist] {
        switch provider {
        case .netease: return try await netease(keyword)
        case .qq: return try await qq(keyword)
        case .kugou: return try await kugou(keyword)
        case .kuwo, .migu, .bilibili: return []
        }
    }

    private static func netease(_ keyword: String) async throws -> [Playlist] {
        let url = "https://music.163.com/api/search/get/web?csrf_token=&s=\(ExtraHTTP.encode(keyword))&type=1000&offset=0&limit=30"
        let headers = ["Referer": "https://music.163.com/", "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"]
        guard let root = try await ExtraHTTP.json(url, headers: headers) as? [String: Any],
              let result = root["result"] as? [String: Any] else { return [] }
        let list = result["playlists"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? Int else { return nil }
            return Playlist(id: id, name: ExtraHTTP.string(item["name"]),
                            coverURL: URL(string: ExtraHTTP.string(item["coverImgUrl"])),
                            trackCount: Int(ExtraHTTP.double(item["trackCount"])), source: .netease)
        }
    }

    private static func qqMusicu(_ keyword: String) async -> [Playlist] {
        let payload: [String: Any] = [
            "comm": ["ct": 19, "cv": 1859, "uin": "0"],
            "req": ["method": "DoSearchForQQMusicDesktop", "module": "music.search.SearchCgiService",
                    "param": ["grp": 1, "num_per_page": 30, "page_num": 1, "query": keyword, "search_type": 3]]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let endpoint = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return [] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("https://y.qq.com", forHTTPHeaderField: "Origin")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let req = root["req"] as? [String: Any],
              let payloadData = req["data"] as? [String: Any],
              let bodyObject = payloadData["body"] as? [String: Any],
              let songlist = bodyObject["songlist"] as? [String: Any],
              let items = songlist["list"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = Int(ExtraHTTP.string(item["dissid"])) else { return nil }
            return Playlist(id: id, name: ExtraHTTP.decodeName(ExtraHTTP.string(item["dissname"])),
                            coverURL: URL(string: ExtraHTTP.string(item["imgurl"])),
                            trackCount: Int(ExtraHTTP.double(item["song_count"])), source: .qq)
        }
    }

    private static func qq(_ keyword: String) async throws -> [Playlist] {
        let modern = await qqMusicu(keyword)
        if !modern.isEmpty { return modern }
        let url = "https://c.y.qq.com/soso/fcgi-bin/client_music_search_songlist?remoteplace=txt.yqq.playlist&page_no=0&num_per_page=30&query=\(ExtraHTTP.encode(keyword))&format=json&inCharset=utf8&outCharset=utf-8&platform=yqq.json&needNewCode=0"
        let headers = ["Referer": "https://y.qq.com/", "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"]
        guard let root = try await ExtraHTTP.json(url, headers: headers) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let list = data["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let rawID = ExtraHTTP.string(item["dissid"])
            guard let id = Int(rawID) else { return nil }
            return Playlist(id: id, name: ExtraHTTP.decodeName(ExtraHTTP.string(item["dissname"])),
                            coverURL: URL(string: ExtraHTTP.string(item["imgurl"])),
                            trackCount: Int(ExtraHTTP.double(item["song_count"])), source: .qq)
        }
    }

    private static func kugou(_ keyword: String) async throws -> [Playlist] {
        let url = "https://msearchretry.kugou.com/api/v3/search/special?keyword=\(ExtraHTTP.encode(keyword))&page=1&pagesize=30&filter=0&version=7910&plat=0"
        guard let root = try await ExtraHTTP.json(url) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let list = data["info"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let rawID = ExtraHTTP.string(item["specialid"])
            guard let id = Int(rawID) else { return nil }
            let cover = ExtraHTTP.string(item["imgurl"]).replacingOccurrences(of: "{size}", with: "400")
            return Playlist(id: id, name: ExtraHTTP.string(item["specialname"]),
                            coverURL: URL(string: cover),
                            trackCount: Int(ExtraHTTP.double(item["songcount"])), source: .kugou)
        }
    }
}

/// 歌单广场缓存：切换平台 / 分类时先展示旧内容。
final class PlaylistSquareCache {
    static let shared = PlaylistSquareCache()
    private var store: [String: (date: Date, list: [Playlist])] = [:]
    private let ttl: TimeInterval = 15 * 60

    func list(for key: String) -> [Playlist]? {
        guard let entry = store[key], Date().timeIntervalSince(entry.date) < ttl else { return nil }
        return entry.list
    }

    func save(_ list: [Playlist], for key: String) {
        guard !list.isEmpty else { return }
        store[key] = (Date(), list)
    }

    func removeAll() { store.removeAll() }
}

/// 独立的歌单广场页面：平台切换、分类、歌单搜索。
@MainActor
struct PlaylistSquareView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared

    @State private var provider: SearchProvider = .netease
    @State private var categories: [String] = ["全部"]
    @State private var category = "全部"
    @State private var playlists: [Playlist] = []
    @State private var query = ""
    @State private var searching = false
    @State private var isSearchResult = false
    @State private var loading = false
    @State private var errorText: String?
    @State private var extraPresented: Playlist?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var providers: [SearchProvider] {
        platformPrefs.enabledSearchProviders.filter { !$0.isVideoPlatform }
    }

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        searchField
                        providerRow
                        if provider == .netease && !isSearchResult { categoryRow }
                        if isSearchResult {
                            Text("歌单搜索结果")
                                .font(BeansFont.appFont(16, .bold)).foregroundStyle(Color.beansLabel)
                        }
                        content
                    }
                    .padding(16)
                    .padding(.bottom, 120)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .beansScrollIndicatorsHidden()
                .refreshable { await load(force: true) }
            }
            .navigationTitle("歌单广场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task(id: "\(provider.rawValue)|\(category)") { await load(force: false) }
        .sheet(item: $extraPresented) { playlist in
            ExtraSongListSheet(title: playlist.name) { try await ExtraPlatforms.playlistSongs(playlist) }
                .environmentObject(theme)
                .environmentObject(player)
                .environmentObject(auth)
        }
        .onAppear {
            if !providers.contains(provider) { provider = providers.first ?? .netease }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.beansComment)
            TextField("搜索歌单", text: $query)
                .font(BeansFont.appFont(14))
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
            if !query.isEmpty {
                Button {
                    query = ""
                    isSearchResult = false
                    Task { await load(force: false) }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.beansComment)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除搜索记录")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background { BeansGlass(shape: Capsule()) }
    }

    private var providerRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(providers) { p in
                    let selected = provider == p
                    Button {
                        BeansHaptics.select()
                        provider = p
                        isSearchResult = false
                        if !query.isEmpty { Task { await runSearch() } }
                    } label: {
                        Text(LocalizedStringKey(p.rawValue))
                            .font(BeansFont.appFont(13, selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.white : Color.beansLabel)
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(selected ? AnyShapeStyle(p.tint) : AnyShapeStyle(Color.beansLabel.opacity(0.06)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories, id: \.self) { cat in
                    let selected = category == cat
                    Button {
                        BeansHaptics.select()
                        category = cat
                    } label: {
                        Text(cat)
                            .font(BeansFont.appFont(12, selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.beansAmber : Color.beansLabel)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(selected ? Color.beansAmber.opacity(0.14) : Color.beansLabel.opacity(0.055), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if (loading || searching) && playlists.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else if playlists.isEmpty {
            Text(errorText ?? (isSearchResult ? "没有找到相关歌单" : "\(beansPlatformName(provider))歌单暂时没有内容"))
                .font(BeansFont.appFont(13)).foregroundStyle(Color.beansComment)
                .frame(maxWidth: .infinity).padding(.top, 40)
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(playlists) { playlist in
                    cell(playlist)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ playlist: Playlist) -> some View {
        let label = VStack(alignment: .leading, spacing: 6) {
            CoverImage(url: playlist.coverURL, size: 144, cornerRadius: 18)
                .frame(maxWidth: .infinity)
            Text(playlist.name)
                .font(BeansFont.appFont(12, .medium))
                .foregroundStyle(Color.beansLabel)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if playlist.trackCount > 0 {
                Text(beansSongCountText(playlist.trackCount))
                    .font(BeansFont.appFont(11)).foregroundStyle(Color.beansComment)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { BeansGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) }

        if playlist.source == .kuwo || playlist.source == .migu {
            Button { extraPresented = playlist } label: { label }
                .buttonStyle(GlassPressButtonStyle(scale: 0.96))
        } else {
            NavigationLink {
                PlaylistView(playlist: playlist)
                    .environmentObject(player)
                    .environmentObject(auth)
            } label: { label }
                .buttonStyle(GlassPressButtonStyle(scale: 0.96))
        }
    }

    // MARK: 加载

    private func cacheKey() -> String { "\(provider.rawValue)|\(category)" }

    private func load(force: Bool) async {
        guard !isSearchResult else { return }
        if !force, let cached = PlaylistSquareCache.shared.list(for: cacheKey()) {
            playlists = cached
            return
        }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let list: [Playlist]
            switch provider {
            case .netease:
                if categories.count <= 1 {
                    let cats = await NetEaseAPI.shared.playlistCatlist()
                    if !cats.isEmpty { categories = ["全部"] + Array(cats.prefix(30)) }
                }
                list = try await NetEaseAPI.shared.playlistSquare(cat: category, order: "hot", limit: 48)
            case .qq:
                list = try await QQMusicAPI.shared.hotPlaylists(limit: 40)
            case .kugou:
                list = try await KugouMusicAPI.shared.recommendPlaylists(limit: 40)
            case .kuwo:
                list = try await KuwoMusicAPI.recommendedPlaylists()
            case .migu:
                list = try await MiguMusicAPI.recommendedPlaylists()
            case .bilibili:
                list = []
            }
            playlists = list
            PlaylistSquareCache.shared.save(list, for: cacheKey())
        } catch {
            // 保留已有内容，失败时才显示错误
            if playlists.isEmpty { errorText = "歌单广场加载失败：下拉刷新可重试" }
        }
    }

    private func runSearch() async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        isSearchResult = true
        searching = true
        errorText = nil
        playlists = []
        defer { searching = false }
        if provider == .kuwo || provider == .migu {
            errorText = "该平台暂不支持歌单搜索"
            return
        }
        do {
            playlists = try await PlaylistSearchAPI.search(provider, keyword: keyword)
        } catch {
            errorText = "搜索失败，请稍后重试"
        }
    }
}
