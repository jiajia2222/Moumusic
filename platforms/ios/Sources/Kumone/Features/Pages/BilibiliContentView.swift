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
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BilibiliContentViewModel()
    @State private var selectedVideo: BilibiliAPI.Video?
    @State private var showLive = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    liveEntry
                    searchField
                    feedPicker
                    if model.feed == .recommend { recommendationSourcePicker }
                    model.feed == .ranking ? AnyView(rankingTabs) : AnyView(categoryTabs)
                    if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { searchTypePicker }

                    if model.isLoading && model.videos.isEmpty && model.users.isEmpty && model.collections.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 280)
                    } else if let errorMessage = model.errorMessage,
                              model.videos.isEmpty && model.users.isEmpty && model.collections.isEmpty {
                        ErrorStateView(message: errorMessage) {
                            Task { await model.search(cookie: bilibili.cookie) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 280)
                    } else if model.isSearching {
                        resultContent
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
        .navigationTitle("哔哩哔哩")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("关闭哔哩哔哩")
            }
        }
        .task {
            model.recommendationSource = settings.bilibiliRecommendationSource
            if model.videos.isEmpty {
                await model.loadPopular(cookie: bilibili.cookie,
                                       source: settings.bilibiliRecommendationSource)
            }
        }
        .sheet(item: $selectedVideo) { video in
            NavigationStack {
                BilibiliVideoDetailView(video: video)
                    .environmentObject(bilibili)
                    .environmentObject(settings)
            }
        }
        .sheet(isPresented: $showLive) {
            NavigationStack {
                BilibiliLiveView()
                    .environmentObject(bilibili)
            }
        }
    }

    private var liveEntry: some View {
        Button { showLive = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("B 站直播").font(.headline)
                    Text("热门直播、分区浏览与直播间搜索")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            TextField("搜索视频、UP 主或合集", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await model.search(cookie: bilibili.cookie) } }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    Task { await model.search(cookie: bilibili.cookie) }
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .accessibilityLabel("清除搜索")
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
        .padding(.horizontal, Theme.Layout.contentInset)
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
        HStack(spacing: 12) {
            Label("推荐客户端", systemImage: "sparkles.tv")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
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
                HStack(spacing: 6) {
                    Text(model.recommendationSource.displayName)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                }
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Theme.accent.opacity(0.12), in: Capsule())
            }
            .accessibilityLabel("选择 B 站推荐客户端")
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.vertical, 2)
        Text(model.recommendationSource.explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Layout.contentInset)
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

    private var searchTypePicker: some View {
        Picker("搜索类型", selection: Binding(
            get: { model.tab },
            set: { model.selectTab($0, cookie: bilibili.cookie) }
        )) {
            ForEach(BilibiliContentViewModel.Tab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private var contentTitle: String {
        switch model.feed {
        case .recommend: return model.recommendationSource == .app ? "App 推荐" : "网页版推荐"
        case .ranking: return "\(model.rankingCategory)排行榜"
        case .partition: return "\(model.category)分区"
        }
    }

    @ViewBuilder private var resultContent: some View {
        switch model.tab {
        case .videos:
            if model.videos.isEmpty { EmptyStateView(icon: "play.rectangle", title: "没有找到视频") }
            else { videoGrid(model.videos) }
        case .users:
            if model.users.isEmpty { EmptyStateView(icon: "person.2", title: "没有找到 UP 主") }
            else {
                LazyVStack(spacing: 10) { ForEach(model.users) { BilibiliUserRow(user: $0) } }
                    .padding(.horizontal, Theme.Layout.contentInset)
            }
        case .collections:
            if model.collections.isEmpty { EmptyStateView(icon: "rectangle.stack", title: "没有找到合集") }
            else {
                LazyVStack(spacing: 10) { ForEach(model.collections) { BilibiliCollectionRow(collection: $0) } }
                    .padding(.horizontal, Theme.Layout.contentInset)
            }
        }
    }

    private func videoGrid(_ videos: [BilibiliAPI.Video]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 18) {
            ForEach(videos) { video in
                Button { selectedVideo = video } label: { BilibiliVideoCard(video: video) }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }
}

struct BilibiliVideoCard: View {
    let video: BilibiliAPI.Video
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                CachedAsyncImage(url: video.coverURL?.resizedImageURL(640))
                    .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                HStack {
                    Label(Formatters.playCount(video.playCount), systemImage: "play.fill")
                    Spacer()
                    Text(video.durationText)
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(8)
                .frame(maxWidth: .infinity).background(.black.opacity(0.42))
            }
            Text(video.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
            Text(video.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
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
    @State private var playbackURL: URL?
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
    @State private var showFullScreen = false
    @State private var showDownloadSheet = false

    private var activeVideo: BilibiliAPI.Video { detail ?? video }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PiliPlusVideoPlayerView(
                        url: playbackURL,
                        cues: subtitleCues,
                        posterURL: activeVideo.coverURL,
                        audioOnly: listenOnly,
                        autoPlay: playbackURL != nil,
                        onError: { errorMessage = $0 },
                        onFullscreen: { showFullScreen = true }
                    )
                    .id(playerToken)
                    .frame(height: 244)
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
        .onChange(of: settings.bilibiliVideoEnabled) { if !$0 { listenOnly = true } }
        .fullScreenCover(isPresented: $showFullScreen) {
            PiliPlusFullScreenPlayer(url: playbackURL, cues: subtitleCues, posterURL: activeVideo.coverURL, audioOnly: listenOnly)
        }
        .sheet(isPresented: $showDownloadSheet) {
            BilibiliDownloadSheet(video: activeVideo, videoQualities: qualities)
                .environmentObject(bilibili)
        }
    }

    private var playerOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if settings.bilibiliAudioEnabled {
                    Button { listenOnly.toggle() } label: {
                        Label(listenOnly ? "听视频音频" : "看视频", systemImage: listenOnly ? "headphones" : "play.rectangle")
                    }.buttonStyle(.bordered)
                }
                if playbackURL != nil {
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
                if !qualities.isEmpty {
                    Menu {
                        ForEach(qualities) { quality in
                            Button {
                                Task { await loadPlayback(quality: quality.code) }
                            } label: {
                                quality.code == selectedQuality ? AnyView(Label(quality.title, systemImage: "checkmark")) : AnyView(Text(quality.title))
                            }
                        }
                    } label: { Label(currentQualityTitle, systemImage: "rectangle.inset.filled") }
                        .buttonStyle(.bordered)
                }
                if !activeVideo.subtitles.isEmpty {
                    Menu {
                        Button("关闭字幕") { selectedSubtitle = nil; subtitleCues = [] }
                        Divider()
                        ForEach(activeVideo.subtitles) { subtitle in
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
            }
        }
        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent).padding(.horizontal, 18)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(activeVideo.title).font(.title3.weight(.semibold))
            Text("\(Formatters.playCount(activeVideo.playCount)) 次播放 · \(activeVideo.author)").font(.subheadline).foregroundStyle(.secondary)
            if !activeVideo.description.isEmpty {
                Text(activeVideo.description).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !activeVideo.subtitles.isEmpty {
                Label("已发现 \(activeVideo.subtitles.count) 条字幕轨道，可选择普通、翻译或 AI 字幕", systemImage: "captions.bubble")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 18)
    }

    private var currentQualityTitle: String {
        guard let selectedQuality else { return "画质" }
        return qualities.first(where: { $0.code == selectedQuality })?.title ?? "画质"
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
        errorMessage = nil
        do {
            let loaded = try await BilibiliAPI.shared.videoDetail(bvid: video.bvid, cookie: bilibili.cookie)
            detail = loaded
            if !settings.bilibiliVideoEnabled { listenOnly = true }
            await loadPlayback(quality: selectedQuality, video: loaded)
            if let subtitle = preferredSubtitle(in: loaded.subtitles) {
                await loadSubtitle(subtitle)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func preferredSubtitle(in subtitles: [BilibiliAPI.Subtitle]) -> BilibiliAPI.Subtitle? {
        subtitles.first(where: { !$0.isAIGenerated && !$0.isTranslated })
            ?? subtitles.first(where: { $0.isAIGenerated && !$0.isTranslated })
            ?? subtitles.first(where: { $0.isTranslated })
            ?? subtitles.first
    }

    @MainActor private func loadPlayback(quality: Int?, video: BilibiliAPI.Video? = nil) async {
        do {
            let playback = try await BilibiliAPI.shared.playback(for: video ?? activeVideo, quality: quality, cookie: bilibili.cookie)
            qualities = playback.qualities
            selectedQuality = playback.quality
            playbackURL = playback.url
            playerToken = UUID()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
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

/// PiliPlus is Flutter and cannot be linked into this Swift Package without
/// embedding a second Flutter engine.  This is the native Moumusic port of
/// its player behaviour: custom controls, inline/full-screen playback, and
/// selectable normal/translated/AI subtitle tracks.
struct PiliPlusVideoPlayerView: UIViewRepresentable {
    let url: URL?
    let cues: [BilibiliAPI.SubtitleCue]
    let posterURL: String?
    let audioOnly: Bool
    let autoPlay: Bool
    var onError: ((String) -> Void)?
    var onFullscreen: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onError: onError, onFullscreen: onFullscreen)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.userContentController.add(context.coordinator, name: "player")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        context.coordinator.webView = webView
        context.coordinator.load(url: url, cues: cues, posterURL: posterURL, audioOnly: audioOnly, autoPlay: autoPlay)
        return webView
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onError = onError
        context.coordinator.onFullscreen = onFullscreen
        context.coordinator.update(url: url, cues: cues, posterURL: posterURL, audioOnly: audioOnly, autoPlay: autoPlay)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onError: ((String) -> Void)?
        var onFullscreen: (() -> Void)?
        private var currentURL: URL?
        private var isLoaded = false
        private var autoplayRequested = false
        private var shouldAutoplay = false

        init(onError: ((String) -> Void)?, onFullscreen: (() -> Void)?) {
            self.onError = onError
            self.onFullscreen = onFullscreen
        }

        func load(url: URL?, cues: [BilibiliAPI.SubtitleCue], posterURL: String?, audioOnly: Bool, autoPlay: Bool = false) {
            currentURL = url
            isLoaded = false
            autoplayRequested = false
            shouldAutoplay = autoPlay
            webView?.loadHTMLString(Self.html(url: url, cues: cues, posterURL: posterURL, audioOnly: audioOnly), baseURL: URL(string: "https://www.bilibili.com/"))
        }

        func update(url: URL?, cues: [BilibiliAPI.SubtitleCue], posterURL: String?, audioOnly: Bool, autoPlay: Bool) {
            if currentURL != url {
                load(url: url, cues: cues, posterURL: posterURL, audioOnly: audioOnly, autoPlay: autoPlay)
                return
            }
            shouldAutoplay = autoPlay
            guard isLoaded else { return }
            let cueObjects: [[String: Any]] = cues.map {
                ["start": $0.start, "end": $0.end, "text": $0.text]
            }
            let cuesJSON = Self.jsonString(cueObjects)
            let posterJSON = Self.jsonString(posterURL ?? "")
            webView?.evaluateJavaScript("window.setCues(\(cuesJSON)); window.setPoster(\(posterJSON)); window.setAudioOnly(\(audioOnly));")
            if autoPlay && !autoplayRequested {
                autoplayRequested = true
                webView?.evaluateJavaScript("window.requestPlayback();")
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any], let type = payload["type"] as? String else { return }
            switch type {
            case "error":
                let text = payload["message"] as? String ?? "B 站播放器加载失败"
                Task { @MainActor [weak self] in self?.onError?(text) }
            case "fullscreen":
                Task { @MainActor [weak self] in self?.onFullscreen?() }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            guard shouldAutoplay, !autoplayRequested else { return }
            autoplayRequested = true
            webView.evaluateJavaScript("window.requestPlayback();")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor [weak self] in self?.onError?(error.localizedDescription) }
        }

        private static func jsonString(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), let value = String(data: data, encoding: .utf8) else { return "null" }
            return value.replacingOccurrences(of: "<", with: "\\u003c")
        }

        private static func html(url: URL?, cues: [BilibiliAPI.SubtitleCue], posterURL: String?, audioOnly: Bool) -> String {
            let sourceJSON = jsonString(url?.absoluteString ?? "")
            let posterJSON = jsonString(posterURL ?? "")
            let cueObjects: [[String: Any]] = cues.map {
                ["start": $0.start, "end": $0.end, "text": $0.text]
            }
            let cueJSON = jsonString(cueObjects)
            let audioJSON = audioOnly ? "true" : "false"
            let surfaceClass = audioOnly ? "audioOnly" : ""
            return """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><style>
            *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#090909}body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;color:#fff}#surface{position:relative;width:100%;height:100%;overflow:hidden;background:#090909}#poster{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;opacity:.72;filter:saturate(.9)}video{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000}.audioOnly video{opacity:0}#subtitle{position:absolute;left:18px;right:18px;bottom:58px;padding:8px 12px;border-radius:12px;background:rgba(0,0,0,.62);text-align:center;font-size:16px;font-weight:600;line-height:1.35;text-shadow:0 1px 3px #000;display:none}#controls{position:absolute;left:12px;right:12px;bottom:10px;display:flex;align-items:center;gap:8px;padding:7px 10px;border:1px solid rgba(255,255,255,.18);border-radius:18px;background:rgba(22,22,22,.72);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px)}button{border:0;color:#fff;background:transparent;min-width:32px;min-height:32px;font-size:17px}#time{font-size:11px;color:rgba(255,255,255,.78);white-space:nowrap;font-variant-numeric:tabular-nums}input[type=range]{min-width:0;flex:1;accent-color:#ff4d5b}
            </style></head><body><div id="surface" class="\(surfaceClass)"><img id="poster" alt=""><video id="video" playsinline webkit-playsinline preload="metadata" crossorigin="anonymous"></video><div id="subtitle"></div><div id="controls"><button id="play">▶︎</button><span id="time">00:00 / 00:00</span><input id="seek" type="range" min="0" max="1" value="0" step="0.01"><button id="full">⛶</button></div></div><script>
            const video=document.getElementById('video'),surface=document.getElementById('surface'),poster=document.getElementById('poster'),subtitle=document.getElementById('subtitle'),play=document.getElementById('play'),seek=document.getElementById('seek'),time=document.getElementById('time');let cues=\(cueJSON),mediaURL=\(sourceJSON);function fmt(v){if(!Number.isFinite(v))return'00:00';const s=Math.max(0,Math.floor(v)),m=Math.floor(s/60);return String(m).padStart(2,'0')+':'+String(s%60).padStart(2,'0')}function renderSubtitle(){const now=video.currentTime||0,cue=cues.find(x=>now>=Number(x.start)&&now<=Number(x.end));subtitle.textContent=cue?.text||'';subtitle.style.display=cue?.text?'block':'none'}function setPoster(v){if(v){poster.src=v;poster.style.display='block'}else{poster.removeAttribute('src');poster.style.display='none'}}function setAudioOnly(v){surface.classList.toggle('audioOnly',!!v)}function setCues(v){cues=Array.isArray(v)?v:[];renderSubtitle()}function setSource(v){if(!v)return;mediaURL=v;video.src=v;video.load()}function requestPlayback(){if(mediaURL)video.play().catch(()=>{})}play.addEventListener('click',()=>video.paused?requestPlayback():video.pause());seek.addEventListener('input',()=>{if(video.duration)video.currentTime=Number(seek.value)*video.duration});document.getElementById('full').addEventListener('click',()=>window.webkit?.messageHandlers?.player?.postMessage({type:'fullscreen'}));video.addEventListener('timeupdate',()=>{if(video.duration)seek.value=video.currentTime/video.duration;time.textContent=fmt(video.currentTime)+' / '+fmt(video.duration);renderSubtitle()});video.addEventListener('play',()=>play.textContent='Ⅱ');video.addEventListener('pause',()=>play.textContent='▶︎');window.setCues=setCues;window.setPoster=setPoster;window.setAudioOnly=setAudioOnly;window.requestPlayback=requestPlayback;setPoster(\(posterJSON));setAudioOnly(\(audioJSON));setSource(\(sourceJSON));
            </script></body></html>
            """
            #if os(Linux)
            let urlJSON = jsonString(url?.absoluteString ?? "")
            let posterJSON = jsonString(posterURL ?? "")
            let cueObjects: [[String: Any]] = cues.map {
                ["start": $0.start, "end": $0.end, "text": $0.text]
            }
            let cuesJSON = jsonString(cueObjects)
            let audioJSON = audioOnly ? "true" : "false"
            let surfaceClass = audioOnly ? "audioOnly" : ""
            return """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><style>
            *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#090909}body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;color:#fff}#surface{position:relative;width:100%;height:100%;overflow:hidden;background:#090909}#poster{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;opacity:.72;filter:saturate(.9)}#shade{position:absolute;inset:0;background:linear-gradient(180deg,rgba(0,0,0,.08),rgba(0,0,0,.12)45%,rgba(0,0,0,.82));pointer-events:none}video{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000}.audioOnly video{opacity:0}#subtitle{position:absolute;left:18px;right:18px;bottom:58px;padding:8px 12px;border-radius:12px;background:rgba(0,0,0,.62);text-align:center;font-size:16px;font-weight:600;line-height:1.35;text-shadow:0 1px 3px #000;display:none}#controls{position:absolute;left:12px;right:12px;bottom:10px;display:flex;align-items:center;gap:8px;padding:7px 10px;border:1px solid rgba(255,255,255,.18);border-radius:18px;background:rgba(22,22,22,.72);backdrop-filter:blur(18px);-webkit-backdrop-filter:blur(18px)}button{border:0;color:#fff;background:transparent;min-width:32px;min-height:32px;font-size:17px}#time{font-size:11px;color:rgba(255,255,255,.78);white-space:nowrap;font-variant-numeric:tabular-nums}input[type=range]{min-width:0;flex:1;accent-color:#ff4d5b}#empty{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:rgba(255,255,255,.7);font-size:14px}
            </style></head><body><div id="surface" class="\(audioOnly ? "audioOnly" : ""\)"><img id="poster" alt=""><div id="shade"></div><video id="video" playsinline webkit-playsinline preload="metadata" crossorigin="anonymous"></video><div id="subtitle"></div><div id="empty">点击播放加载 B 站视频</div><div id="controls"><button id="play">▶︎</button><span id="time">00:00 / 00:00</span><input id="seek" type="range" min="0" max="1" value="0" step="0.01"><button id="full">⛶</button></div></div><script>
            const video=document.getElementById('video'),surface=document.getElementById('surface'),poster=document.getElementById('poster'),subtitle=document.getElementById('subtitle'),empty=document.getElementById('empty'),play=document.getElementById('play'),seek=document.getElementById('seek'),time=document.getElementById('time');let cues=\(cuesJSON),mediaURL=\(urlJSON);function send(type,extra){try{window.webkit.messageHandlers.player.postMessage(Object.assign({type:type},extra||{}))}catch(_){}}function fmt(v){if(!Number.isFinite(v))return'00:00';const s=Math.max(0,Math.floor(v)),m=Math.floor(s/60);return String(m).padStart(2,'0')+':'+String(s%60).padStart(2,'0')}function setPoster(v){if(v){poster.src=v;poster.style.display='block'}else{poster.removeAttribute('src');poster.style.display='none'}}function setAudioOnly(v){surface.classList.toggle('audioOnly',!!v)}function setCues(v){cues=Array.isArray(v)?v:[];renderSubtitle()}function renderSubtitle(){const now=video.currentTime||0,cue=cues.find(x=>now>=Number(x.start)&&now<=Number(x.end));if(cue&&cue.text){subtitle.textContent=cue.text;subtitle.style.display='block'}else{subtitle.textContent='';subtitle.style.display='none'}}function requestPlayback(){if(!mediaURL)return;video.play().then(()=>{empty.style.display='none'}).catch(()=>{})}function setSource(v){if(!v)return;mediaURL=v;video.src=v;video.load();empty.style.display='none'}play.addEventListener('click',()=>{if(video.paused)requestPlayback();else video.pause()});seek.addEventListener('input',()=>{if(video.duration)video.currentTime=Number(seek.value)*video.duration});document.getElementById('full').addEventListener('click',()=>{surface.classList.toggle('full');send('fullscreen',{value:surface.classList.contains('full')})});video.addEventListener('loadedmetadata',()=>{time.textContent=fmt(video.currentTime)+' / '+fmt(video.duration)});video.addEventListener('timeupdate',()=>{if(video.duration)seek.value=video.currentTime/video.duration;time.textContent=fmt(video.currentTime)+' / '+fmt(video.duration);renderSubtitle()});video.addEventListener('play',()=>{play.textContent='Ⅱ';empty.style.display='none'});video.addEventListener('pause',()=>{play.textContent='▶︎'});video.addEventListener('error',()=>send('error',{message:'B 站视频流无法播放，请切换画质或稍后重试'}));window.setCues=setCues;window.setPoster=setPoster;window.setAudioOnly=setAudioOnly;window.requestPlayback=requestPlayback;setPoster(\(posterJSON));setAudioOnly(\(audioJSON));setSource(\(urlJSON));</script></body></html>
            """
            #endif
        }
    }
}

struct PiliPlusFullScreenPlayer: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL?
    let cues: [BilibiliAPI.SubtitleCue]
    let posterURL: String?
    let audioOnly: Bool
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            PiliPlusVideoPlayerView(url: url, cues: cues, posterURL: posterURL, audioOnly: audioOnly, autoPlay: true).ignoresSafeArea()
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white).padding(16) }
                .accessibilityLabel("退出全屏")
        }
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
