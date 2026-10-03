#if os(iOS)
import SwiftUI

/// One account playlist of a platform (QQ 音乐 / 酷狗 / 哔哩哔哩 收藏夹) that can be
/// mirrored into the local playlist page, exactly like the NetEase cloud playlists.
struct CloudPlaylistItem: Identifiable {
    let id: String
    let name: String
    let coverURL: String?
    let count: Int
    let load: () async throws -> [Track]
}

enum CloudPlaylistSync {
    /// Re-fetches every already-added playlist of `source` so the local copies stay current.
    @MainActor
    static func refreshMirrored(source: String, sourceName: String, items: [CloudPlaylistItem]) async {
        let store = LocalPlaylistStore.shared
        for item in items where store.containsRemotePlaylist(source: source, key: item.id) {
            guard let tracks = try? await item.load(), !tracks.isEmpty else { continue }
            store.upsertRemotePlaylist(source: source, remoteKey: item.id, name: item.name,
                                       coverURL: item.coverURL, sourceName: sourceName,
                                       revision: item.count, tracks: tracks)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "moumusic.cloudsync.\(source)")
    }

    /// Imports the selected playlists; returns (added or updated, failed names).
    @MainActor
    static func importSelected(source: String, sourceName: String, items: [CloudPlaylistItem],
                               selected: Set<String>) async -> (changed: Int, failed: [String]) {
        var changed = 0
        var failed: [String] = []
        for item in items where selected.contains(item.id) {
            do {
                let tracks = try await item.load()
                guard !tracks.isEmpty else {
                    failed.append("\(item.name)：没有可同步的歌曲")
                    continue
                }
                let result = LocalPlaylistStore.shared.upsertRemotePlaylist(
                    source: source, remoteKey: item.id, name: item.name, coverURL: item.coverURL,
                    sourceName: sourceName, revision: item.count, tracks: tracks)
                if result.inserted || result.changed { changed += 1 }
            } catch {
                failed.append(item.name)
            }
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "moumusic.cloudsync.\(source)")
        return (changed, failed)
    }
}

/// "云端歌单" card for a platform page: count, last sync, refresh and the picker entry.
struct PlatformCloudPlaylistsCard: View {
    let source: String
    let sourceName: String
    let items: [CloudPlaylistItem]
    var onRefresh: (() async -> Void)? = nil

    @ObservedObject private var local = LocalPlaylistStore.shared
    @AppStorage private var lastSyncTime: Double
    @State private var showPicker = false
    @State private var isRefreshing = false

    init(source: String, sourceName: String, items: [CloudPlaylistItem], onRefresh: (() async -> Void)? = nil) {
        self.source = source
        self.sourceName = sourceName
        self.items = items
        self.onRefresh = onRefresh
        _lastSyncTime = AppStorage(wrappedValue: 0, "moumusic.cloudsync.\(source)")
    }

    private var importedCount: Int {
        items.filter { local.containsRemotePlaylist(source: source, key: $0.id) }.count
    }

    private var lastSyncText: String {
        guard lastSyncTime > 0 else { return "尚未同步云端歌单" }
        let date = Date(timeIntervalSince1970: lastSyncTime)
        return "上次同步 \(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label("云端歌单", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
            }

            Text("已获取 \(items.count) 个\(sourceName)歌单，其中 \(importedCount) 个已加入本地歌单。选择后才会加入本地歌单；已加入的歌单会在每次打开应用时检查更新。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: lastSyncTime == 0 ? "clock" : "checkmark.circle.fill")
                    .foregroundStyle(lastSyncTime == 0 ? Color.secondary : Color.green)
                Text(lastSyncText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("刷新") {
                    Task {
                        isRefreshing = true
                        await onRefresh?()
                        await CloudPlaylistSync.refreshMirrored(source: source, sourceName: sourceName, items: items)
                        isRefreshing = false
                    }
                }
                .font(.caption.weight(.semibold))
                .disabled(isRefreshing)
            }

            Button {
                showPicker = true
            } label: {
                Label("选择要加入的歌单（支持全选）", systemImage: "checklist")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .mouMaterialBackground(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, Theme.Layout.contentInset)
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                PlatformCloudPlaylistPicker(source: source, sourceName: sourceName, items: items)
            }
            .presentationDetents([.large])
        }
    }
}

struct PlatformCloudPlaylistPicker: View {
    let source: String
    let sourceName: String
    let items: [CloudPlaylistItem]

    @ObservedObject private var local = LocalPlaylistStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var isImporting = false

    private var allSelected: Bool {
        !items.isEmpty && Set(items.map(\.id)).isSubset(of: selected)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("选择要同步的歌单", systemImage: "arrow.down.circle")
                        .font(.title3.weight(.semibold))
                    Text("只会导入你勾选的歌单。之后应用每次打开都会检查已加入歌单的更新，有变化时自动更新本地副本。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Text("已选择 \(selected.count) / \(items.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(allSelected ? "取消全选" : "全选") {
                        if allSelected { selected.removeAll() } else { selected = Set(items.map(\.id)) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(items.isEmpty || isImporting)
                }

                if items.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "暂时没有云端歌单",
                                   subtitle: "请先刷新，或确认当前账号有可见歌单。")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }

                VStack(spacing: 8) {
                    ForEach(items) { item in row(item) }
                }
                PlayerClearanceSpacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("同步歌单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    importSelected()
                } label: {
                    if isImporting { ProgressView() } else { Text("添加 \(selected.count)") }
                }
                .disabled(isImporting || selected.isEmpty)
            }
        }
        .task {
            selected = Set(items.filter { local.containsRemotePlaylist(source: source, key: $0.id) }.map(\.id))
        }
    }

    private func row(_ item: CloudPlaylistItem) -> some View {
        let isSelected = selected.contains(item.id)
        let isImported = local.containsRemotePlaylist(source: source, key: item.id)
        return Button {
            if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: item.coverURL?.resizedImageURL(128), animated: false)
                    .frame(width: 52, height: 52)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isImported {
                            Text("已加入")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text("\(item.count) 首 · \(sourceName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                    .frame(width: 44, height: 44)
            }
            .padding(10)
            .background(isSelected ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func importSelected() {
        isImporting = true
        Task {
            let report = await CloudPlaylistSync.importSelected(source: source, sourceName: sourceName,
                                                                items: items, selected: selected)
            isImporting = false
            if report.failed.isEmpty {
                ToastCenter.shared.show("已添加 \(report.changed) 个歌单，后续会自动同步更新")
            } else {
                ToastCenter.shared.show("已完成部分同步，\(report.failed.count) 个歌单稍后重试")
            }
            dismiss()
        }
    }
}

/// Bilibili 收藏夹 as cloud playlists (videos become tracks played through the music player).
struct BilibiliCloudPlaylistsCard: View {
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @State private var folders: [BilibiliAPI.FavoriteFolder] = []

    private var items: [CloudPlaylistItem] {
        let cookie = bilibili.cookie
        return folders.map { folder in
            CloudPlaylistItem(id: String(folder.id), name: folder.title, coverURL: folder.coverURL, count: folder.mediaCount) {
                var videos: [BilibiliAPI.Video] = []
                for page in 1...8 {
                    let batch = try await BilibiliAPI.shared.favoriteVideos(folderID: folder.id, page: page, pageSize: 30, cookie: cookie)
                    videos += batch
                    if batch.count < 30 { break }
                }
                return videos.map { Track.bilibili($0) }
            }
        }
    }

    var body: some View {
        Group {
            if !folders.isEmpty {
                PlatformCloudPlaylistsCard(source: "bilibili", sourceName: "哔哩哔哩收藏夹", items: items) {
                    await load()
                }
            }
        }
        .task(id: bilibili.isLoggedIn) {
            await load()
            await CloudPlaylistSync.refreshMirrored(source: "bilibili", sourceName: "哔哩哔哩收藏夹", items: items)
        }
    }

    private func load() async {
        guard bilibili.isLoggedIn else { folders = []; return }
        folders = (try? await BilibiliAPI.shared.favoriteFolders(cookie: bilibili.cookie)) ?? folders
    }
}
#endif