#if os(iOS)
import SwiftUI
import UIKit
import WebKit

@MainActor
private final class BilibiliContentViewModel: ObservableObject {
    enum Feed: String, CaseIterable, Identifiable {
        case recommend = "推荐"
        case ranking = "排行榜"
        case partition = "分区"
        var id: String { rawValue }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case videos = "视频"
        case users = "UP 主"
        case collections = "合集"
        var id: String { rawValue }
    }

    @Published var videos: [BilibiliAPI.Video] = []
    @Published var users: [BilibiliAPI.User] = []
    @Published var collections: [BilibiliAPI.Collection] = []
    @Published var tab: Tab = .videos
    @Published var query = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isSearching = false
    @Published var feed: Feed = .recommend
    @Published var category = "推荐"
    @Published var rankingCategory = "全站"
    @Published var recommendationSource: BilibiliRecommendationSource = .app

    func loadPopular(cookie: String?, source: BilibiliRecommendationSource) async {
        recommendationSource = source
        await loadCategory("推荐", cookie: cookie)
    }

    func selectRecommendationSource(_ source: BilibiliRecommendationSource, cookie: String?) {
        recommendationSource = source
        Task { @MainActor [weak self] in
            await self?.loadCategory("推荐", cookie: cookie)
        }
    }

    func selectCategory(_ value: String, cookie: String?) {
        Task { @MainActor [weak self] in await self?.loadCategory(value, cookie: cookie) }
    }

    func selectRanking(_ value: String, cookie: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            rankingCategory = value
            feed = .ranking
            isSearching = false
            query = ""
            isLoading = true
            errorMessage = nil
            do {
                videos = try await BilibiliAPI.shared.rankedVideos(
                    categoryID: Self.rankingIDs[value] ?? 0,
                    cookie: cookie
                )
                if videos.isEmpty { errorMessage = "暂时没有相关排行榜内容" }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func search(cookie: String?) async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            isSearching = false
            feed = .recommend
            await loadPopular(cookie: cookie, source: recommendationSource)
            return
        }

        isSearching = true
        isLoading = true
        errorMessage = nil
        // Bilibili owns a separate result store. Never leave a previous feed
        // or tab visible while a new query is in flight.
        videos = []
        users = []
        collections = []
        do {
            switch tab {
            case .videos:
                videos = try await BilibiliAPI.shared.searchVideos(keyword: keyword, cookie: cookie).videos
            case .users:
                users = try await BilibiliAPI.shared.searchUsers(keyword: keyword, cookie: cookie)
            case .collections:
                collections = try await BilibiliAPI.shared.searchCollections(keyword: keyword, cookie: cookie)
            }
            if isEmptyForCurrentTab { errorMessage = "没有找到相关内容" }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// The first request can race Bilibili's visitor-cookie bootstrap. Keep
    /// that transient failure inside the Bilibili search flow and retry once;
    /// music search is never involved in this recovery path.
    func searchWithRetry(cookie: String?) async {
        await search(cookie: cookie)
        guard errorMessage != nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        errorMessage = nil
        try? await Task.sleep(for: .milliseconds(250))
        await search(cookie: cookie)
    }

    func selectTab(_ value: Tab, cookie: String?) {
        tab = value
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await search(cookie: cookie) }
    }

    private func loadCategory(_ value: String, cookie: String?) async {
        category = value
        feed = value == "推荐" ? .recommend : .partition
        query = ""
        isSearching = false
        isLoading = true
        errorMessage = nil
        do {
            if value == "推荐" {
                videos = try await BilibiliAPI.shared.recommendedVideos(
                    source: recommendationSource,
                    cookie: cookie
                )
            } else if let categoryID = Self.categoryIDs[value] {
                videos = try await BilibiliAPI.shared.rankedVideos(categoryID: categoryID, cookie: cookie)
            } else {
                videos = []
            }
            if videos.isEmpty { errorMessage = "暂时没有相关视频" }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private var isEmptyForCurrentTab: Bool {
        switch tab {
        case .videos: return videos.isEmpty
        case .users: return users.isEmpty
        case .collections: return collections.isEmpty
        }
    }

    private static let categoryIDs = [
        "音乐": 3, "游戏": 4, "动画": 1, "番剧": 13, "国创": 167,
        "舞蹈": 129, "娱乐": 5, "知识": 36, "电影": 23,
        "电视剧": 11, "纪录片": 177, "资讯": 202
    ]

    private static let rankingIDs = [
        "全站": 0, "动画": 1, "番剧": 13, "音乐": 3, "游戏": 4, "知识": 36
    ]
}

struct BilibiliContentView: View {
    private enum Surface: String, CaseIterable, Identifiable, Hashable {
        case videos = "视频"
        case live = "直播"
        case dynamic = "动态"
        case account = "我的"

        var id: String { rawValue }
    }

    private enum AccountTab: String, CaseIterable, Identifiable {
        case history = "观看记录"
        case favorites = "收藏夹"
        case messages = "私信"

        var id: String { rawValue }
    }

    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var player: PlayerService
    @StateObject private var model = BilibiliContentViewModel()
    @State private var selectedVideo: BilibiliAPI.Video?
    @State private var surface: Surface = .videos
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var dynamics: [BilibiliAPI.DynamicItem] = []
    @State private var dynamicLoading = false
    @State private var dynamicError: String?
    @State private var accountTab: AccountTab = .history
    @State private var watchHistory: [BilibiliAPI.WatchHistoryItem] = []
    @State private var favoriteFolders: [BilibiliAPI.FavoriteFolder] = []
    @State private var favoriteVideos: [BilibiliAPI.Video] = []
    @State private var privateMessages: [BilibiliAPI.PrivateMessageThread] = []
    @State private var selectedFavoriteFolderID: Int?
    @State private var accountLoading = false
    @State private var accountError: String?
    @State private var accountStats = BilibiliAccountStats()
    @State private var showAccountDetail = false
    @State private var showFilter = false
    @State private var showAppSettings = false
    @Environment(\.dismiss) private var dismiss
    /// Embedded in the Home tab (platform switcher) instead of presented on its own.
    var embedded = false

    var body: some View {
        VStack(spacing: 0) {
        if embedded {
            Picker("哔哩哔哩", selection: $surface) {
                ForEach(Surface.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Layout.contentInset)
            .padding(.vertical, 8)
        }
        ZStack {
            // Embedded in the home tab the page background (wallpaper) must show through.
            if !embedded { Color(uiColor: .systemBackground).ignoresSafeArea() }
            if surface == .live {
                VStack(spacing: 0) {
                    // Keep live browsing inside the Bilibili surface instead
                    // of presenting a second, unrelated sheet. This is the
                    // native equivalent of PiliPlus's video/live switch.
                    BilibiliLiveView(embedded: true)
                        .environmentObject(bilibili)
                        .environmentObject(settings)
                }
            } else if surface == .dynamic {
                dynamicSurface
            } else if surface == .account {
                accountSurface
            } else {
                videoSurface
            }
        }
        }
        .navigationTitle(embedded ? "推荐" : "哔哩哔哩")
        .navigationBarTitleDisplayMode(embedded ? .automatic : .large)
        .toolbar {
            if embedded {
                // Bilibili-only search, right next to the account entry.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("搜索哔哩哔哩")
                }
                // Account entry next to the platform switcher (like Beans' avatar button).
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { surface = .account }
                    } label: {
                        bilibiliAvatarButton
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("哔哩哔哩账号")
                }
            }
            if !embedded {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("返回")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(Surface.allCases) { value in
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                surface = value
                            }
                        } label: {
                            Label(value.rawValue, systemImage: surfaceIcon(value))
                        }
                    }
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .accessibilityLabel("切换哔哩哔哩内容")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                ThemeRevealButton()
                    .environmentObject(settings)
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("打开独立搜索")

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("B 站设置")
                // Beans uses the account avatar as the entry point for the
                // Bilibili profile, messages, history, and favorites. Keep
                // the mode switcher in the page body; this button only opens
                // the account surface and does not add another close control.
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        surface = .account
                    }
                } label: {
                    bilibiliAvatarButton
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Bilibili account")
            }
            }
        }
        .task {
            model.recommendationSource = settings.bilibiliRecommendationSource
            if surface == .dynamic {
                await loadDynamic()
            } else if surface == .account {
                await loadAccount()
            } else if model.videos.isEmpty {
                await model.loadPopular(cookie: bilibili.cookie,
                                       source: settings.bilibiliRecommendationSource)
            }
        }
        .onChange(of: surface) { value in
            if value == .dynamic {
                Task { await loadDynamic() }
            } else if value == .account {
                Task { await loadAccount() }
            }
        }
        .onChange(of: accountTab) { _ in
            guard surface == .account else { return }
            Task { await loadAccount() }
        }
        .sheet(item: $selectedVideo) { video in
            NavigationStack {
                BilibiliVideoDetailView(video: video)
                    .environmentObject(bilibili)
                    .environmentObject(settings)
            }
        }
        .sheet(isPresented: $showFilter) {
            BilibiliFilterView()
        }
        .sheet(isPresented: $showAppSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .sheet(isPresented: $showAccountDetail) {
            accountDetailSheet
                .environmentObject(bilibili)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                BilibiliSettingsView()
                    .environmentObject(settings)
            }
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                BilibiliSearchView()
                    .environmentObject(bilibili)
                    .environmentObject(settings)
            }
        }
    }
    private var dynamicSurface: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !bilibili.isLoggedIn {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("动态需要登录", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.headline)
                        Text("登录后读取关注动态；登录只保存平台会话，不会把密码交给 Moumusic。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("请在“账号与同步”中完成哔哩哔哩扫码登录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, Theme.Layout.contentInset)
                } else if dynamicLoading && dynamics.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                } else if let dynamicError, dynamics.isEmpty {
                    ErrorStateView(message: dynamicError) {
                        Task { await loadDynamic() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else if dynamics.isEmpty {
                    EmptyStateView(icon: "bolt.horizontal.circle", title: "暂时没有动态")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    HStack {
                        SectionHeader(title: "动态")
                        Spacer()
                        Button {
                            Task { await loadDynamic() }
                        } label: {
                            Image(systemName: dynamicLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        }
                        .disabled(dynamicLoading)
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                    ForEach(BilibiliContentFilter.dynamics(dynamics)) { item in
                        BilibiliDynamicCard(item: item) {
                            if let video = item.video { open(video) }
                        }
                        .padding(.horizontal, Theme.Layout.contentInset)
                    }
                }
                PlayerClearanceSpacer()
            }
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
    }

    @MainActor
    private func loadDynamic() async {
        guard bilibili.isLoggedIn else { return }
        dynamicLoading = true
        dynamicError = nil
        defer { dynamicLoading = false }
        do {
            dynamics = try await BilibiliAPI.shared.dynamicFeed(cookie: bilibili.cookie)
            if dynamics.isEmpty { dynamicError = "暂时没有可显示的动态" }
        } catch {
            dynamicError = "动态加载失败：\(error.localizedDescription)"
        }
    }

    private var accountSurface: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if bilibili.isLoggedIn {
                    beansAccountSurface
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("登录后查看 B 站账号内容", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.headline)
                        Text("观看记录、收藏夹和私信只会读取当前设备保存的 B 站会话。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("请在“账号与同步”中完成哔哩哔哩扫码登录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, Theme.Layout.contentInset)
                }
                PlayerClearanceSpacer()
            }
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .task {
            if bilibili.isLoggedIn {
                accountStats = await BilibiliAccountStats.fetch(cookie: bilibili.cookie)
                if privateMessages.isEmpty {
                    privateMessages = (try? await BilibiliAPI.shared.privateMessages(cookie: bilibili.cookie)) ?? []
                }
            }
        }
    }

    /// Beans-style "我的" page: account card, account content rows, settings
    /// rows and the listen/watch switch.
    private var beansAccountSurface: some View {
        VStack(alignment: .leading, spacing: 16) {
            BilibiliBeansAccountCard(
                avatarURL: bilibili.avatarURL?.resizedImageURL(120),
                name: bilibili.profileName ?? "Bilibili",
                uid: accountStats.uid,
                stats: accountStats,
                onSignOut: { bilibili.signOut() }
            )

            BilibiliRowCard(title: "账号内容", rows: [
                .init(icon: "sparkles", title: "动态") {
                    withAnimation(.easeInOut(duration: 0.22)) { surface = .dynamic }
                },
                .init(icon: "bell.badge", title: "账号消息", badge: unreadMessageCount) {
                    openAccountDetail(.messages)
                },
                .init(icon: "clock.arrow.circlepath", title: "观看记录") {
                    openAccountDetail(.history)
                },
                .init(icon: "star", title: "账号收藏") {
                    openAccountDetail(.favorites)
                },
            ])

            BilibiliCloudPlaylistsCard()
                .environmentObject(bilibili)
                .padding(.horizontal, -Theme.Layout.contentInset)

            BilibiliRowCard(title: "设置", titleIcon: "slider.horizontal.3", rows: [
                .init(icon: "paintpalette", title: "界面显示", subtitle: "强调色跟随 Moumusic") {
                    showSettings = true
                },
                .init(icon: "house", title: "首页与搜索",
                      subtitle: settings.bilibiliRecommendationSource.displayName) {
                    showSettings = true
                },
                .init(icon: "play.rectangle", title: "播放偏好", subtitle: "画质、解码、自动播放与播放行为") {
                    showSettings = true
                },
                .init(icon: "line.3.horizontal.decrease.circle", title: "内容过滤", subtitle: "推荐与动态关键词过滤") {
                    showFilter = true
                },
                .init(icon: "gearshape", title: "Moumusic 设置", subtitle: "Moumusic 软件设置") {
                    showAppSettings = true
                },
            ])

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "play.rectangle").font(.title3)
                    Text("视频播放").font(.headline.weight(.semibold))
                }
                Picker("视频播放", selection: $settings.bilibiliMode) {
                    Text("听视频").tag(BilibiliMode.listen)
                    Text("看视频").tag(BilibiliMode.watch)
                }
                .pickerStyle(.segmented)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .compatGlass(interactive: false, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.8)
            }
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private func openAccountDetail(_ tab: AccountTab) {
        accountTab = tab
        showAccountDetail = true
        Task { await loadAccount() }
    }

    private var accountDetailSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if accountLoading && accountIsEmpty {
                        ProgressView("正在读取 B 站账号内容")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else if let accountError, accountIsEmpty {
                        ErrorStateView(message: accountError) {
                            Task { await loadAccount() }
                        }
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        accountBody
                    }
                }
                .padding(.top, 12)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(accountTab.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadAccount() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(accountLoading)
                }
            }
        }
    }

    private var accountIdentityCard: some View {
        MouGlassCard(cornerRadius: 26, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    bilibiliAvatar(size: 58)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(bilibili.profileName ?? "Bilibili user")
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        Text("Bilibili account sync")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let membership = bilibili.membershipTitle {
                            Label(membership, systemImage: "checkmark.seal.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                }

                HStack(spacing: 10) {
                    accountShortcut(title: "私信", value: unreadMessageCount, icon: "bubble.left.and.bubble.right.fill") {
                        accountTab = .messages
                    }
                    accountShortcut(title: "记录", icon: "clock.fill") {
                        accountTab = .history
                    }
                    accountShortcut(title: "收藏", icon: "star.fill") {
                        accountTab = .favorites
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private var unreadMessageCount: Int {
        privateMessages.reduce(0) { $0 + max(0, $1.unreadCount) }
    }

    private func accountShortcut(
        title: String,
        value: Int? = nil,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 42, height: 34)
                    if let value, value > 0 {
                        Text("\(value)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(.red, in: Capsule())
                            .offset(x: 5, y: -4)
                    }
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var bilibiliAvatarButton: some View {
        bilibiliAvatar(size: 36)
    }

    private func bilibiliAvatar(size: CGFloat) -> some View {
        Group {
            if let url = bilibili.avatarURL?.resizedImageURL(Int(size * 2)) {
                CachedAsyncImage(url: url, animated: false) {
                    avatarPlaceholder
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .background(.regularMaterial, in: Circle())
        .overlay {
            Circle().strokeBorder(.primary.opacity(0.16), lineWidth: 0.8)
        }
        .contentShape(Circle())
    }

    private var avatarPlaceholder: some View {
        Image(systemName: bilibili.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
            .font(.system(size: 25, weight: .semibold))
            .foregroundStyle(bilibili.isLoggedIn ? Theme.accent : .secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accountIsEmpty: Bool {
        switch accountTab {
        case .history: return watchHistory.isEmpty
        case .favorites: return favoriteFolders.isEmpty && favoriteVideos.isEmpty
        case .messages: return privateMessages.isEmpty
        }
    }

    @ViewBuilder
    private var accountBody: some View {
        switch accountTab {
        case .history:
            if watchHistory.isEmpty {
                EmptyStateView(icon: "clock", title: "还没有观看记录")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(watchHistory) { item in
                        Button {
                            if let video = item.video { open(video) }
                        } label: {
                            BilibiliHistoryRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .disabled(item.video == nil)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
        case .favorites:
            favoriteBody
        case .messages:
            if privateMessages.isEmpty {
                EmptyStateView(icon: "bubble.left.and.bubble.right", title: "暂无私信")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(privateMessages) { message in
                        BilibiliMessageRow(message: message)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
        }
    }

    @ViewBuilder
    private var favoriteBody: some View {
        if favoriteFolders.isEmpty {
            EmptyStateView(icon: "star", title: "暂无收藏夹")
                .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(favoriteFolders) { folder in
                        Button {
                            selectedFavoriteFolderID = folder.id
                            Task { await loadFavoriteFolder(folder.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.title).lineLimit(1)
                                Text("\(folder.mediaCount) 个视频")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                selectedFavoriteFolderID == folder.id ? Theme.accent.opacity(0.18) : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
            if favoriteVideos.isEmpty {
                EmptyStateView(icon: "rectangle.stack", title: "收藏夹为空或尚未读取")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                videoGrid(favoriteVideos)
            }
        }
    }

    @MainActor
    private func loadAccount() async {
        guard bilibili.isLoggedIn else { return }
        accountLoading = true
        accountError = nil
        defer { accountLoading = false }
        do {
            switch accountTab {
            case .history:
                watchHistory = try await BilibiliAPI.shared.watchHistory(cookie: bilibili.cookie)
            case .favorites:
                if favoriteFolders.isEmpty {
                    favoriteFolders = try await BilibiliAPI.shared.favoriteFolders(cookie: bilibili.cookie)
                }
                if selectedFavoriteFolderID == nil {
                    selectedFavoriteFolderID = favoriteFolders.first?.id
                }
                if let folderID = selectedFavoriteFolderID {
                    favoriteVideos = try await BilibiliAPI.shared.favoriteVideos(
                        folderID: folderID, cookie: bilibili.cookie
                    )
                }
            case .messages:
                privateMessages = try await BilibiliAPI.shared.privateMessages(cookie: bilibili.cookie)
            }
        } catch is CancellationError {
            return
        } catch {
            accountError = error.localizedDescription
        }
    }

    @MainActor
    private func loadFavoriteFolder(_ folderID: Int) async {
        guard bilibili.isLoggedIn else { return }
        accountLoading = true
        accountError = nil
        defer { accountLoading = false }
        do {
            favoriteVideos = try await BilibiliAPI.shared.favoriteVideos(
                folderID: folderID, cookie: bilibili.cookie
            )
        } catch is CancellationError {
            return
        } catch {
            accountError = error.localizedDescription
        }
    }
    private var videoSurface: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                feedPicker
                if model.feed == .recommend { recommendationSourcePicker }
                model.feed == .ranking ? AnyView(rankingTabs) : AnyView(categoryTabs)

                if model.isLoading && model.videos.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 280)
                } else if let errorMessage = model.errorMessage,
                          model.videos.isEmpty {
                    ErrorStateView(message: errorMessage) {
                        Task { await model.searchWithRetry(cookie: bilibili.cookie) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    SectionHeader(title: LocalizedStringKey(contentTitle))
                        .padding(.horizontal, Theme.Layout.contentInset)
                    videoGrid(model.videos)
                }
                PlayerClearanceSpacer()
            }
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
    }

    private func surfaceIcon(_ value: Surface) -> String {
        switch value {
        case .videos: return "play.rectangle"
        case .live: return "dot.radiowaves.left.and.right"
        case .dynamic: return "bolt.horizontal.circle"
        case .account: return "person.crop.circle"
        }
    }

    private var feedPicker: some View {
        Picker("内容类型", selection: Binding(
            get: { model.feed },
            set: {
                switch $0 {
                case .recommend: model.selectCategory("推荐", cookie: bilibili.cookie)
                case .ranking: model.selectRanking("全站", cookie: bilibili.cookie)
                case .partition: model.selectCategory("音乐", cookie: bilibili.cookie)
                }
            }
        )) {
            ForEach(BilibiliContentViewModel.Feed.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private var recommendationSourcePicker: some View {
        Menu {
            ForEach(BilibiliRecommendationSource.allCases) { source in
                Button {
                    settings.bilibiliRecommendationSource = source
                    model.selectRecommendationSource(source, cookie: bilibili.cookie)
                } label: {
                    Label {
                        Text(source.displayName)
                    } icon: {
                        Image(systemName: source == model.recommendationSource
                              ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.tv")
                    .foregroundStyle(Theme.accent)
                Text("推荐")
                    .font(.subheadline.weight(.semibold))
                Text(model.recommendationSource.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .compatGlass(interactive: true, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Layout.contentInset)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel("选择 B 站推荐客户端")
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(["推荐", "音乐", "游戏", "动画", "番剧", "国创", "舞蹈", "娱乐", "知识", "电影", "纪录片", "资讯"], id: \.self) { title in
                    Button { model.selectCategory(title, cookie: bilibili.cookie) } label: {
                        Text(title)
                            .font(.headline.weight(model.category == title ? .semibold : .regular))
                            .foregroundStyle(model.category == title ? Theme.accent : .secondary)
                            .padding(.bottom, 8)
                            .overlay(alignment: .bottom) {
                                if model.category == title { Capsule().fill(Theme.accent).frame(width: 32, height: 3) }
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private var rankingTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["全站", "动画", "番剧", "音乐", "游戏", "知识"], id: \.self) { title in
                    Button { model.selectRanking(title, cookie: bilibili.cookie) } label: { Text(title) }
                        .buttonStyle(.chip(isSelected: model.rankingCategory == title))
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private var contentTitle: String {
        switch model.feed {
        case .recommend: return model.recommendationSource == .app ? "App 推荐" : "网页版推荐"
        case .ranking: return "\(model.rankingCategory)排行榜"
        case .partition: return "\(model.category)分区"
        }
    }

    /// 听视频 plays the audio through the main music player; 看视频 opens the video page.
    private func open(_ video: BilibiliAPI.Video, in list: [BilibiliAPI.Video]? = nil) {
        if settings.bilibiliMode == .listen {
            let source = list ?? [video]
            player.play(tracks: source.map(Track.bilibili), source: .none, startAt: Track.bilibili(video))
        } else {
            selectedVideo = video
        }
    }

    private func videoGrid(_ videos: [BilibiliAPI.Video]) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 0), spacing: 12),
                GridItem(.flexible(minimum: 0), spacing: 12)
            ],
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(BilibiliContentFilter.videos(videos)) { video in
                Button { open(video, in: videos) } label: { BilibiliVideoCard(video: video) }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Layout.contentInset)
    }
}

/// Beans keeps music search as its own destination. Bilibili search follows
/// the same rule instead of being injected into the music platform picker.
struct BilibiliSearchView: View {
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BilibiliContentViewModel()
    @State private var selectedVideo: BilibiliAPI.Video?
    @State private var selectedUser: BilibiliAPI.User?
    @EnvironmentObject private var player: PlayerService
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                searchField
                Picker("搜索类型", selection: Binding(
                    get: { model.tab },
                    set: { model.selectTab($0, cookie: bilibili.cookie) }
                )) {
                    ForEach(BilibiliContentViewModel.Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Layout.contentInset)

                if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "搜索哔哩哔哩视频、UP 主或合集")
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if model.isLoading {
                    ProgressView("正在搜索哔哩哔哩")
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if let errorMessage = model.errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await model.searchWithRetry(cookie: bilibili.cookie) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    results
                }
                PlayerClearanceSpacer()
            }
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("哔哩哔哩搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .task {
            searchFocused = true
        }
        .sheet(item: $selectedUser) { user in
            NavigationStack {
                BilibiliUserVideosView(user: user)
                    .environmentObject(bilibili)
                    .environmentObject(settings)
                    .environmentObject(player)
            }
        }
        .sheet(item: $selectedVideo) { video in
            NavigationStack {
                BilibiliVideoDetailView(video: video)
                    .environmentObject(bilibili)
                    .environmentObject(settings)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("搜索视频、UP 主或合集", text: $model.query)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    searchFocused = false
                    Task { @MainActor in
                        // Let UIKit commit marked text from Chinese and
                        // third-party keyboards before reading the query.
                        await Task.yield()
                        try? await Task.sleep(for: .milliseconds(80))
                        await model.searchWithRetry(cookie: bilibili.cookie)
                    }
                }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    model.isSearching = false
                    model.errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除 B 站搜索")
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    @ViewBuilder
    private var results: some View {
        switch model.tab {
        case .videos:
            if model.videos.isEmpty {
                EmptyStateView(icon: "play.rectangle", title: "没有找到相关视频")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 18
                ) {
                    ForEach(model.videos) { video in
                        Button { selectedVideo = video } label: {
                            BilibiliVideoCard(video: video)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
        case .users:
            if model.users.isEmpty {
                EmptyStateView(icon: "person.2", title: "没有找到相关 UP 主")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.users) { user in
                        Button { selectedUser = user } label: { BilibiliUserRow(user: user).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
        case .collections:
            if model.collections.isEmpty {
                EmptyStateView(icon: "rectangle.stack", title: "没有找到相关合集")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.collections) { collection in
                        BilibiliCollectionRow(collection: collection)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
        }
    }
}

private struct BilibiliHistoryRow: View {
    let item: BilibiliAPI.WatchHistoryItem

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: item.coverURL?.resizedImageURL(240), animated: false)
                .frame(width: 112, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text([item.author, item.durationText].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let viewedAt = item.viewedAt {
                    Text(Self.dateFormatter.string(from: viewedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if item.video != nil {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

private struct BilibiliMessageRow: View {
    let message: BilibiliAPI.PrivateMessageThread

    /// Bilibili stores message bodies as JSON (`{"content":"hi"}`, image
    /// `{"url":...}`, share `{"title":...}`); show human text instead.
    static func readable(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return raw }
        if let content = object["content"] as? String, !content.isEmpty { return content }
        if let title = object["title"] as? String, !title.isEmpty { return "[分享] \(title)" }
        if object["url"] != nil, object["height"] != nil || object["width"] != nil { return "[图片]" }
        if let reply = object["reply_content"] as? String { return reply }
        return "[消息]"
    }

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: message.avatarURL?.resizedImageURL(96), animated: false)
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(message.userName)
                        .font(.subheadline.weight(.semibold))
                    if message.unreadCount > 0 {
                        Text("\(message.unreadCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                    }
                }
                Text(Self.readable(message.lastMessage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let updatedAt = message.updatedAt {
                Text(Self.dateFormatter.string(from: updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

private struct BilibiliDynamicCard: View {
    let item: BilibiliAPI.DynamicItem
    let openVideo: () -> Void

    var body: some View {
        Button(action: openVideo) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    CachedAsyncImage(url: item.avatarURL?.resizedImageURL(96))
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.author).font(.subheadline.weight(.semibold))
                        if let date = item.publishedAt {
                            Text(Self.dateFormatter.string(from: date))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if item.video != nil {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }
                if !item.text.isEmpty {
                    Text(item.text).font(.body).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let cover = item.coverURL ?? item.video?.coverURL {
                    CachedAsyncImage(url: cover.resizedImageURL(640))
                        .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                HStack(spacing: 16) {
                    Label(Formatters.playCount(item.likeCount), systemImage: "hand.thumbsup")
                    Label(Formatters.playCount(item.commentCount), systemImage: "bubble.left")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
struct BilibiliVideoCard: View {
    let video: BilibiliAPI.Video
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                // Use a fixed-ratio canvas before the asynchronous image is
                // inserted, otherwise SwiftUI measures the loading view at
                // its intrinsic width and the result grid can overlap.
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        CachedAsyncImage(url: video.coverURL?.resizedImageURL(640))
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .overlay(alignment: .bottom) {
                        HStack {
                            Label(Formatters.playCount(video.playCount), systemImage: "play.fill")
                            Spacer(minLength: 4)
                            Text(video.durationText)
                        }
                        .font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(8)
                        .frame(maxWidth: .infinity).background(.black.opacity(0.42))
                    }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()
            // Fixed-height text block so every card in a row (and column) is the same height
            // and the covers line up regardless of title length.
            Text(video.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .topLeading)
            Text(video.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .topLeading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct BilibiliUserRow: View {
    let user: BilibiliAPI.User
    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: user.avatarURL?.resizedImageURL(160)).frame(width: 54, height: 54).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(user.name).font(.headline)
                Text(user.signature.isEmpty ? "UP 主" : user.signature).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if user.followerCount > 0 { Text("粉丝 \(Formatters.playCount(user.followerCount))").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct BilibiliCollectionRow: View {
    let collection: BilibiliAPI.Collection
    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: collection.coverURL?.resizedImageURL(240)).frame(width: 68, height: 68).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(collection.title).font(.headline).lineLimit(2)
                Text(collection.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text("\(collection.itemCount) 个视频").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct BilibiliVideoDetailView: View {
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
    let video: BilibiliAPI.Video

    @State private var detail: BilibiliAPI.Video?
    @StateObject private var playerModel = BiliPlayerModel()
    @State private var playbackURL: URL?
    @State private var playbackAudioURL: URL?
    @State private var triedMuxedFallback = false
    @State private var qualityFallbackDepth = 0
    /// Tracks from the player endpoint (includes AI subtitles when signed in).
    @State private var extraSubtitles: [BilibiliAPI.Subtitle] = []

    private var allSubtitles: [BilibiliAPI.Subtitle] {
        var seen = Set<String>()
        return (activeVideo.subtitles + extraSubtitles).filter { seen.insert($0.url.absoluteString).inserted }
    }
    @State private var audioPlaybackURL: URL?
    @State private var audioQualities: [BilibiliAPI.BilibiliAudioQuality] = []
    @State private var selectedAudioQuality: Int?
    @State private var audioLoading = false
    @State private var playerToken = UUID()
    @State private var errorMessage: String?
    @State private var selectedTab = 0
    @State private var comments: [BilibiliAPI.Comment] = []
    @State private var commentSort: BilibiliAPI.CommentSort = .hot
    @State private var commentsLoading = false
    @State private var listenOnly = false
    @State private var qualities: [BilibiliAPI.VideoQuality] = []
    @State private var selectedQuality: Int?
    @State private var selectedSubtitle: BilibiliAPI.Subtitle?
    @State private var subtitleCues: [BilibiliAPI.SubtitleCue] = []
    @State private var subtitleLoading = false
    @State private var isLoading = true
    @State private var showFullScreen = false
    @State private var showDownloadSheet = false
    @State private var danmakuCues: [BilibiliAPI.DanmakuCue] = []
    @State private var interaction: BilibiliAPI.InteractionState?
    @State private var interactionLoading = false
    @State private var interactionMessage: String?
    @State private var commentText = ""
    @State private var commentPosting = false

    private var activeVideo: BilibiliAPI.Video { detail ?? video }

    private var playerSourceKey: String {
        "\(activePlaybackURL?.absoluteString ?? "")|\(listenOnly ? "" : (playbackAudioURL?.absoluteString ?? ""))|\(playerToken.uuidString)"
    }

    private var activePlaybackURL: URL? {
        listenOnly ? (audioPlaybackURL ?? playbackURL) : playbackURL
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        BiliNativePlayer(
                            model: playerModel,
                            cues: subtitleCues,
                            danmaku: danmakuCues,
                            danmakuEnabled: settings.bilibiliDanmakuEnabled,
                            subtitles: allSubtitles,
                            selectedSubtitleID: selectedSubtitle?.id,
                            onSelectSubtitle: { subtitle in
                                if let subtitle {
                                    Task { await loadSubtitle(subtitle) }
                                } else {
                                    selectedSubtitle = nil
                                    subtitleCues = []
                                }
                            },
                            posterURL: activeVideo.coverURL,
                            audioOnly: listenOnly,
                            title: activeVideo.title,
                            onFullscreen: { showFullScreen = true }
                        )
                        if isLoading {
                            VStack(spacing: 8) {
                                ProgressView()
                                    .tint(.white)
                                Text("正在加载 B 站视频")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.86))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .id(playerToken)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(activeVideo.displayAspectRatio, contentMode: .fit)
                    .frame(maxHeight: activeVideo.displayAspectRatio < 1 ? UIScreen.main.bounds.height * 0.6 : nil)
                    playerOptions
                    Picker("视频内容", selection: $selectedTab) {
                        Text("简介").tag(0)
                        Text("评论").tag(1)
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 16)
                    if selectedTab == 0 { introduction } else { commentsView }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(Theme.accent).padding(.horizontal, 18)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("视频详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .task { await load() }
        .onChange(of: settings.bilibiliMode) { _ in
            Task { await reloadForCurrentMode() }
        }
        .onChange(of: settings.bilibiliDanmakuEnabled) { _ in
            Task { await loadDanmaku() }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            BiliNativePlayer(
                model: playerModel,
                cues: subtitleCues,
                danmaku: danmakuCues,
                danmakuEnabled: settings.bilibiliDanmakuEnabled,
                subtitles: allSubtitles,
                selectedSubtitleID: selectedSubtitle?.id,
                onSelectSubtitle: { subtitle in
                    if let subtitle {
                        Task { await loadSubtitle(subtitle) }
                    } else {
                        selectedSubtitle = nil
                        subtitleCues = []
                    }
                },
                posterURL: activeVideo.coverURL,
                audioOnly: listenOnly,
                title: activeVideo.title,
                isFullscreen: true,
                rotatesInFullscreen: activeVideo.displayAspectRatio >= 1,
                onClose: { showFullScreen = false }
            )
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())
        }
        .task(id: playerSourceKey) {
            playerModel.fallbackDuration = activeVideo.duration
            playerModel.load(
                video: activePlaybackURL,
                audio: listenOnly ? nil : playbackAudioURL,
                autoplay: UserDefaults.standard.object(forKey: "moumusic.bili.autoplay") as? Bool ?? true
            )
        }
        .onAppear {
            playerModel.onError = { message in
                // DASH (separate video/audio) can fail on odd streams: retry once with the
                // muxed MP4 before reporting an error.
                // A tier this device cannot decode (8K, Dolby Vision, ...) fails to open: step down
                // to the next lower quality first, and only then to the muxed MP4.
                if !listenOnly, qualityFallbackDepth < 6,
                   let current = selectedQuality,
                   let lower = qualities.map(\.code).filter({ $0 < current }).max() {
                    qualityFallbackDepth += 1
                    ToastCenter.shared.show("当前画质无法在本机播放，已自动降到较低画质")
                    Task { await loadPlayback(quality: lower) }
                    return
                }
                if !listenOnly, !triedMuxedFallback {
                    triedMuxedFallback = true
                    Task { await loadPlayback(quality: selectedQuality, muxed: true) }
                    return
                }
                isLoading = false
                errorMessage = message
            }
        }
        .onDisappear { playerModel.stop() }
        .sheet(isPresented: $showDownloadSheet) {
            BilibiliDownloadSheet(video: activeVideo, videoQualities: qualities)
                .environmentObject(bilibili)
        }
    }

    private var playerOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(
                    settings.bilibiliMode == .listen ? "听哔哩哔哩" : "看哔哩哔哩",
                    systemImage: settings.bilibiliMode == .listen ? "headphones" : "play.rectangle"
                )
                if settings.bilibiliMode != .listen && activePlaybackURL != nil {
                    Button { showFullScreen = true } label: {
                        Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right")
                    }.buttonStyle(.bordered)
                }
                Button { showDownloadSheet = true } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Link(destination: URL(string: "https://www.bilibili.com/video/\(activeVideo.bvid)")!) {
                    Image(systemName: "safari")
                }.accessibilityLabel("在 B 站打开")
            }
            HStack(spacing: 10) {
                if settings.bilibiliMode != .listen && !qualities.isEmpty {
                    Menu {
                        ForEach(qualities) { quality in
                            Button {
                                qualityFallbackDepth = 0
                                triedMuxedFallback = false
                                Task { await loadPlayback(quality: quality.code) }
                            } label: {
                                quality.code == selectedQuality ? AnyView(Label(quality.displayTitle, systemImage: "checkmark")) : AnyView(Text(quality.displayTitle))
                            }
                            .disabled((quality.requiresVIP && !bilibili.isVIP) ||
                                      (quality.requiresLogin && !bilibili.isLoggedIn))
                        }
                    } label: { Label(currentQualityTitle, systemImage: "rectangle.inset.filled") }
                        .buttonStyle(.bordered)
                }
                if !allSubtitles.isEmpty {
                    Menu {
                        Button("关闭字幕") { selectedSubtitle = nil; subtitleCues = [] }
                        Divider()
                        ForEach(allSubtitles) { subtitle in
                            Button {
                                Task { await loadSubtitle(subtitle) }
                            } label: {
                                subtitle.id == selectedSubtitle?.id ? AnyView(Label(subtitle.displayTitle, systemImage: "checkmark")) : AnyView(Text(subtitle.displayTitle))
                            }
                        }
                    } label: {
                        Label(subtitleLoading ? "加载字幕" : (selectedSubtitle?.displayTitle ?? "字幕"), systemImage: "captions.bubble")
                    }
                    .buttonStyle(.bordered).disabled(subtitleLoading)
                }
                if settings.bilibiliMode == .listen && !audioQualities.isEmpty {
                    Menu {
                        ForEach(audioQualities) { quality in
                            Button {
                                Task { await loadAudioPlayback(quality: quality.code) }
                            } label: {
                                quality.code == selectedAudioQuality
                                    ? AnyView(Label(quality.displayTitle, systemImage: "checkmark"))
                                    : AnyView(Text(quality.displayTitle))
                            }
                            .disabled((quality.requiresVIP && !bilibili.isVIP) ||
                                      (quality.requiresLogin && !bilibili.isLoggedIn))
                        }
                    } label: {
                        Label(audioLoading ? "正在读取音轨" : currentAudioQualityTitle,
                              systemImage: "waveform")
                    }
                    .buttonStyle(.bordered)
                    .disabled(audioLoading)
                }
            }
        }
        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent).padding(.horizontal, 18)
    }

    private var interactionBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await toggleLike() }
            } label: {
                Label(interaction?.isLiked == true ? "已点赞" : "点赞",
                      systemImage: interaction?.isLiked == true ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            .buttonStyle(.bordered)
            .disabled(!bilibili.isLoggedIn || interactionLoading)

            Button {
                Task { await addCoin() }
            } label: {
                Label((interaction?.coinCount ?? 0) > 0 ? "已投币" : "投币",
                      systemImage: (interaction?.coinCount ?? 0) > 0 ? "circle.fill" : "circle")
            }
            .buttonStyle(.bordered)
            .disabled(!bilibili.isLoggedIn || interactionLoading)

            Button {
                Task { await toggleFavorite() }
            } label: {
                Label(interaction?.isFavorited == true ? "已收藏" : "收藏",
                      systemImage: interaction?.isFavorited == true ? "star.fill" : "star")
            }
            .buttonStyle(.bordered)
            .disabled(!bilibili.isLoggedIn || interactionLoading)

            if interactionLoading {
                ProgressView().controlSize(.small)
            } else if let interactionMessage {
                Text(interactionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !bilibili.isLoggedIn {
                Text("登录后互动")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.medium))
    }

    private var commentComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("发一条评论…", text: $commentText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button {
                Task { await submitComment() }
            } label: {
                if commentPosting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(commentPosting || commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !bilibili.isLoggedIn)
        }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(activeVideo.title).font(.title3.weight(.semibold))
            Text("\(Formatters.playCount(activeVideo.playCount)) 次播放 · \(activeVideo.author)").font(.subheadline).foregroundStyle(.secondary)
            if !activeVideo.description.isEmpty {
                Text(activeVideo.description).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            interactionBar
            if !allSubtitles.isEmpty {
                Label("已发现 \(allSubtitles.count) 条字幕轨道（含中文与 AI 字幕），可在播放器里选择", systemImage: "captions.bubble")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 18)
    }

    private var currentQualityTitle: String {
        guard let selectedQuality else { return "画质" }
        return qualities.first(where: { $0.code == selectedQuality })?.displayTitle ?? "画质"
    }

    private var currentAudioQualityTitle: String {
        guard let selectedAudioQuality else { return "音轨" }
        return audioQualities.first(where: { $0.code == selectedAudioQuality })?.displayTitle ?? "音轨"
    }

    private var commentsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("评论排序", selection: Binding(
                get: { commentSort },
                set: { commentSort = $0; Task { await loadComments() } }
            )) {
                Text("热门").tag(BilibiliAPI.CommentSort.hot)
                Text("最新").tag(BilibiliAPI.CommentSort.latest)
            }.pickerStyle(.segmented)
            commentComposer
            if commentsLoading && comments.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if comments.isEmpty {
                EmptyStateView(icon: "bubble.left", title: "暂无评论").frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ForEach(comments) { BilibiliCommentRow(comment: $0) }
            }
        }
        .padding(.horizontal, 18)
        .task(id: selectedTab) { if selectedTab == 1 && comments.isEmpty { await loadComments() } }
    }

    @MainActor private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await BilibiliAPI.shared.videoDetail(bvid: video.bvid, cookie: bilibili.cookie)
            detail = loaded
            if settings.bilibiliMode == .listen {
                listenOnly = true
                playbackURL = nil
                qualities = []
                selectedQuality = nil
                await loadAudioPlayback(quality: selectedAudioQuality)
            } else {
                listenOnly = false
                await loadPlayback(quality: selectedQuality, video: loaded)
            }
            await loadInteractionState()
            await loadDanmaku()
            if let cid = loaded.cid {
                extraSubtitles = (try? await BilibiliAPI.shared.subtitleTracks(
                    bvid: loaded.bvid, aid: loaded.aid, cid: cid, cookie: bilibili.cookie)) ?? []
            }
            if let subtitle = preferredSubtitle(in: allSubtitles) {
                await loadSubtitle(subtitle)
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    /// Chinese first (uploaded, then AI), then any uploaded track, then AI, then translations.
    private func preferredSubtitle(in subtitles: [BilibiliAPI.Subtitle]) -> BilibiliAPI.Subtitle? {
        func isChinese(_ item: BilibiliAPI.Subtitle) -> Bool {
            item.language.lowercased().contains("zh") || item.title.contains("中文") || item.title.contains("简体")
        }
        return subtitles.first(where: { isChinese($0) && !$0.isAIGenerated && !$0.isTranslated })
            ?? subtitles.first(where: { isChinese($0) && $0.isAIGenerated && !$0.isTranslated })
            ?? subtitles.first(where: { !$0.isAIGenerated && !$0.isTranslated })
            ?? subtitles.first(where: { $0.isAIGenerated && !$0.isTranslated })
            ?? subtitles.first(where: { isChinese($0) })
            ?? subtitles.first
    }

    @MainActor private func reloadForCurrentMode() async {
        guard detail != nil else { return }
        switch settings.bilibiliMode {
        case .listen:
            listenOnly = true
            playbackURL = nil
            playbackAudioURL = nil
            qualities = []
            selectedQuality = nil
            await loadAudioPlayback(quality: selectedAudioQuality)
        case .watch:
            listenOnly = false
            audioPlaybackURL = nil
            audioQualities = []
            selectedAudioQuality = nil
            await loadPlayback(quality: selectedQuality)
        case .disabled:
            listenOnly = false
            playbackURL = nil
            audioPlaybackURL = nil
            qualities = []
            audioQualities = []
        }
    }

    @MainActor private func loadInteractionState() async {
        guard bilibili.isLoggedIn, activeVideo.aid > 0 else { return }
        interactionLoading = true
        defer { interactionLoading = false }
        interaction = try? await BilibiliAPI.shared.interactionState(
            aid: activeVideo.aid,
            cookie: bilibili.cookie
        )
    }

    @MainActor private func loadDanmaku() async {
        guard settings.bilibiliDanmakuEnabled, let cid = activeVideo.cid, cid > 0 else {
            danmakuCues = []
            return
        }
        danmakuCues = (try? await BilibiliAPI.shared.danmaku(
            cid: cid,
            cookie: bilibili.cookie
        )) ?? []
    }

    @MainActor private func toggleLike() async {
        guard bilibili.isLoggedIn, activeVideo.aid > 0 else {
            interactionMessage = "请先登录 B 站"
            return
        }
        let next = !(interaction?.isLiked ?? false)
        interactionLoading = true
        defer { interactionLoading = false }
        do {
            try await BilibiliAPI.shared.setVideoLike(
                aid: activeVideo.aid,
                liked: next,
                cookie: bilibili.cookie
            )
            let current = interaction ?? BilibiliAPI.InteractionState(
                isLiked: false,
                coinCount: 0,
                isFavorited: false
            )
            interaction = BilibiliAPI.InteractionState(
                isLiked: next,
                coinCount: current.coinCount,
                isFavorited: current.isFavorited
            )
            interactionMessage = next ? "已点赞" : "已取消点赞"
        } catch {
            interactionMessage = "点赞失败，请稍后重试"
        }
    }

    @MainActor private func addCoin() async {
        guard bilibili.isLoggedIn, activeVideo.aid > 0 else {
            interactionMessage = "请先登录 B 站"
            return
        }
        interactionLoading = true
        defer { interactionLoading = false }
        do {
            try await BilibiliAPI.shared.addVideoCoin(
                aid: activeVideo.aid,
                cookie: bilibili.cookie
            )
            let current = interaction ?? BilibiliAPI.InteractionState(
                isLiked: false,
                coinCount: 0,
                isFavorited: false
            )
            interaction = BilibiliAPI.InteractionState(
                isLiked: current.isLiked,
                coinCount: max(1, current.coinCount),
                isFavorited: current.isFavorited
            )
            interactionMessage = "已投币 1 枚"
        } catch {
            interactionMessage = "投币失败，请稍后重试"
        }
    }

    @MainActor private func toggleFavorite() async {
        guard bilibili.isLoggedIn, activeVideo.aid > 0 else {
            interactionMessage = "请先登录 B 站"
            return
        }
        let next = !(interaction?.isFavorited ?? false)
        interactionLoading = true
        defer { interactionLoading = false }
        do {
            try await BilibiliAPI.shared.setVideoFavorite(
                aid: activeVideo.aid,
                favorited: next,
                cookie: bilibili.cookie
            )
            let current = interaction ?? BilibiliAPI.InteractionState(
                isLiked: false,
                coinCount: 0,
                isFavorited: false
            )
            interaction = BilibiliAPI.InteractionState(
                isLiked: current.isLiked,
                coinCount: current.coinCount,
                isFavorited: next
            )
            interactionMessage = next ? "已收藏到默认收藏夹" : "已取消收藏"
        } catch {
            interactionMessage = "收藏失败，请检查登录状态"
        }
    }

    @MainActor private func submitComment() async {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bilibili.isLoggedIn, activeVideo.aid > 0, !text.isEmpty else {
            interactionMessage = "请登录后输入评论"
            return
        }
        commentPosting = true
        defer { commentPosting = false }
        do {
            try await BilibiliAPI.shared.postComment(
                aid: activeVideo.aid,
                message: text,
                cookie: bilibili.cookie
            )
            commentText = ""
            interactionMessage = "评论已发送"
            if selectedTab == 1 {
                await loadComments()
            }
        } catch {
            interactionMessage = "评论发送失败，请稍后重试"
        }
    }
    @MainActor private func loadPlayback(quality: Int?, video: BilibiliAPI.Video? = nil, muxed: Bool = false) async {
        isLoading = true
        do {
            let playback = try await BilibiliAPI.shared.playback(for: video ?? activeVideo, quality: quality, muxed: muxed, cookie: bilibili.cookie)
            qualities = playback.qualities
            selectedQuality = playback.quality > 0 ? playback.quality : nil
            playbackURL = playback.url
            playbackAudioURL = playback.audioURL
            playerToken = UUID()
            errorMessage = nil
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func loadAudioPlayback(quality: Int?) async {
        isLoading = true
        audioLoading = true
        defer { audioLoading = false }
        do {
            let playback = try await BilibiliAPI.shared.audioPlayback(
                for: activeVideo,
                quality: quality,
                cookie: bilibili.cookie
            )
            audioPlaybackURL = playback.url
            audioQualities = playback.qualities
            selectedAudioQuality = playback.quality.code
            playerToken = UUID()
            errorMessage = nil
            isLoading = false
        } catch {
            isLoading = false
            audioPlaybackURL = nil
            audioQualities = []
            selectedAudioQuality = nil
            if listenOnly {
                listenOnly = false
            }
            errorMessage = "音频轨不可用，已切回视频播放：\(error.localizedDescription)"
        }
    }
    @MainActor private func loadSubtitle(_ subtitle: BilibiliAPI.Subtitle) async {
        subtitleLoading = true
        defer { subtitleLoading = false }
        do {
            subtitleCues = try await BilibiliAPI.shared.subtitleCues(for: subtitle, cookie: bilibili.cookie)
            selectedSubtitle = subtitle
        } catch {
            subtitleCues = []
            selectedSubtitle = nil
            ToastCenter.shared.show("字幕加载失败，请稍后重试")
        }
    }

    @MainActor private func loadComments() async {
        guard activeVideo.aid > 0 else { return }
        commentsLoading = true
        comments = (try? await BilibiliAPI.shared.comments(aid: activeVideo.aid, sort: commentSort, cookie: bilibili.cookie).comments) ?? []
        commentsLoading = false
    }
}

private struct BilibiliCommentRow: View {
    let comment: BilibiliAPI.Comment
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAsyncImage(url: comment.avatarURL?.resizedImageURL(128)).frame(width: 36, height: 36).clipShape(Circle())
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(comment.author).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(comment.publishedAt.map { Self.dateFormatter.string(from: $0) } ?? "").font(.caption2).foregroundStyle(.tertiary)
                }
                Text(comment.message).font(.body).fixedSize(horizontal: false, vertical: true)
                Label("\(comment.likeCount)", systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"; return formatter
    }()
}
#endif
