import SwiftUI

/// Optional account page. Login is deliberately isolated from LX source
/// management: it synchronises account metadata and listening history only.
struct AccountSyncView: View {
    @EnvironmentObject private var account: AccountStore
    @StateObject private var syncStore = ListeningSyncStore.shared
    @EnvironmentObject private var player: PlayerService

    @State private var showLogin = false
    @State private var isRefreshing = false
    @State private var records: [PlayRecordItem] = []
    @State private var recordsError: String?
    @State private var showPlaylistPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceOnlyNotice

                if account.isLoggedIn, let profile = account.profile {
                    profileCard(profile)
                    cloudPlaylistsCard
                    syncCard
                    recentRecords
                } else {
                    loginCard
                }

                PlayerClearanceSpacer()
            }
            .padding(.horizontal, Theme.Layout.contentInset)
            .padding(.top, 12)
        }
        .navigationTitle("账号同步")
        .toolbar {
            if account.isLoggedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("刷新账号数据")
                }
            }
        }
        .task(id: account.isLoggedIn) {
            if account.isLoggedIn { await refresh() }
        }
        .sheet(isPresented: $showLogin) {
            NavigationStack {
                LoginSheet()
                    .navigationTitle("登录账号")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showPlaylistPicker) {
            NavigationStack {
                RemotePlaylistPickerView()
                    .environmentObject(account)
            }
            .presentationDetents([.large])
        }
    }

    private var sourceOnlyNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("登录只用于同步，不是音源", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(Theme.accent)
            Text("登录后可同步账号资料、每日推荐、播放记录和听歌时长。歌曲播放仍然只使用你在 LX 音源页面导入并启用的 User API，不会使用账号接口提供音频。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 1)
        }
    }

    private var loginCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("登录以开启同步")
                .font(.title3.weight(.semibold))
            Text("不会改变音源，也不会替代 LX 播放。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                showLogin = true
            } label: {
                Label("登录网易云账号", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.accentGradient, in: Capsule())
            }
            .buttonStyle(.pressable)
            .frame(minHeight: 48)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func profileCard(_ profile: UserProfile) -> some View {
        HStack(spacing: 14) {
            CachedAsyncImage(url: profile.avatarUrl?.resizedImageURL(192)) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 1))

            VStack(alignment: .leading, spacing: 5) {
                Text(profile.nickname.isEmpty ? "已登录账号" : profile.nickname)
                    .font(.title3.weight(.semibold))
                Text("账号资料已同步")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出", role: .destructive) {
                Task { await account.logout(); records = [] }
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("听歌同步", systemImage: "chart.bar.xaxis")
                .font(.headline)
            HStack(spacing: 10) {
                syncMetric(title: "本机已同步", value: syncStore.formattedDuration)
                syncMetric(title: "歌曲数", value: "\(syncStore.syncedTrackCount)")
                syncMetric(title: "状态", value: "已开启")
            }
            Text("播放歌曲达到有效时长后，Moumusic 会把匹配到的歌曲播放记录和时长同步到账号。LX 音源只负责提供音频地址。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let date = syncStore.lastSyncedAt {
                Text("最近上报 " + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("播放达到有效时长后会自动上报")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var cloudPlaylistsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label("云端歌单", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
                if account.isSyncingPlaylists {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("已获取 \(account.userPlaylists.count) 个歌单，包含我喜欢的音乐和收藏歌单。选择后才会加入本地歌单；已加入的歌单会在每次打开应用时检查更新。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: account.lastPlaylistSyncAt == nil ? "clock" : "checkmark.circle.fill")
                    .foregroundStyle(account.lastPlaylistSyncAt == nil ? .secondary : .green)
                Text(lastPlaylistSyncText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("刷新") {
                    Task { await refresh() }
                }
                .font(.caption.weight(.semibold))
                .disabled(isRefreshing || account.isSyncingPlaylists)
            }

            Button {
                showPlaylistPicker = true
            } label: {
                Label("选择要加入的歌单", systemImage: "checklist")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)

            if let error = account.lastPlaylistSyncError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var lastPlaylistSyncText: String {
        guard let date = account.lastPlaylistSyncAt else { return "尚未同步云端歌单" }
        return "上次同步 \(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now))"
    }

    private func syncMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var recentRecords: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("最近播放", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
            }

            if let recordsError {
                Text(recordsError)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if records.isEmpty && !isRefreshing {
                Text("暂时没有播放记录。登录只用于同步账号信息，不会影响 LX 音源播放。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                TrackListView(tracks: records.map(\.song), style: .compact, source: .none, context: .recents)
            }
        }
    }

    private func refresh() async {
        guard account.isLoggedIn else { return }
        isRefreshing = true
        recordsError = nil
        defer { isRefreshing = false }

        // Refresh the account first. The previous implementation captured the
        // user ID before bootstrap(), so a stale profile could be used for the
        // first records request after login or account switching.
        await account.bootstrap()
        guard account.isLoggedIn, let uid = account.profile?.userId else {
            recordsError = "账号状态已失效，请重新登录后再试。"
            return
        }
        do {
            records = try await NeteaseAPI.playRecords(uid: uid, week: true)
        } catch {
            recordsError = "播放记录暂时无法获取，稍后可重试。"
        }
    }
}

/// Lets the user opt individual cloud playlists into the local playlist page.
/// The source is intentionally provider-specific; an LX User API script does
/// not provide a common account or playlist protocol for other platforms.
struct RemotePlaylistPickerView: View {
    @EnvironmentObject private var account: AccountStore
    @StateObject private var localPlaylists = LocalPlaylistStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs = Set<Int>()
    @State private var isImporting = false

    private var likedPlaylists: [PlaylistSummary] {
        account.userPlaylists.filter(\.isLikedSongsList)
    }

    private var createdPlaylists: [PlaylistSummary] {
        account.createdPlaylists
    }

    private var subscribedPlaylists: [PlaylistSummary] {
        account.subscribedPlaylists
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("选择要同步的歌单", systemImage: "arrow.down.circle")
                        .font(.title3.weight(.semibold))
                    Text("只会导入你勾选的歌单。之后应用每次打开都会检查已加入歌单的更新时间，有变化时自动更新本地副本。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                playlistSection("我喜欢的音乐", playlists: likedPlaylists)
                playlistSection("我的歌单", playlists: createdPlaylists)
                playlistSection("收藏的歌单", playlists: subscribedPlaylists)

                if account.userPlaylists.isEmpty {
                    EmptyStateView(
                        icon: "music.note.list",
                        title: "暂时没有云端歌单",
                        subtitle: "请先刷新账号数据，或确认当前账号有可见歌单。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
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
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    importSelected()
                } label: {
                    if isImporting {
                        ProgressView()
                    } else {
                        Text("添加 \(selectedIDs.count)")
                    }
                }
                .disabled(isImporting || selectedIDs.isEmpty)
            }
        }
        .task {
            selectedIDs = Set(account.userPlaylists.filter {
                localPlaylists.containsRemotePlaylist(source: "netease", id: $0.id)
            }.map(\.id))
        }
    }

    @ViewBuilder
    private func playlistSection(_ title: String, playlists: [PlaylistSummary]) -> some View {
        if !playlists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                VStack(spacing: 8) {
                    ForEach(playlists) { playlist in
                        playlistRow(playlist)
                    }
                }
            }
        }
    }

    private func playlistRow(_ playlist: PlaylistSummary) -> some View {
        let isSelected = selectedIDs.contains(playlist.id)
        let isImported = localPlaylists.containsRemotePlaylist(source: "netease", id: playlist.id)

        return Button {
            if isSelected {
                selectedIDs.remove(playlist.id)
            } else {
                selectedIDs.insert(playlist.id)
            }
        } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(128), animated: false)
                    .frame(width: 52, height: 52)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(playlist.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isImported {
                            Text("已加入")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text("\(playlist.trackCount) 首 · \(playlist.creator?.nickname ?? "云端歌单")")
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
            .background(
                isSelected ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(playlist.name)，\(isSelected ? "已选择" : "未选择")")
    }

    private func importSelected() {
        isImporting = true
        Task {
            let report = await account.importSelectedPlaylists(selectedIDs)
            isImporting = false
            if report.failed.isEmpty {
                ToastCenter.shared.show("已添加 \(report.changedCount) 个歌单，后续会自动同步更新")
                dismiss()
            } else {
                ToastCenter.shared.show("已完成部分同步，\(report.failed.count) 个歌单稍后重试")
                dismiss()
            }
        }
    }
}
