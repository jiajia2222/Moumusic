#if os(iOS)
import SwiftUI

/// Bilibili live browsing and playback.
///
/// This page deliberately lives beside the music search surface so live
/// streams do not compete with song results. The API and view are native
/// Swift implementations; the existing Moumusic WebKit player supplies the
/// inline/full-screen controls.
@MainActor
private final class BilibiliLiveViewModel: ObservableObject {
    @Published private(set) var rooms: [BilibiliAPI.LiveRoom] = []
    @Published private(set) var areas: [BilibiliAPI.LiveArea] = []
    @Published var selectedArea: BilibiliAPI.LiveArea?
    @Published var query = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func loadInitial(cookie: String?) async {
        if areas.isEmpty {
            areas = (try? await BilibiliAPI.shared.liveAreas(cookie: cookie)) ?? []
        }
        await reload(cookie: cookie)
    }

    func reload(cookie: String?) async {
        await loadRooms(area: selectedArea, cookie: cookie)
    }

    func selectArea(_ area: BilibiliAPI.LiveArea?, cookie: String?) {
        selectedArea = area
        query = ""
        Task { @MainActor [weak self] in
            await self?.loadRooms(area: area, cookie: cookie)
        }
    }

    func search(cookie: String?) async {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            await reload(cookie: cookie)
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            rooms = try await BilibiliAPI.shared.searchLiveRooms(keyword: cleaned, cookie: cookie)
            if rooms.isEmpty { errorMessage = "没有找到相关直播间" }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadRooms(area: BilibiliAPI.LiveArea?, cookie: String?) async {
        isLoading = true
        errorMessage = nil
        do {
            if let area {
                rooms = try await BilibiliAPI.shared.liveRooms(
                    parentAreaID: area.parentID,
                    areaID: area.id,
                    cookie: cookie
                )
            } else {
                rooms = try await BilibiliAPI.shared.popularLiveRooms(cookie: cookie)
            }
            if rooms.isEmpty { errorMessage = "暂时没有可展示的直播间" }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct BilibiliLiveView: View {
    /// When embedded, this view supplies only the live browsing surface and
    /// leaves navigation/closing to BilibiliContentView.
    let embedded: Bool

    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BilibiliLiveViewModel()
    @State private var selectedRoom: BilibiliAPI.LiveRoom?

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    searchField
                    areaPicker

                    if model.isLoading && model.rooms.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 260)
                    } else if let errorMessage = model.errorMessage, model.rooms.isEmpty {
                        ErrorStateView(message: errorMessage) {
                            Task { await model.search(cookie: bilibili.cookie) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
                    } else if model.rooms.isEmpty {
                        EmptyStateView(icon: "dot.radiowaves.left.and.right", title: "暂时没有直播")
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        SectionHeader(title: LocalizedStringKey(model.query.isEmpty ? "热门直播" : "搜索结果"))
                            .padding(.horizontal, Theme.Layout.contentInset)
                        liveGrid
                    }
                    PlayerClearanceSpacer()
                }
                .padding(.top, 12)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await model.reload(cookie: bilibili.cookie)
            }
        }
        .navigationTitle(embedded ? "哔哩哔哩 · 直播" : "B 站直播")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭 B 站直播")
                }
            }
        }
        .task {
            await model.loadInitial(cookie: bilibili.cookie)
        }
        .sheet(item: $selectedRoom) { room in
            NavigationStack {
                BilibiliLiveRoomView(room: room)
                    .environmentObject(bilibili)
                    .environmentObject(settings)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label("直播", systemImage: "dot.radiowaves.left.and.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text("热门直播、分区浏览和直播间搜索")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                Task { await model.reload(cookie: bilibili.cookie) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.headline.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新直播")
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("搜索直播间或主播", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await model.search(cookie: bilibili.cookie) } }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    Task { await model.reload(cookie: bilibili.cookie) }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("清除直播搜索")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private var areaPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("热门") {
                    model.selectArea(nil, cookie: bilibili.cookie)
                }
                .buttonStyle(.chip(isSelected: model.selectedArea == nil && model.query.isEmpty))
                ForEach(model.areas.prefix(18)) { area in
                    Button(area.name) {
                        model.selectArea(area, cookie: bilibili.cookie)
                    }
                    .buttonStyle(.chip(isSelected: model.selectedArea?.id == area.id && model.query.isEmpty))
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
        .scrollIndicators(.hidden)
    }

    private var liveGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 0), spacing: 12),
                GridItem(.flexible(minimum: 0), spacing: 12)
            ],
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(model.rooms) { room in
                Button { selectedRoom = room } label: {
                    BilibiliLiveRoomCard(room: room)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Layout.contentInset)
    }
}

private struct BilibiliLiveRoomCard: View {
    let room: BilibiliAPI.LiveRoom

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                // Give the grid a real layout canvas first.  A loading
                // CachedAsyncImage has no intrinsic size; using it as the
                // ZStack's measuring child makes the two columns overlap.
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        CachedAsyncImage(url: room.coverURL?.resizedImageURL(640))
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 5) {
                            Circle().fill(.red).frame(width: 7, height: 7)
                            Text("直播")
                        }
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.58), in: Capsule())
                        .padding(8)
                    }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()
            Text(room.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Text(room.userName).lineLimit(1)
                Spacer(minLength: 0)
                if room.online > 0 {
                    Label(Formatters.playCount(room.online), systemImage: "eye")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !room.areaName.isEmpty {
                Text(room.areaName)
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

struct BilibiliLiveRoomView: View {
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
    let room: BilibiliAPI.LiveRoom

    @State private var playbackURL: URL?
    @State private var qualities: [BilibiliAPI.LiveQuality] = []
    @State private var selectedQuality: Int?
    @State private var playerToken = UUID()
    @State private var errorMessage: String?
    @State private var showFullScreen = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack(alignment: .topLeading) {
                        PiliPlusVideoPlayerView(
                            url: playbackURL,
                            cues: [],
                            danmaku: [],
                            posterURL: room.coverURL,
                            audioOnly: settings.bilibiliMode == .listen,
                            autoPlay: playbackURL != nil,
                            title: room.title,
                            author: room.userName,
                            onError: { errorMessage = $0 },
                            onFullscreen: { showFullScreen = true }
                        )
                        .id(playerToken)
                        .frame(height: 244)
                        Label("正在直播", systemImage: "dot.radiowaves.left.and.arrow.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.red.opacity(0.9), in: Capsule())
                            .padding(12)
                    }
                    playbackOptions
                    roomInformation
                    if let errorMessage {
                        ErrorStateView(message: errorMessage) {
                            Task { await loadPlayback(quality: selectedQuality) }
                        }
                        .padding(.horizontal, 18)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(room.userName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .task { await loadPlayback(quality: selectedQuality) }
        .fullScreenCover(isPresented: $showFullScreen) {
            PiliPlusFullScreenPlayer(url: playbackURL, cues: [], danmaku: [], posterURL: room.coverURL, audioOnly: settings.bilibiliMode == .listen)
        }
    }

    private var playbackOptions: some View {
        HStack(spacing: 10) {
            if !qualities.isEmpty {
                Menu {
                    ForEach(qualities) { quality in
                        Button {
                            Task { await loadPlayback(quality: quality.code) }
                        } label: {
                            if quality.code == selectedQuality {
                                Label(quality.title, systemImage: "checkmark")
                            } else {
                                Text(quality.title)
                            }
                        }
                    }
                } label: {
                    Label(currentQualityTitle, systemImage: "rectangle.inset.filled")
                }
                .buttonStyle(.bordered)
            }
            if settings.bilibiliMode != .listen {
                Button { showFullScreen = true } label: {
                    Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
            Link(destination: URL(string: "https://live.bilibili.com/\(room.roomID)")!) {
                Image(systemName: "safari")
            }
            .accessibilityLabel("在 B 站打开直播间")
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 18)
    }

    private var currentQualityTitle: String {
        guard let selectedQuality else { return "画质" }
        return qualities.first(where: { $0.code == selectedQuality })?.title ?? "画质"
    }

    private var roomInformation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(room.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let avatar = room.userAvatarURL {
                    CachedAsyncImage(url: avatar.resizedImageURL(96))
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                }
                Text(room.userName).font(.subheadline.weight(.medium))
                if room.online > 0 {
                    Text("· \(Formatters.playCount(room.online)) 人气")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !room.parentAreaName.isEmpty || !room.areaName.isEmpty {
                Text([room.parentAreaName, room.areaName].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 18)
    }

    @MainActor
    private func loadPlayback(quality: Int?) async {
        do {
            let playback = try await BilibiliAPI.shared.livePlayback(
                for: room.roomID,
                quality: quality,
                cookie: bilibili.cookie
            )
            playbackURL = playback.url
            qualities = playback.qualities
            selectedQuality = playback.quality
            playerToken = UUID()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
