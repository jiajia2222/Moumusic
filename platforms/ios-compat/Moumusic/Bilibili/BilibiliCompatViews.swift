import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// iOS 15–18 screens for the Bilibili module: feeds, search, live, video detail, account.
// Written against iOS 15 SwiftUI (NavigationView, no NavigationStack / ViewThatFits / lineLimit ranges).

private func biliKey(_ subtitle: BilibiliAPI.Subtitle) -> String {
    "\(subtitle.language.lowercased())|\(subtitle.isAIGenerated)|\(subtitle.isTranslated)"
}

// MARK: - Root

struct CompatBilibiliRootView: View {
    let onClose: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case recommend = "推荐"
        case popular = "热门"
        case live = "直播"
        case search = "搜索"
        case account = "我的"
        var id: String { rawValue }
    }

    @ObservedObject private var session = BilibiliSessionStore.shared
    @ObservedObject private var toast = ToastCenter.shared
    @State private var tab: Tab = .recommend

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                switch tab {
                case .recommend: BiliVideoFeed(kind: .recommend)
                case .popular: BiliVideoFeed(kind: .popular)
                case .live: BiliLiveFeed()
                case .search: BiliSearchView()
                case .account: BiliAccountView()
                }
            }
            .navigationTitle("哔哩哔哩")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭", action: onClose)
                }
            }
        }
        .navigationViewStyle(.stack)
        .environmentObject(session)
        .overlay(alignment: .bottom) {
            if let message = toast.message {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast.message)
    }
}

// MARK: - Cards

private struct BiliVideoCard: View {
    let video: BilibiliAPI.Video

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: video.coverURL?.resizedImageURL(480), animated: false)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                if !video.durationText.isEmpty {
                    Text(video.durationText)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(video.title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(video.author) · \(Formatters.playCount(video.playCount))播放")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

private struct BiliVideoGrid: View {
    let videos: [BilibiliAPI.Video]
    let onSelect: (BilibiliAPI.Video) -> Void
    var onLast: (() -> Void)?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(videos) { video in
                Button { onSelect(video) } label: { BiliVideoCard(video: video) }
                    .buttonStyle(.plain)
                    .onAppear { if video.id == videos.last?.id { onLast?() } }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 24)
    }
}

// MARK: - Feeds

private struct BiliVideoFeed: View {
    enum Kind { case recommend, popular }
    let kind: Kind

    @EnvironmentObject private var session: BilibiliSessionStore
    @State private var videos: [BilibiliAPI.Video] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var error: String?
    @State private var selected: BilibiliAPI.Video?

    var body: some View {
        ScrollView {
            if let error, videos.isEmpty {
                ErrorStateView(message: error) { Task { await reload() } }
                    .frame(minHeight: 300)
            } else if videos.isEmpty && isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            } else {
                BiliVideoGrid(videos: videos, onSelect: { selected = $0 }, onLast: { Task { await loadMore() } })
            }
        }
        .refreshable { await reload() }
        .task { if videos.isEmpty { await reload() } }
        .sheet(item: $selected) { video in
            CompatBiliVideoView(video: video)
        }
    }

    private func fetch(page: Int) async throws -> [BilibiliAPI.Video] {
        switch kind {
        case .recommend:
            return try await BilibiliAPI.shared.recommendedVideos(source: .web, page: page, cookie: session.cookie)
        case .popular:
            return try await BilibiliAPI.shared.popularVideos(page: page, cookie: session.cookie)
        }
    }

    @MainActor private func reload() async {
        isLoading = true
        error = nil
        page = 1
        do {
            videos = try await fetch(page: 1)
        } catch {
            self.error = "加载失败，请下拉重试"
        }
        isLoading = false
    }

    @MainActor private func loadMore() async {
        guard !isLoading, !videos.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        if let more = try? await fetch(page: page + 1) {
            page += 1
            let known = Set(videos.map(\.id))
            videos += more.filter { !known.contains($0.id) }
        }
    }
}

private struct BiliLiveCard: View {
    let room: BilibiliAPI.LiveRoom

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: room.coverURL?.resizedImageURL(480), animated: false)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                Text("\(Formatters.playCount(room.online)) 人气")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(room.title).font(.subheadline.weight(.semibold)).foregroundColor(.primary).lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(room.userName) · \(room.areaName)").font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
    }
}

private struct BiliLiveFeed: View {
    @EnvironmentObject private var session: BilibiliSessionStore
    @State private var rooms: [BilibiliAPI.LiveRoom] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var selected: BilibiliAPI.LiveRoom?
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            if let error, rooms.isEmpty {
                ErrorStateView(message: error) { Task { await reload() } }.frame(minHeight: 300)
            } else if rooms.isEmpty && isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(rooms) { room in
                        Button { selected = room } label: { BiliLiveCard(room: room) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
        }
        .refreshable { await reload() }
        .task { if rooms.isEmpty { await reload() } }
        .sheet(item: $selected) { room in CompatBiliLiveView(room: room) }
    }

    @MainActor private func reload() async {
        isLoading = true
        error = nil
        do { rooms = try await BilibiliAPI.shared.popularLiveRooms(cookie: session.cookie) } catch { self.error = "加载失败，请下拉重试" }
        isLoading = false
    }
}

// MARK: - Search

private struct BiliSearchView: View {
    @EnvironmentObject private var session: BilibiliSessionStore
    private enum Kind: String, CaseIterable, Identifiable { case video = "视频", live = "直播"; var id: String { rawValue } }
    @State private var text = ""
    @State private var kind: Kind = .video
    @State private var videos: [BilibiliAPI.Video] = []
    @State private var rooms: [BilibiliAPI.LiveRoom] = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var selectedVideo: BilibiliAPI.Video?
    @State private var selectedRoom: BilibiliAPI.LiveRoom?
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("搜索视频、直播", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                Button("搜索") { Task { await search() } }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .onChange(of: kind) { _ in Task { await search() } }

            ScrollView {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else if let message {
                    Text(message).foregroundColor(.secondary).frame(maxWidth: .infinity, minHeight: 200)
                } else if kind == .video {
                    BiliVideoGrid(videos: videos, onSelect: { selectedVideo = $0 })
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(rooms) { room in
                            Button { selectedRoom = room } label: { BiliLiveCard(room: room) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .sheet(item: $selectedVideo) { CompatBiliVideoView(video: $0) }
        .sheet(item: $selectedRoom) { CompatBiliLiveView(room: $0) }
    }

    @MainActor private func search() async {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        isLoading = true
        message = nil
        do {
            if kind == .video {
                videos = try await BilibiliAPI.shared.searchVideos(keyword: keyword, cookie: session.cookie).videos
                if videos.isEmpty { message = "没有找到相关视频" }
            } else {
                rooms = try await BilibiliAPI.shared.searchLiveRooms(keyword: keyword, cookie: session.cookie)
                if rooms.isEmpty { message = "没有找到相关直播" }
            }
        } catch {
            message = "搜索失败，请稍后重试"
        }
        isLoading = false
    }
}

// MARK: - Video detail

struct CompatBiliVideoView: View {
    let video: BilibiliAPI.Video

    @EnvironmentObject private var session: BilibiliSessionStore
    @Environment(\.presentationMode) private var presentation
    @StateObject private var model = BiliPlayerModel()
    @State private var detail: BilibiliAPI.Video?
    @State private var qualities: [BilibiliAPI.VideoQuality] = []
    @State private var selectedQuality: Int?
    @State private var alternates: [URL] = []
    @State private var currentPlayback: BilibiliAPI.Playback?
    @State private var qualityFallbackDepth = 0
    @State private var triedMuxed = false
    @State private var danmaku: [BilibiliAPI.DanmakuCue] = []
    @State private var subtitles: [BilibiliAPI.Subtitle] = []
    @State private var selectedSubtitle: BilibiliAPI.Subtitle?
    @State private var cues: [BilibiliAPI.SubtitleCue] = []
    @State private var related: [BilibiliAPI.Video] = []
    @State private var comments: [BilibiliAPI.Comment] = []
    @State private var interaction: BilibiliAPI.InteractionState?
    @State private var draft = ""
    @State private var tab = 0
    @State private var errorMessage: String?
    @State private var showFullScreen = false
    @State private var relatedSelection: BilibiliAPI.Video?

    private var active: BilibiliAPI.Video { detail ?? video }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    player
                        .aspectRatio(active.displayAspectRatio, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: active.displayAspectRatio < 1 ? UIScreen.main.bounds.height * 0.6 : nil)
                    options
                    VStack(alignment: .leading, spacing: 10) {
                        Text(active.title).font(.title3.weight(.semibold))
                        Text("\(Formatters.playCount(active.playCount)) 次播放 · \(active.author)")
                            .font(.subheadline).foregroundColor(.secondary)
                        interactionBar
                        Picker("", selection: $tab) {
                            Text("简介").tag(0)
                            Text("评论").tag(1)
                            Text("相关").tag(2)
                        }
                        .pickerStyle(.segmented)
                        if let errorMessage {
                            Text(errorMessage).font(.footnote).foregroundColor(.red)
                        }
                        tabContent
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 30)
            }
            .navigationTitle("视频详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .fullScreenCover(isPresented: $showFullScreen) {
            playerView(fullscreen: true)
                .ignoresSafeArea()
                .background(Color.black.ignoresSafeArea())
        }
        .sheet(item: $relatedSelection) { CompatBiliVideoView(video: $0) }
        .task { await bootstrap() }
        .onAppear { model.onError = { handleError($0) } }
        .onDisappear { model.stop() }
    }

    // MARK: Player

    private var player: some View { playerView(fullscreen: false) }

    private func playerView(fullscreen: Bool) -> some View {
        BiliNativePlayer(
            model: model,
            cues: cues,
            danmaku: danmaku,
            danmakuEnabled: UserDefaults.standard.object(forKey: "moumusic.bili.danmakuEnabled") as? Bool ?? true,
            subtitles: subtitles,
            selectedSubtitleID: selectedSubtitle?.id,
            onSelectSubtitle: { subtitle in
                if let subtitle { Task { await loadSubtitle(subtitle) } } else { selectedSubtitle = nil; cues = [] }
            },
            posterURL: active.coverURL,
            audioOnly: false,
            title: active.title,
            isFullscreen: fullscreen,
            rotatesInFullscreen: active.displayAspectRatio >= 1,
            onFullscreen: fullscreen ? nil : { showFullScreen = true },
            onClose: fullscreen ? { showFullScreen = false } : nil
        )
    }

    private var options: some View {
        HStack(spacing: 10) {
            if !qualities.isEmpty {
                Menu {
                    ForEach(qualities) { quality in
                        Button {
                            qualityFallbackDepth = 0
                            triedMuxed = false
                            Task { await loadPlayback(quality: quality.code) }
                        } label: {
                            if quality.code == selectedQuality {
                                Label(quality.displayTitle, systemImage: "checkmark")
                            } else {
                                Text(quality.displayTitle)
                            }
                        }
                        .disabled((quality.requiresVIP && !session.isVIP) || (quality.requiresLogin && !session.isLoggedIn))
                    }
                } label: {
                    Label(qualities.first(where: { $0.code == selectedQuality })?.displayTitle ?? "画质", systemImage: "rectangle.inset.filled")
                }
                .buttonStyle(.bordered)
            }
            if !subtitles.isEmpty {
                Menu {
                    Button("关闭字幕") { selectedSubtitle = nil; cues = [] }
                    ForEach(subtitles) { subtitle in
                        Button {
                            Task { await loadSubtitle(subtitle) }
                        } label: {
                            if subtitle.id == selectedSubtitle?.id {
                                Label(subtitle.displayTitle, systemImage: "checkmark")
                            } else {
                                Text(subtitle.displayTitle)
                            }
                        }
                    }
                } label: {
                    Label(selectedSubtitle?.displayTitle ?? "字幕", systemImage: "captions.bubble")
                }
                .buttonStyle(.bordered)
            }
            Button { showFullScreen = true } label: {
                Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private var interactionBar: some View {
        HStack(spacing: 8) {
            Button { Task { await toggleLike() } } label: {
                Label(interaction?.isLiked == true ? "已赞" : "点赞", systemImage: interaction?.isLiked == true ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            Button { Task { await coin() } } label: {
                Label((interaction?.coinCount ?? 0) > 0 ? "已投币" : "投币", systemImage: "circle")
            }
            Button { Task { await toggleFavorite() } } label: {
                Label(interaction?.isFavorited == true ? "已收藏" : "收藏", systemImage: interaction?.isFavorited == true ? "star.fill" : "star")
            }
            Button { Task { await watchLater() } } label: {
                Label("稍后看", systemImage: "clock.badge.plus")
            }
        }
        .font(.footnote)
        .buttonStyle(.bordered)
        .disabled(!session.isLoggedIn)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case 0:
            if !active.description.isEmpty {
                Text(active.description).font(.body).foregroundColor(.secondary)
            }
        case 1:
            commentsView
        default:
            if related.isEmpty {
                Text("暂无相关推荐").foregroundColor(.secondary)
            }
            ForEach(related.prefix(15)) { item in
                Button { relatedSelection = item } label: {
                    HStack(spacing: 10) {
                        CachedAsyncImage(url: item.coverURL?.resizedImageURL(320), animated: false)
                            .aspectRatio(16 / 9, contentMode: .fill)
                            .frame(width: 120, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.subheadline.weight(.semibold)).foregroundColor(.primary).lineLimit(2)
                            Text("\(item.author) · \(Formatters.playCount(item.playCount))播放")
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var commentsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.isLoggedIn {
                HStack {
                    TextField("发表评论", text: $draft).textFieldStyle(.roundedBorder)
                    Button("发送") { Task { await sendComment() } }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if comments.isEmpty {
                Text("暂无评论").foregroundColor(.secondary)
            }
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    Text(comment.author).font(.subheadline.weight(.semibold))
                    Text(comment.message).font(.footnote)
                    Text("赞 \(comment.likeCount)").font(.caption2).foregroundColor(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: Loading

    @MainActor private func bootstrap() async {
        model.fallbackDuration = video.duration
        model.expectsPicture = true
        model.nowPlayingMeta = (video.title, video.author, video.coverURL)
        model.resumeKey = "\(video.bvid)-\(video.cid ?? 0)"
        let aid = video.aid, cookie = session.cookie
        model.onProgressReport = { seconds in
            Task { await BilibiliAPI.shared.reportHistory(aid: aid, cid: aid == 0 ? 0 : (self.video.cid ?? 0), progress: seconds, cookie: cookie) }
        }
        do {
            detail = try await BilibiliAPI.shared.videoDetail(bvid: video.bvid, cookie: session.cookie)
        } catch {
            errorMessage = "视频信息读取失败"
        }
        await loadPlayback(quality: nil)
        async let danmakuTask: Void = loadDanmaku()
        async let extras: Void = loadExtras()
        _ = await (danmakuTask, extras)
    }

    @MainActor private func loadPlayback(quality: Int?, muxed: Bool = false) async {
        do {
            let playback = try await BilibiliAPI.shared.playback(for: active, quality: quality, muxed: muxed, cookie: session.cookie)
            qualities = playback.qualities
            selectedQuality = playback.quality > 0 ? playback.quality : nil
            alternates = playback.alternateURLs
            currentPlayback = playback
            errorMessage = nil
            model.load(video: playback.url, audio: playback.audioURL, dash: playback.dash,
                       autoplay: UserDefaults.standard.object(forKey: "moumusic.bili.autoplay") as? Bool ?? true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleError(_ message: String) {
        DiagnosticLogStore.shared.append(level: .warning, category: "哔哩哔哩播放", message: "画质 \(selectedQuality.map(String.init) ?? "-") 打开失败", detail: message)
        if !alternates.isEmpty, let playback = currentPlayback {
            let next = alternates.removeFirst()
            model.load(video: next, audio: playback.audioURL, dash: nil, autoplay: true)
            return
        }
        if qualityFallbackDepth < 6, let current = selectedQuality,
           let lower = qualities.map(\.code).filter({ $0 < current }).max() {
            qualityFallbackDepth += 1
            ToastCenter.shared.show("该画质打开失败，已降到较低画质")
            Task { await loadPlayback(quality: lower) }
            return
        }
        if !triedMuxed {
            triedMuxed = true
            Task { await loadPlayback(quality: selectedQuality, muxed: true) }
            return
        }
        errorMessage = message
    }

    @MainActor private func loadDanmaku() async {
        guard let cid = detail?.cid ?? video.cid else { return }
        danmaku = (try? await BilibiliAPI.shared.danmaku(cid: cid, cookie: session.cookie)) ?? []
    }

    @MainActor private func loadExtras() async {
        let base = detail ?? video
        var tracks = base.subtitles
        if let cid = base.cid,
           let extra = try? await BilibiliAPI.shared.subtitleTracks(bvid: base.bvid, aid: base.aid, cid: cid, cookie: session.cookie) {
            tracks += extra
        }
        var seen = Set<String>()
        subtitles = tracks.filter { seen.insert(biliKey($0)).inserted }
        if let preferred = subtitles.first(where: { $0.language.lowercased().contains("zh") && !$0.isAIGenerated && !$0.isTranslated })
            ?? subtitles.first(where: { $0.language.lowercased().contains("zh") }) {
            await loadSubtitle(preferred)
        }
        related = (try? await BilibiliAPI.shared.relatedVideos(bvid: video.bvid, cookie: session.cookie)) ?? []
        comments = (try? await BilibiliAPI.shared.comments(aid: base.aid, cookie: session.cookie).comments) ?? []
        if session.isLoggedIn {
            interaction = try? await BilibiliAPI.shared.interactionState(aid: base.aid, cookie: session.cookie)
        }
        if UserDefaults.standard.object(forKey: "moumusic.bili.sponsorBlock") as? Bool ?? true {
            model.skipSegments = await BilibiliAPI.shared.sponsorSegments(bvid: video.bvid)
        }
    }

    @MainActor private func loadSubtitle(_ subtitle: BilibiliAPI.Subtitle) async {
        if let loaded = try? await BilibiliAPI.shared.subtitleCues(for: subtitle, cookie: session.cookie) {
            selectedSubtitle = subtitle
            cues = loaded
        } else {
            ToastCenter.shared.show("字幕加载失败")
        }
    }

    // MARK: Actions

    @MainActor private func refreshInteraction() async {
        interaction = try? await BilibiliAPI.shared.interactionState(aid: active.aid, cookie: session.cookie)
    }

    @MainActor private func toggleLike() async {
        let liked = interaction?.isLiked == true
        try? await BilibiliAPI.shared.setVideoLike(aid: active.aid, liked: !liked, cookie: session.cookie)
        await refreshInteraction()
    }

    @MainActor private func coin() async {
        do { try await BilibiliAPI.shared.addVideoCoin(aid: active.aid, cookie: session.cookie) } catch { ToastCenter.shared.show("投币失败") }
        await refreshInteraction()
    }

    @MainActor private func toggleFavorite() async {
        let favorited = interaction?.isFavorited == true
        try? await BilibiliAPI.shared.setVideoFavorite(aid: active.aid, favorited: !favorited, cookie: session.cookie)
        await refreshInteraction()
    }

    @MainActor private func watchLater() async {
        do {
            try await BilibiliAPI.shared.addToWatchLater(aid: active.aid, cookie: session.cookie)
            ToastCenter.shared.show("已加入稍后再看")
        } catch {
            ToastCenter.shared.show("加入稍后再看失败")
        }
    }

    @MainActor private func sendComment() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try await BilibiliAPI.shared.postComment(aid: active.aid, message: text, cookie: session.cookie)
            draft = ""
            comments = (try? await BilibiliAPI.shared.comments(aid: active.aid, sort: .latest, cookie: session.cookie).comments) ?? comments
        } catch {
            ToastCenter.shared.show("评论发送失败")
        }
    }
}

// MARK: - Live

struct CompatBiliLiveView: View {
    let room: BilibiliAPI.LiveRoom

    @EnvironmentObject private var session: BilibiliSessionStore
    @Environment(\.presentationMode) private var presentation
    @StateObject private var model = BiliPlayerModel()
    @State private var qualities: [BilibiliAPI.LiveQuality] = []
    @State private var selectedQuality: Int?
    @State private var listenOnly = false
    @State private var errorMessage: String?
    @State private var showFullScreen = false
    @State private var danmakuClient = BiliLiveDanmakuClient()

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                player(fullscreen: false)
                    .frame(height: 244)
                HStack(spacing: 10) {
                    if !qualities.isEmpty {
                        Menu {
                            ForEach(qualities) { quality in
                                Button(quality.title) { Task { await loadPlayback(quality: quality.code) } }
                            }
                        } label: {
                            Label(qualities.first(where: { $0.code == selectedQuality })?.title ?? "画质", systemImage: "rectangle.inset.filled")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button { model.seekToLiveEdge() } label: { Label("追到最新", systemImage: "forward.end.fill") }
                        .buttonStyle(.bordered)
                    Button { listenOnly.toggle() } label: {
                        Label(listenOnly ? "看画面" : "只听声音", systemImage: listenOnly ? "play.rectangle" : "headphones")
                    }
                    .buttonStyle(.bordered)
                    Button { showFullScreen = true } label: { Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.bordered)
                }
                .font(.footnote)
                .padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 6) {
                    Text(room.title).font(.title3.weight(.semibold))
                    Text("\(room.userName) · \(Formatters.playCount(room.online)) 人气 · \(room.areaName)")
                        .font(.subheadline).foregroundColor(.secondary)
                    if let errorMessage { Text(errorMessage).font(.footnote).foregroundColor(.red) }
                }
                .padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
            .navigationTitle("直播")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { presentation.wrappedValue.dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
        .fullScreenCover(isPresented: $showFullScreen) {
            player(fullscreen: true).ignoresSafeArea().background(Color.black.ignoresSafeArea())
        }
        .task {
            model.expectsPicture = true
            model.onError = { errorMessage = $0 }
            await loadPlayback(quality: nil)
            danmakuClient.start(roomID: room.roomID, cookie: session.cookie) { text, color in
                model.pushLiveDanmaku(text: text, color: color)
            }
        }
        .onDisappear {
            danmakuClient.stop()
            model.stop()
        }
    }

    private func player(fullscreen: Bool) -> some View {
        BiliNativePlayer(
            model: model, cues: [], danmaku: [],
            danmakuEnabled: UserDefaults.standard.object(forKey: "moumusic.bili.danmakuEnabled") as? Bool ?? true,
            subtitles: [], selectedSubtitleID: nil, onSelectSubtitle: { _ in },
            posterURL: room.coverURL, audioOnly: listenOnly, title: room.title,
            isFullscreen: fullscreen, rotatesInFullscreen: true,
            onFullscreen: fullscreen ? nil : { showFullScreen = true },
            onClose: fullscreen ? { showFullScreen = false } : nil
        )
    }

    @MainActor private func loadPlayback(quality: Int?) async {
        do {
            let playback = try await BilibiliAPI.shared.livePlayback(for: room.roomID, quality: quality, cookie: session.cookie)
            qualities = playback.qualities
            selectedQuality = playback.quality
            errorMessage = nil
            model.load(video: playback.url, audio: nil, dash: nil, autoplay: true)
        } catch {
            errorMessage = "直播流读取失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Account

private struct BiliAccountView: View {
    @EnvironmentObject private var session: BilibiliSessionStore
    @State private var showLogin = false

    var body: some View {
        List {
            if session.isLoggedIn {
                Section {
                    HStack(spacing: 12) {
                        CachedAsyncImage(url: session.avatarURL?.resizedImageURL(120), animated: false)
                            .frame(width: 52, height: 52)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.profileName ?? "哔哩哔哩用户").font(.headline)
                            Text(session.membershipTitle ?? "非会员").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Section {
                    NavigationLink("观看记录") { BiliHistoryView() }
                    NavigationLink("收藏夹") { BiliFavoritesView() }
                    NavigationLink("私信") { BiliMessagesView() }
                    NavigationLink("消息通知") { BiliNoticesView() }
                }
                Section {
                    Button("退出登录", role: .destructive) { session.signOut() }
                }
            } else {
                Section {
                    Text("登录后可使用推荐个性化、点赞投币收藏、观看记录与私信。")
                        .font(.footnote).foregroundColor(.secondary)
                    Button("扫码登录") { showLogin = true }
                }
            }
        }
        .sheet(isPresented: $showLogin) { CompatBiliLoginSheet().environmentObject(session) }
    }
}

private struct BiliHistoryView: View {
    @EnvironmentObject private var session: BilibiliSessionStore
    @State private var items: [BilibiliAPI.WatchHistoryItem] = []
    @State private var loading = true
    @State private var selected: BilibiliAPI.Video?

    var body: some View {
        List {
            if loading { ProgressView() }
            ForEach(items) { item in
                Button {
                    if let video = item.video { selected = video }
                } label: {
                    HStack(spacing: 10) {
                        CachedAsyncImage(url: item.coverURL?.resizedImageURL(320), animated: false)
                            .aspectRatio(16 / 9, contentMode: .fill)
                            .frame(width: 112, height: 63)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.subheadline.weight(.semibold)).foregroundColor(.primary).lineLimit(2)
                            Text(item.author).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("观看记录")
        .task {
            items = (try? await BilibiliAPI.shared.watchHistory(cookie: session.cookie)) ?? []
            loading = false
        }
        .sheet(item: $selected) { CompatBiliVideoView(video: $0) }
    }
}

private struct BiliFavoritesView: View {
    @EnvironmentObject private var session: BilibiliSessionStore
    @State private var folders: [BilibiliAPI.FavoriteFolder] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading { ProgressView() }
            ForEach(folders) { folder in
                NavigationLink {
                    BiliFolderVideosView(folder: folder)
                } label: {
                    HStack {
                        Text(folder.title)
                        Spacer()
                        Text("\(folder.mediaCount)").foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("收藏夹")
        .task {
            folders = (try? await BilibiliAPI.shared.favoriteFolders(cookie: session.cookie)) ?? []
            loading = false
        }
    }
}

private struct BiliFolderVideosView: View {
    let folder: BilibiliAPI.FavoriteFolder
    @EnvironmentObject private var session: BilibiliSessionStore
    @State private var videos: [BilibiliAPI.Video] = []
    @State private var selected: BilibiliAPI.Video?

    var body: some View {
        ScrollView { BiliVideoGrid(videos: videos, onSelect: { selected = $0 }) }
            .navigationTitle(folder.title)
            .task { videos = (try? await BilibiliAPI.shared.favoriteVideos(folderID: folder.id, cookie: session.cookie)) ?? [] }
            .sheet(item: $selected) { CompatBiliVideoView(video: $0) }
    }
}

private struct BiliMessagesView: View {
    @EnvironmentObject private var session: BilibiliSessionStore
    @State private var threads: [BilibiliAPI.PrivateMessageThread] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading { ProgressView() }
            ForEach(threads) { thread in
                NavigationLink {
                    BiliChatView(thread: thread)
                } label: {
                    HStack(spacing: 10) {
                        CachedAsyncImage(url: thread.avatarURL?.resizedImageURL(96), animated: false)
                            .frame(width: 42, height: 42)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(thread.userName).font(.subheadline.weight(.semibold))
                            Text(BilibiliAPI.readableMessage(thread.lastMessage, type: 1)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if thread.unreadCount > 0 {
                            Text("\(thread.unreadCount)").font(.caption2.weight(.bold)).foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Color.red, in: Capsule())
                        }
                    }
                }
            }
        }
        .navigationTitle("私信")
        .task {
            threads = (try? await BilibiliAPI.shared.privateMessages(cookie: session.cookie)) ?? []
            loading = false
        }
    }
}

private struct BiliChatView: View {
    let thread: BilibiliAPI.PrivateMessageThread
    @EnvironmentObject private var session: BilibiliSessionStore
    @State private var messages: [BilibiliAPI.ChatMessage] = []
    @State private var loading = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if loading { ProgressView().padding(.top, 40) }
                    ForEach(messages) { message in
                        let mine = message.senderID != thread.userID
                        Text(message.text)
                            .font(.subheadline)
                            .foregroundColor(mine ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(mine ? Theme.accent : Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: messages) { _ in
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .navigationTitle(thread.userName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            messages = (try? await BilibiliAPI.shared.conversation(talker: thread.userID, cookie: session.cookie)) ?? []
            loading = false
        }
    }
}

private struct BiliNoticesView: View {
    @EnvironmentObject private var session: BilibiliSessionStore
    @State private var kind: BilibiliAPI.NoticeKind = .reply
    @State private var items: [BilibiliAPI.FeedNotice] = []
    @State private var loading = true

    var body: some View {
        VStack {
            Picker("", selection: $kind) {
                ForEach(BilibiliAPI.NoticeKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            List {
                if loading { ProgressView() }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        CachedAsyncImage(url: item.avatarURL?.resizedImageURL(96), animated: false)
                            .frame(width: 38, height: 38)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.userName).font(.subheadline.weight(.semibold))
                            Text(item.action).font(.caption).foregroundColor(.secondary)
                            if !item.content.isEmpty { Text(item.content).font(.footnote).lineLimit(4) }
                        }
                    }
                }
            }
        }
        .navigationTitle("消息通知")
        .task(id: kind) {
            loading = true
            items = (try? await BilibiliAPI.shared.notices(kind: kind, cookie: session.cookie)) ?? []
            loading = false
        }
    }
}

// MARK: - Login

struct CompatBiliLoginSheet: View {
    @EnvironmentObject private var session: BilibiliSessionStore
    @Environment(\.presentationMode) private var presentation
    @State private var qr: UIImage?
    @State private var status = "正在获取二维码…"
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                Text("使用哔哩哔哩 App 扫码登录").font(.headline).padding(.top, 20)
                Group {
                    if let qr {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220)
                            .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        ProgressView().frame(width: 220, height: 220)
                    }
                }
                Text(status).font(.subheadline).foregroundColor(.secondary)
                Button("刷新二维码") { start() }.buttonStyle(.bordered)
                Spacer()
            }
            .navigationTitle("哔哩哔哩登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { presentation.wrappedValue.dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { start() }
        .onDisappear { pollTask?.cancel() }
    }

    private func start() {
        pollTask?.cancel()
        qr = nil
        status = "正在获取二维码…"
        pollTask = Task {
            do {
                let payload = try await BilibiliAPI.shared.qrCode()
                await MainActor.run {
                    qr = Self.qrImage(payload.url)
                    status = "等待扫码"
                }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    switch try await BilibiliAPI.shared.poll(key: payload.key) {
                    case .waiting:
                        break
                    case .scanned:
                        await MainActor.run { status = "已扫码，请在手机上确认" }
                    case .expired:
                        await MainActor.run { status = "二维码已过期，请刷新" }
                        return
                    case .success(let cookie):
                        try await session.signInFromQR(cookie: cookie)
                        await MainActor.run { presentation.wrappedValue.dismiss() }
                        return
                    }
                }
            } catch {
                await MainActor.run { status = "登录失败：\(error.localizedDescription)" }
            }
        }
    }

    private static func qrImage(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
