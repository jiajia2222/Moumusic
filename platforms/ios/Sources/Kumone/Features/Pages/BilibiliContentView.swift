#if os(iOS)
import AVKit
import SwiftUI

@MainActor
private final class BilibiliContentViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case videos = "视频"
        case users = "UP主"
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
    @Published var category = "推荐"

    private var requestTask: Task<Void, Never>?

    func loadPopular(cookie: String?) async {
        guard !isSearching else { return }
        requestTask?.cancel()
        isLoading = true
        errorMessage = nil
        do {
            videos = try await BilibiliAPI.shared.popularVideos(cookie: cookie)
            if videos.isEmpty { errorMessage = "暂时没有热门视频" }
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
        isLoading = false
    }

    func selectCategory(_ category: String, cookie: String?) {
        self.category = category
        query = ""
        isSearching = false
        requestTask?.cancel()
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            isLoading = true
            errorMessage = nil
            do {
                if category == "推荐" || category == "直播" {
                    videos = try await BilibiliAPI.shared.popularVideos(cookie: cookie)
                } else if let categoryID = Self.categoryIDs[category] {
                    videos = try await BilibiliAPI.shared.rankedVideos(categoryID: categoryID, cookie: cookie)
                } else {
                    videos = []
                }
                if videos.isEmpty { errorMessage = "暂时没有相关视频" }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            isLoading = false
        }
        Task { await requestTask?.value }
    }

    func search(cookie: String?) async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            isSearching = false
            await loadPopular(cookie: cookie)
            return
        }
        requestTask?.cancel()
        let tab = self.tab
        isSearching = true
        isLoading = true
        errorMessage = nil
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
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
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            isLoading = false
        }
        await requestTask?.value
    }

    func selectTab(_ tab: Tab, cookie: String?) {
        self.tab = tab
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await search(cookie: cookie) }
    }

    private var isEmptyForCurrentTab: Bool {
        switch tab {
        case .videos: return videos.isEmpty
        case .users: return users.isEmpty
        case .collections: return collections.isEmpty
        }
    }

    private static let categoryIDs = [
        "音乐": 3,
        "游戏": 4,
        "动画": 1,
        "知识": 36
    ]
}

struct BilibiliContentView: View {
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @StateObject private var model = BilibiliContentViewModel()
    @State private var selectedVideo: BilibiliAPI.Video?

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    searchField
                    categoryTabs

                    if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        searchTypePicker
                    }

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
                        SectionHeader(title: "热门推荐")
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
        .task {
            if model.videos.isEmpty { await model.loadPopular(cookie: bilibili.cookie) }
        }
        .sheet(item: $selectedVideo) { video in
            NavigationStack {
                BilibiliVideoDetailView(video: video)
                    .environmentObject(bilibili)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("搜索视频、UP主或合集", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await model.search(cookie: bilibili.cookie) } }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    Task { await model.loadPopular(cookie: bilibili.cookie) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
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

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                ForEach(["推荐", "直播", "音乐", "游戏", "动画", "知识"], id: \.self) { title in
                    Button {
                        model.selectCategory(title, cookie: bilibili.cookie)
                    } label: {
                        Text(title)
                            .font(.headline.weight(model.category == title ? .semibold : .regular))
                            .foregroundStyle(model.category == title ? Theme.accent : .secondary)
                            .padding(.bottom, 8)
                            .overlay(alignment: .bottom) {
                                if model.category == title {
                                    Capsule().fill(Theme.accent).frame(width: 32, height: 3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
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
            ForEach(BilibiliContentViewModel.Tab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    @ViewBuilder
    private var resultContent: some View {
        switch model.tab {
        case .videos:
            if model.videos.isEmpty {
                EmptyStateView(icon: "play.rectangle", title: "没有找到视频")
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                videoGrid(model.videos)
            }
        case .users:
            if model.users.isEmpty {
                EmptyStateView(icon: "person.2", title: "没有找到 UP 主")
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.users) { user in
                        BilibiliUserRow(user: user)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
        case .collections:
            if model.collections.isEmpty {
                EmptyStateView(icon: "rectangle.stack", title: "没有找到合集")
                    .frame(maxWidth: .infinity, minHeight: 280)
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

    private func videoGrid(_ videos: [BilibiliAPI.Video]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 18) {
            ForEach(videos) { video in
                Button { selectedVideo = video } label: {
                    BilibiliVideoCard(video: video)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }
}

private struct BilibiliVideoCard: View {
    let video: BilibiliAPI.Video

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                CachedAsyncImage(url: video.coverURL?.resizedImageURL(640))
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                HStack {
                    Label(Formatters.playCount(video.playCount), systemImage: "play.fill")
                    Spacer()
                    Text(video.durationText)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.42))
            }
            Text(video.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(video.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct BilibiliUserRow: View {
    let user: BilibiliAPI.User

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: user.avatarURL?.resizedImageURL(160))
                .frame(width: 54, height: 54)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(user.name).font(.headline)
                Text(user.signature.isEmpty ? "UP 主" : user.signature)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if user.followerCount > 0 {
                Text("粉丝 (Formatters.playCount(user.followerCount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct BilibiliCollectionRow: View {
    let collection: BilibiliAPI.Collection

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: collection.coverURL?.resizedImageURL(240))
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(collection.title).font(.headline).lineLimit(2)
                Text(collection.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text("\(collection.itemCount) 个")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct BilibiliVideoDetailView: View {
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @Environment(\.dismiss) private var dismiss
    let video: BilibiliAPI.Video

    @State private var detail: BilibiliAPI.Video?
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedTab = 0
    @State private var comments: [BilibiliAPI.Comment] = []
    @State private var commentSort: BilibiliAPI.CommentSort = .hot
    @State private var commentsLoading = false

    private var activeVideo: BilibiliAPI.Video { detail ?? video }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    videoPlayer
                    infoBar
                    Picker("视频内容", selection: $selectedTab) {
                        Text("简介").tag(0)
                        Text("评论").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    if selectedTab == 0 { introduction } else { commentList }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("视频详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var videoPlayer: some View {
        if let player {
            VideoPlayer(player: player)
                .frame(height: 235)
                .background(.black)
        } else {
            ZStack {
                CachedAsyncImage(url: activeVideo.coverURL?.resizedImageURL(960))
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .clipped()
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("加载视频", systemImage: "play.fill")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
            .frame(height: 235)
            .background(.black)
        }
    }

    private var infoBar: some View {
        HStack {
            Label("高清", systemImage: "gearshape")
            Spacer()
            Link(destination: URL(string: "https://www.bilibili.com/video/\(activeVideo.bvid)")!) {
                Label("在哔哩哔哩打开", systemImage: "safari")
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 18)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(activeVideo.title)
                .font(.title3.weight(.semibold))
            Text("\(Formatters.playCount(activeVideo.playCount)) 次播放 · \(activeVideo.author)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !activeVideo.description.isEmpty {
                Text(activeVideo.description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
    }

    private var commentList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("评论排序", selection: Binding(
                get: { commentSort },
                set: { value in commentSort = value; Task { await loadComments() } }
            )) {
                Text("热门").tag(BilibiliAPI.CommentSort.hot)
                Text("最新").tag(BilibiliAPI.CommentSort.latest)
            }
            .pickerStyle(.segmented)

            if commentsLoading && comments.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if comments.isEmpty {
                EmptyStateView(icon: "bubble.left", title: "暂无评论")
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ForEach(comments) { comment in
                    BilibiliCommentRow(comment: comment)
                }
            }
        }
        .padding(.horizontal, 18)
        .task(id: selectedTab) {
            if selectedTab == 1 && comments.isEmpty { await loadComments() }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await BilibiliAPI.shared.videoDetail(bvid: video.bvid, cookie: bilibili.cookie)
            detail = loaded
            if let url = try? await BilibiliAPI.shared.playableURL(for: loaded, cookie: bilibili.cookie) {
                let asset = AVURLAsset(url: url, options: [
                    AVURLAssetHTTPHeaderFieldsKey: [
                        "Referer": "https://www.bilibili.com/",
                        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
                    ]
                ])
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player?.play()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func loadComments() async {
        guard activeVideo.aid > 0 else { return }
        commentsLoading = true
        comments = (try? await BilibiliAPI.shared.comments(
            aid: activeVideo.aid, sort: commentSort, cookie: bilibili.cookie
        ).comments) ?? []
        commentsLoading = false
    }
}

private struct BilibiliCommentRow: View {
    let comment: BilibiliAPI.Comment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAsyncImage(url: comment.avatarURL?.resizedImageURL(128))
                .frame(width: 36, height: 36)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(comment.author).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(comment.publishedAt.map { Self.dateFormatter.string(from: $0) } ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(comment.message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Label("\(comment.likeCount)", systemImage: "hand.thumbsup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
#endif
