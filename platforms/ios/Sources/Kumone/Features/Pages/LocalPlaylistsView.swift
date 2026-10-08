import SwiftUI
import UniformTypeIdentifiers

struct LocalPlaylistsView: View {
    @StateObject private var store = LocalPlaylistStore.shared
    @EnvironmentObject private var account: AccountStore
    @State private var showImport = false
    @State private var showCreate = false
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                NavigationLink(value: Destination.likedSongs) {
                    likedSongsRow
                }
                .buttonStyle(.plain)

                if store.playlists.isEmpty {
                    VStack(spacing: 14) {
                        EmptyStateView(
                            icon: "music.note.list",
                            title: "还没有本地歌单",
                            subtitle: "可以导入其他音乐软件的歌单，或在歌曲页面点“加入歌单”"
                        )
                        Button {
                            showImport = true
                        } label: {
                            Label("导入歌单", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                    }
                    .frame(maxWidth: .infinity, minHeight: 460)
                    .padding(.horizontal, Theme.Layout.contentInset)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(store.playlists) { playlist in
                            NavigationLink(value: Destination.localPlaylist(playlist.id)) {
                                playlistRow(playlist)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    Task {
                                        await account.syncLocalPlaylistToOfficialPlaylist(
                                            localPlaylistID: playlist.id
                                        )
                                    }
                                } label: {
                                    Label("同步到官方歌单", systemImage: "arrow.triangle.2.circlepath")
                                }
                                ShareLink(item: store.exportText(playlist)) {
                                    Label("导出歌单", systemImage: "square.and.arrow.up")
                                }
                                Button("删除歌单", role: .destructive) {
                                    store.delete(id: playlist.id)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.delete(id: playlist.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                    .padding(.top, 2)
                }
            }
            .padding(.top, 14)
            PlayerClearanceSpacer()
        }
        .navigationTitle("本地歌单")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showImport = true
                } label: {
                    Label("导入歌单", systemImage: "square.and.arrow.down")
                }
                Button {
                    showCreate = true
                } label: {
                    Label("新建歌单", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportPlaylistSheet()
        }
        .alert("新建本地歌单", isPresented: $showCreate) {
            TextField("歌单名称", text: $newName)
            Button("创建") {
                _ = store.create(name: newName)
                newName = ""
            }
            Button("取消", role: .cancel) { newName = "" }
        }
    }

    private var likedSongsRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "heart.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(
                    LinearGradient(
                        colors: [Theme.accent, Theme.accent.opacity(0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text("我喜欢的音乐")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(likedSongsSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, Theme.Layout.contentInset)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("我喜欢的音乐，\(likedSongsSubtitle)")
    }

    private var likedSongsSubtitle: String {
        guard account.isLoggedIn else {
            let local = FavoritesStore.shared.tracks.count
            return local == 0 ? "红心歌曲保存在本机，登录网易云可同步" : "\(local) 首 · 本地收藏"
        }
        let count = account.likedTrackIDs.count
        return count == 0 ? "暂无红心歌曲" : "\(count) 首红心歌曲 · 云端同步"
    }

    private func playlistRow(_ playlist: LocalPlaylist) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(160), animated: false)
                .frame(width: 68, height: 68)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    if playlist.coverURL == nil {
                        Image(systemName: "music.note.list")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(playlist.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(["\(playlist.tracks.count) 首", playlist.sourceName]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// 我喜欢的音乐: one tab per signed-in platform (网易云 / QQ 音乐 / 酷狗) plus 本地. Every tab
/// re-fetches its platform's liked list when opened, so all platforms stay in sync automatically.
struct LikedSongsView: View {
    enum Source: String, CaseIterable, Identifiable {
        case netease = "网易云"
        case qq = "QQ 音乐"
        case kugou = "酷狗"
        case local = "本地"
        var id: String { rawValue }
    }

    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var qqMusic: QQMusicSessionStore
    @EnvironmentObject private var kugou: KugouSessionStore
    @Environment(\.openLogin) private var openLogin

    @ObservedObject private var favorites = FavoritesStore.shared
    @State private var source: Source?
    @State private var tracksBySource: [Source: [Track]] = [:]
    @State private var query = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    #if os(iOS)
    @State private var showDownloadOptions = false
    #endif

    private var availableSources: [Source] {
        var result: [Source] = []
        if account.isLoggedIn { result.append(.netease) }
        if qqMusic.isLoggedIn { result.append(.qq) }
        if kugou.isLoggedIn { result.append(.kugou) }
        result.append(.local)
        return result
    }

    private var current: Source { source.flatMap { availableSources.contains($0) ? $0 : nil } ?? availableSources[0] }

    private var tracks: [Track] {
        current == .local ? favorites.tracks : (tracksBySource[current] ?? [])
    }

    private var visibleTracks: [Track] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tracks }
        return tracks.filter { track in
            track.name.localizedCaseInsensitiveContains(query)
                || track.artistNames.localizedCaseInsensitiveContains(query)
                || track.album.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if availableSources.count > 1 {
                    Picker("平台", selection: Binding(get: { current }, set: { source = $0 })) {
                        ForEach(availableSources) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Theme.Layout.contentInset)
                }

                if isLoading && tracks.isEmpty {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("正在读取\(current.rawValue)红心歌曲").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else if let errorMessage, tracks.isEmpty {
                    ErrorStateView(message: errorMessage) { Task { await load(force: true) } }
                        .frame(minHeight: 280)
                } else if tracks.isEmpty {
                    EmptyStateView(
                        icon: "heart",
                        title: "还没有红心歌曲",
                        subtitle: current == .local
                            ? "在歌曲播放页点红心，歌曲会保存在本机；登录任意平台后显示该平台的喜欢歌单"
                            : "\(current.rawValue)账号里还没有喜欢的歌曲"
                    )
                    .frame(minHeight: 260)
                    if !account.isLoggedIn && current == .local {
                        Button("登录网易云") { openLogin() }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                } else if visibleTracks.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "没有匹配的歌曲", subtitle: "试试搜索歌曲名、歌手或专辑")
                        .frame(minHeight: 220)
                } else {
                    TrackListView(tracks: visibleTracks, source: .none)
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }

                PlayerClearanceSpacer()
            }
            .padding(.top, 14)
        }
        .navigationTitle("我喜欢的音乐")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !visibleTracks.isEmpty {
                    Button {
                        player.play(tracks: visibleTracks, source: .none)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    #if os(iOS)
                    Button {
                        showDownloadOptions = true
                    } label: {
                        Label("批量下载", systemImage: "arrow.down.circle")
                    }
                    #endif
                }
                Button {
                    Task { await load(force: true) }
                } label: {
                    Label("刷新红心歌曲", systemImage: "arrow.clockwise")
                }
            }
        }
        .searchable(text: $query, prompt: "搜索红心歌曲")
        .task(id: "\(current.rawValue)-\(account.likedTrackIDs.count)-\(qqMusic.sessionRevision)-\(kugou.sessionRevision)") {
            await load(force: false)
        }
        .refreshable { await load(force: true) }
        #if os(iOS)
        .sheet(isPresented: $showDownloadOptions) {
            DownloadOptionsSheet(tracks: visibleTracks)
        }
        #endif
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "heart.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(
                    LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.58)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 6) {
                Text("我喜欢的音乐").font(.title3.weight(.bold))
                Text(current == .local ? "\(tracks.count) 首 · 仅保存在本机" : "\(tracks.count) 首 · \(current.rawValue)账号同步")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    @MainActor
    private func load(force: Bool) async {
        let target = current
        guard target != .local else { errorMessage = nil; return }
        if !force, tracksBySource[target] != nil { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched: [Track]
            switch target {
            case .netease:
                if force { await account.refreshLibrary() } else { await account.refreshForOpen() }
                fetched = try await neteaseTracks()
            case .qq:
                fetched = try await qqTracks()
            case .kugou:
                fetched = try await kugouTracks()
            case .local:
                fetched = []
            }
            tracksBySource[target] = fetched
        } catch {
            errorMessage = "\(target.rawValue)红心歌曲暂时无法读取，请稍后重试"
        }
    }

    private func neteaseTracks() async throws -> [Track] {
        let ids = account.likedTrackIDs.sorted(by: >)
        var fetched: [Track] = []
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids.dropFirst(start).prefix(500))
            let response = try await NeteaseAPI.songDetails(ids: chunk)
            let lookup = Dictionary(response.songs.map { ($0.id, $0.normalizedForLXPlayback()) },
                                    uniquingKeysWith: { first, _ in first })
            fetched.append(contentsOf: chunk.compactMap { lookup[$0] })
        }
        return fetched
    }

    /// QQ 音乐's liked songs are the account playlist called 我喜欢 (dirid 201).
    private func qqTracks() async throws -> [Track] {
        #if os(iOS)
        guard let cookie = qqMusic.cookie else { return [] }
        let lists = try await QQMusicAPI.shared.userPlaylists(cookie: cookie)
        guard let liked = lists.first(where: { $0.name.contains("我喜欢") }) ?? lists.first else { return [] }
        return try await LXCatalogService.playlistDetail(source: .tx, id: liked.id).tracks
        #else
        return []
        #endif
    }

    /// 酷狗's liked songs are the cloud list named 我喜欢.
    private func kugouTracks() async throws -> [Track] {
        #if os(iOS)
        guard let cookie = await kugou.cookieWithDevice() else { return [] }
        let lists = try await KugouAPI.shared.userPlaylists(cookie: cookie)
        guard let liked = lists.first(where: { $0.name.contains("我喜欢") }) ?? lists.first else { return [] }
        let rows = try await KugouAPI.shared.cloudPlaylistSongs(id: liked.id, cookie: cookie)
        return rows.compactMap { AccountPlaylistsView.kugouTrack($0) }
        #else
        return []
        #endif
    }
}

struct ImportPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = LocalPlaylistStore.shared
    @State private var input = ""
    @State private var isImporting = false
    @State private var showFileImporter = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("粘贴歌单") {
                    TextEditor(text: $input)
                        .frame(minHeight: 180)
                        .font(.body)
                        .overlay(alignment: .topLeading) {
                            if input.isEmpty {
                                Text("粘贴任意支持平台的歌单链接，或粘贴包含链接的整段文字。也支持其他音乐软件导出的歌单 JSON；网易云、QQ、酷狗、酷我和咪咕歌曲会保留原平台标识，并由已选 LX 音源负责播放。")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.trailing, 8)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Section("汽水音乐") {
                    Text("仅支持导入汽水音乐公开歌单。导入会读取完整曲目列表；播放、歌词和音质统一交给你已启用的 LX 音源，不再调用内置汽水播放接口。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("选择 JSON / 文本文件", systemImage: "doc.badge.plus")
                    }
                    .frame(minHeight: 44)
                    Button {
                        importPlaylist()
                    } label: {
                        HStack {
                            Text(isImporting ? "正在导入…" : "开始导入")
                            Spacer()
                            if isImporting { ProgressView() }
                        }
                    }
                    .disabled(isImporting || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 44)
                }

                Section("说明") {
                    Text("歌单只保存到本机，不会修改原音乐软件。支持网易云、QQ、酷狗、酷我和咪咕的公开歌单链接，也支持从分享文本中自动识别链接及导入 JSON。在线目录只读取公开信息，实际播放仍使用你自己添加的 LX 音源。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("导入歌单")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showFileImporter) {
                // Like the source import: the chosen file is imported at once. Its text is not put into the paste box below
                // (a big playlist export froze the text editor).
                CopyingDocumentPicker(contentTypes: [.item]) { urls in
                    guard let url = urls.first else { return }
                    importPlaylistFile(at: url)
                }
            }
            #else
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    input = try readTextFile(at: url)
                } catch {
                    errorMessage = "读取文件失败：\(error.localizedDescription)"
                }
            }
            #endif
            .alert("导入失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func importPlaylist() {
        importPlaylist(from: input)
    }

    /// The chosen file is read off the main thread and imported from its bytes (see `LocalPlaylistStore.importPlaylistFile`).
    private func importPlaylistFile(at url: URL) {
        isImporting = true
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                _ = try await store.importPlaylistFile(data: data)
                isImporting = false
                dismiss()
            } catch {
                isImporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importPlaylist(from text: String) {
        isImporting = true
        Task {
            do {
                _ = try await store.importPlaylist(from: text)
                isImporting = false
                dismiss()
            } catch {
                isImporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func readTextFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian,
                         .utf16BigEndian, .utf32, .utf32LittleEndian,
                         .utf32BigEndian, .windowsCP1252] {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text
            }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}

struct LocalPlaylistDetailView: View {
    let playlistID: UUID

    @StateObject private var store = LocalPlaylistStore.shared
    @EnvironmentObject private var player: PlayerService
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showAddTracks = false
    @State private var playlistQuery = ""
    @State private var isSearching = false
    @State private var isSelectingTracks = false
    @State private var selectedTrackKeys = Set<String>()
    #if os(iOS)
    @State private var showSelectedDownload = false
    #endif

    var body: some View {
        ScrollView {
            if let playlist = store.playlist(id: playlistID) {
                VStack(alignment: .leading, spacing: 18) {
                    header(playlist)

                    HStack(spacing: 10) {
                        Button {
                            player.play(tracks: playlist.tracks, source: .none)
                        } label: {
                            Label("播放全部", systemImage: "play.fill")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(playlist.tracks.isEmpty)

                        ShareLink(item: store.exportText(playlist)) {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("导出歌单")
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)

                    if isSearching {
                        TrackSearchField(text: $playlistQuery, isSearching: $isSearching)
                    }

                    if playlist.tracks.isEmpty {
                        EmptyStateView(icon: "music.note.list", title: "歌单暂无歌曲")
                            .frame(minHeight: 260)
                    } else if filteredTracks(playlist.tracks).isEmpty {
                        EmptyStateView(icon: "magnifyingglass", title: "没有匹配的歌曲", subtitle: "试试搜索歌曲名、歌手或专辑")
                            .frame(minHeight: 200)
                    } else {
                        TrackListView(
                            tracks: filteredTracks(playlist.tracks),
                            source: .none,
                            onRemoved: { track in
                                store.remove(track, from: playlistID)
                                selectedTrackKeys.remove(track.playbackKey)
                            },
                            selectedTrackKeys: isSelectingTracks ? $selectedTrackKeys : nil
                        )
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                    }
                }
                .padding(.vertical, Theme.Layout.contentInset)
            } else {
                ErrorStateView(message: "歌单不存在") {}
                    .frame(minHeight: 360)
            }
            PlayerClearanceSpacer()
        }
        .navigationTitle(store.playlist(id: playlistID)?.name ?? "歌单")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isSelectingTracks.toggle()
                    if !isSelectingTracks { selectedTrackKeys.removeAll() }
                } label: {
                    Label(isSelectingTracks ? "完成选择" : "选择歌曲",
                          systemImage: isSelectingTracks ? "checkmark" : "checklist")
                }
                if isSelectingTracks, let playlist = store.playlist(id: playlistID), !selectedTrackKeys.isEmpty {
                    Button {
                        showAddTracks = true
                    } label: {
                        Label("加入歌单", systemImage: "text.badge.plus")
                    }
                    #if os(iOS)
                    Button {
                        showSelectedDownload = true
                    } label: {
                        Label("下载所选", systemImage: "arrow.down.circle")
                    }
                    #endif
                    Button(role: .destructive) {
                        store.remove(selectedTracks(from: playlist), from: playlistID)
                        selectedTrackKeys.removeAll()
                        isSelectingTracks = false
                    } label: {
                        Label("删除所选", systemImage: "trash")
                    }
                }
                if !isSelectingTracks, !(store.playlist(id: playlistID)?.tracks.isEmpty ?? true) {
                    Button {
                        showAddTracks = true
                    } label: {
                        Label("添加到歌单", systemImage: "text.badge.plus")
                    }
                }
                Button {
                    renameText = store.playlist(id: playlistID)?.name ?? ""
                    showRename = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    store.delete(id: playlistID)
                } label: {
                    Label("删除歌单", systemImage: "trash")
                }
            }
        }
        .alert("重命名歌单", isPresented: $showRename) {
            TextField("歌单名称", text: $renameText)
            Button("保存") { store.rename(id: playlistID, name: renameText) }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showAddTracks) {
            if let playlist = store.playlist(id: playlistID) {
                let tracks = selectedTracks(from: playlist)
                AddToPlaylistSheet(tracks: tracks.isEmpty ? playlist.tracks : tracks)
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showSelectedDownload) {
            if let playlist = store.playlist(id: playlistID) {
                DownloadOptionsSheet(tracks: selectedTracks(from: playlist))
            }
        }
        #endif
        .trackSearchButton(isSearching: $isSearching, text: $playlistQuery)
    }

    private func filteredTracks(_ tracks: [Track]) -> [Track] {
        let query = playlistQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tracks }
        return tracks.filter { track in
            track.name.localizedCaseInsensitiveContains(query)
                || track.artistNames.localizedCaseInsensitiveContains(query)
                || track.album.name.localizedCaseInsensitiveContains(query)
        }
    }

    private func selectedTracks(from playlist: LocalPlaylist) -> [Track] {
        playlist.tracks.filter { selectedTrackKeys.contains($0.playbackKey) }
    }

    private func header(_ playlist: LocalPlaylist) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(384))
                .frame(width: 126, height: 126)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    if playlist.coverURL == nil {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Text(playlist.name)
                    .font(.title3.weight(.bold))
                    .lineLimit(3)
                if let sourceName = playlist.sourceName, !sourceName.isEmpty {
                    Text("来源：\(sourceName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("\(playlist.tracks.count) 首")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }
}