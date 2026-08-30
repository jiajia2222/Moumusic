import SwiftUI
import UniformTypeIdentifiers

struct LocalPlaylistsView: View {
    @StateObject private var store = LocalPlaylistStore.shared
    @State private var showImport = false
    @State private var showCreate = false
    @State private var newName = ""

    var body: some View {
        ScrollView {
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
                .padding(.top, 14)
            }
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
                                Text("支持网易云、QQ、酷我、酷狗、咪咕歌单链接，也支持 JSON 或每行一首歌（歌名 - 歌手）")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
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
                    Text("导入歌单会保存到本机，不会修改原音乐软件的歌单。链接导入会保留原平台歌曲，JSON 或文本导入会尝试用聚合搜索匹配可播放歌曲。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                allowedContentTypes: [.json, .plainText],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    input = try String(contentsOf: url, encoding: .utf8)
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
}

struct LocalPlaylistDetailView: View {
    let playlistID: UUID

    @StateObject private var store = LocalPlaylistStore.shared
    @EnvironmentObject private var player: PlayerService
    @State private var showRename = false
    @State private var renameText = ""

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
                            tracks: playlist.tracks,
                            source: .none,
                            onRemoved: { track in
                                store.remove(track, from: playlistID)
                            }
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
