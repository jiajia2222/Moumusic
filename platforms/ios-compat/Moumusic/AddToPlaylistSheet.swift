import SwiftUI

/// 记录“这首歌被本 App 收藏到了哪些官方歌单”，用于展示「取消官方歌单收藏」。
final class OfficialPlaylistMembershipStore {
    static let shared = OfficialPlaylistMembershipStore()
    private let key = "beans.officialPlaylistMembership.v1"
    private var map: [String: [Int]]

    private init() {
        map = (UserDefaults.standard.dictionary(forKey: key) as? [String: [Int]]) ?? [:]
    }

    func playlists(for song: Song) -> [Int] { map[song.identityKey] ?? [] }

    func add(_ playlistID: Int, for song: Song) {
        var list = map[song.identityKey] ?? []
        if !list.contains(playlistID) { list.append(playlistID) }
        map[song.identityKey] = list
        save()
    }

    func remove(_ playlistID: Int, for song: Song) {
        map[song.identityKey]?.removeAll { $0 == playlistID }
        if map[song.identityKey]?.isEmpty == true { map[song.identityKey] = nil }
        save()
    }

    func forget(playlist playlistID: Int) {
        for (k, v) in map { map[k] = v.filter { $0 != playlistID } }
        save()
    }

    private func save() {
        UserDefaults.standard.set(map, forKey: key)
    }
}

/// 官方歌单收藏：目前支持网易云音乐官方歌单；其他平台保存在本地收藏。
struct AddToPlaylistSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    private let favorites = FavoritesStore.shared
    private let membership = OfficialPlaylistMembershipStore.shared
    @Environment(\.dismiss) private var dismiss

    let song: Song
    @State private var newName = ""
    @State private var showCreateField = false
    @State private var message: String?
    @State private var memberIDs: [Int] = []
    @State private var showRemovePicker = false
    @State private var showAddPicker = true

    /// 只展示用户自己创建的普通歌单（排除「我喜欢的音乐」等特殊歌单）。
    private var writablePlaylists: [Playlist] {
        auth.playlists.filter { $0.specialType == 0 }
    }

    private var isSupported: Bool { song.source == .netease }

    private var memberPlaylists: [Playlist] {
        auth.playlists.filter { memberIDs.contains($0.id) }
    }

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            List {
                if !isSupported {
                    Section {
                        Text(song.source == .qq ? "当前不支持 QQ 官方歌单收藏，已使用本地收藏" : "当前平台仅支持本地收藏")
                            .foregroundStyle(Color.beansComment)
                        Button {
                            Task {
                                if !favorites.isLiked(song) { _ = await favorites.toggle(song) }
                                ToastCenter.shared.show("已加入本地收藏")
                                dismiss()
                            }
                        } label: {
                            Label("加入本地收藏", systemImage: "heart")
                        }
                    }
                } else {
                    if !memberIDs.isEmpty {
                        Section {
                            Text("这首歌已收藏到官方歌单；可以继续保存到另一份歌单，或选择要取消的歌单。")
                                .font(BeansFont.appFont(13))
                                .foregroundStyle(Color.beansComment)
                            Button {
                                showAddPicker = true
                                showRemovePicker = false
                            } label: {
                                Label("收藏到其他官方歌单", systemImage: "plus.circle")
                            }
                            Button(role: .destructive) {
                                showRemovePicker.toggle()
                            } label: {
                                Label("取消官方歌单收藏", systemImage: "minus.circle")
                            }
                        }
                    }

                    if showRemovePicker {
                        Section("选择要取消的歌单") {
                            if memberPlaylists.isEmpty {
                                Text("未找到可取消的官方歌单").foregroundStyle(Color.beansComment)
                            }
                            ForEach(memberPlaylists) { playlist in
                                Button {
                                    Task { await remove(from: playlist) }
                                } label: {
                                    playlistRow(playlist)
                                }
                            }
                            Text("选择后只会取消该官方歌单中的歌曲。")
                                .font(BeansFont.appFont(11)).foregroundStyle(Color.beansComment)
                        }
                    }

                    if showAddPicker && !showRemovePicker {
                        if writablePlaylists.isEmpty {
                            Text("暂无歌单，请先创建一个")
                                .foregroundStyle(Color.beansComment)
                        } else {
                            Section("选择官方歌单") {
                                ForEach(writablePlaylists.filter { !memberIDs.contains($0.id) }) { playlist in
                                    Button {
                                        Task { await add(to: playlist) }
                                    } label: {
                                        playlistRow(playlist)
                                    }
                                }
                                Text("选择后歌曲会保存到该官方歌单。")
                                    .font(BeansFont.appFont(11)).foregroundStyle(Color.beansComment)
                            }
                        }
                    }

                    if showCreateField {
                        Section("新建官方歌单") {
                            TextField("歌单名称", text: $newName)
                                .submitLabel(.done)
                            Text("创建后可以继续选择它保存歌曲。")
                                .font(BeansFont.appFont(11)).foregroundStyle(Color.beansComment)
                            Button {
                                Task { await createAndAdd() }
                            } label: {
                                Text("创建并添加")
                                    .font(BeansFont.appFont(15, .semibold))
                                    .foregroundStyle(Color.beansAmber)
                            }
                        }
                    } else {
                        Button {
                            showCreateField = true
                        } label: {
                            Label("新建官方歌单", systemImage: "plus.circle")
                        }
                    }
                }

                if let message {
                    Section {
                        Text(message)
                            .font(BeansFont.appFont(13))
                            .foregroundStyle(Color.beansSage)
                    }
                }
            }
            .navigationTitle("官方歌单收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        .onAppear { memberIDs = membership.playlists(for: song) }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: playlist.coverURL, size: 38, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(BeansFont.appFont(15))
                    .foregroundStyle(Color.beansLabel)
                    .lineLimit(1)
                Text(beansSongCountText(playlist.trackCount))
                    .font(BeansFont.appFont(11))
                    .foregroundStyle(Color.beansComment)
            }
            Spacer()
        }
    }

    private func add(to playlist: Playlist) async {
        do {
            let ok = try await NetEaseAPI.shared.addToPlaylist(playlistID: playlist.id, songIDs: [song.id])
            if ok {
                membership.add(playlist.id, for: song)
                if !favorites.isLiked(song) { _ = await favorites.toggle(song) }
                ToastCenter.shared.show("已加入「\(playlist.name)」")
                dismiss()
            } else {
                message = "网易云音乐收藏失败"
            }
        } catch {
            message = "网易云音乐收藏失败"
        }
    }

    private func remove(from playlist: Playlist) async {
        do {
            let ok = try await NetEaseAPI.shared.removeFromPlaylist(playlistID: playlist.id, songIDs: [song.id])
            if ok {
                membership.remove(playlist.id, for: song)
                memberIDs = membership.playlists(for: song)
                ToastCenter.shared.show("已取消官方歌单收藏")
                if memberIDs.isEmpty { dismiss() }
            } else {
                message = "取消网易云收藏失败"
            }
        } catch {
            message = "取消网易云收藏失败"
        }
    }

    private func createAndAdd() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { message = "歌单名称不能为空"; return }
        do {
            let playlistID = try await NetEaseAPI.shared.createPlaylist(name: name)
            ToastCenter.shared.show("已创建网易云歌单")
            let ok = try await NetEaseAPI.shared.addToPlaylist(playlistID: playlistID, songIDs: [song.id])
            if ok {
                membership.add(playlistID, for: song)
                if !favorites.isLiked(song) { _ = await favorites.toggle(song) }
                await auth.loadLibrary(force: true)
                dismiss()
            } else {
                message = "歌单已创建，但添加歌曲失败"
            }
        } catch {
            message = "创建官方歌单失败：\(error.localizedDescription)"
        }
    }
}
