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
        guard account.isLoggedIn else { return "登录网易云后同步红心歌曲" }
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

struct LikedSongsView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerService
    @Environment(\.openLogin) private var openLogin

    @State private var tracks: [Track] = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    #if os(iOS)
    @State private var showDownloadOptions = false
    #endif

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

                if !account.isLoggedIn {
                    loginState
                } else if isLoading && tracks.isEmpty {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在读取红心歌曲")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else if let errorMessage, tracks.isEmpty {
                    ErrorStateView(message: errorMessage) {
                        Task { await loadTracks() }
                    }
                    .frame(minHeight: 280)
                } else if tracks.isEmpty {
                    EmptyStateView(
                        icon: "heart",
                        title: "还没有红心歌曲",
                        subtitle: "在歌曲播放页点红心，歌曲会同步出现在这里"
                    )
                    .frame(minHeight: 260)
                } else {
                    if visibleTracks.isEmpty {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "没有匹配的歌曲",
                            subtitle: "试试搜索歌曲名、歌手或专辑"
                        )
                        .frame(minHeight: 220)
                    } else {
                        TrackListView(
                            tracks: visibleTracks,
                            source: .none
                        )
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                    }
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
                    Task { await loadTracks() }
                } label: {
                    Label("刷新红心歌曲", systemImage: "arrow.clockwise")
                }
            }
        }
        .searchable(text: $query, prompt: "搜索红心歌曲")
        .task(id: account.likedTrackIDs) {
            await account.refreshForOpen()
            await loadTracks()
        }
        .refreshable {
            await account.refreshLibrary()
            await loadTracks()
        }
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
                    LinearGradient(
                        colors: [Theme.accent, Theme.accent.opacity(0.58)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text("我喜欢的音乐")
                    .font(.title3.weight(.bold))
                Text(account.isLoggedIn
                     ? "\(account.likedTrackIDs.count) 首 · 网易云云端同步"
                     : "登录网易云后查看你的红心歌单")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private var loginState: some View {
        VStack(spacing: 14) {
            EmptyStateView(
                icon: "person.crop.circle.badge.plus",
                title: "登录网易云查看红心歌曲",
                subtitle: "红心歌单来自网易云账号，不会使用应用内置账号"
            )
            Button {
                openLogin()
            } label: {
                Label("登录网易云", systemImage: "person.crop.circle.badge.checkmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.horizontal, Theme.Layout.contentInset * 2)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    @MainActor
    private func loadTracks() async {
        guard account.isLoggedIn else {
            tracks = []
            errorMessage = nil
            return
        }

        let ids = account.likedTrackIDs.sorted(by: >)
        guard !ids.isEmpty else {
            tracks = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            var fetched: [Track] = []
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids.dropFirst(start).prefix(500))
                let response = try await NeteaseAPI.songDetails(ids: chunk)
                let lookup = Dictionary(
                    response.songs.map { ($0.id, $0.normalizedForLXPlayback()) },
                    uniquingKeysWith: { first, _ in first }
                )
                fetched.append(contentsOf: chunk.compactMap { lookup[$0] })
            }

            tracks = fetched
            if fetched.isEmpty {
                errorMessage = "红心歌曲暂时无法读取，请稍后重试"
            }
        } catch {
            tracks = []
            errorMessage = "红心歌曲暂时无法读取，请检查网络后重试"
        }
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
        isImporting = true
        Task {
            do {
                _ = try await store.importPlaylist(from: input)
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

                    if playlist.tracks.isEmpty {
                        EmptyStateView(icon: "music.note.list", title: "歌单暂无歌曲")
                            .frame(minHeight: 260)
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
        .searchable(text: $playlistQuery, prompt: "搜索此歌单")
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
