import SwiftUI

/// Optional account page. Login is deliberately isolated from LX source
/// management: it synchronises account metadata and listening history only.
struct AccountSyncView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var qqMusic: QQMusicSessionStore
    @EnvironmentObject private var kugou: KugouSessionStore
#if os(iOS)
    @EnvironmentObject private var bilibili: BilibiliSessionStore
#endif
    @StateObject private var syncStore = ListeningSyncStore.shared
    @EnvironmentObject private var player: PlayerService

    @State private var showLogin = false
    @State private var showQQMusicLogin = false
    @State private var showKugouLogin = false
#if os(iOS)
    @State private var showBilibiliLogin = false
#endif
    @State private var isRefreshing = false
    @State private var records: [PlayRecordItem] = []
    @State private var recordsError: String?
    @State private var showPlaylistPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceOnlyNotice
                platformAccountsCard
                platformSyncCapabilitiesCard

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
        .sheet(isPresented: $showQQMusicLogin) {
            QQMusicLoginSheet()
                .environmentObject(qqMusic)
        }
        .sheet(isPresented: $showKugouLogin) {
            KugouLoginSheet()
                .environmentObject(kugou)
        }
#if os(iOS)
        .sheet(isPresented: $showBilibiliLogin) {
            BilibiliLoginSheet()
                .environmentObject(bilibili)
        }
#endif
        .sheet(isPresented: $showPlaylistPicker) {
            NavigationStack {
                RemotePlaylistPickerView()
                    .environmentObject(account)
            }
            .presentationDetents([.large])
        }
    }

    private var platformAccountsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("平台账号同步", systemImage: "person.2.badge.key.fill")
                .font(.headline)
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 6)

            Text("账号登录只同步资料、歌单和历史；播放仍由当前播放策略决定。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)

            platformRow(
                title: "QQ 音乐",
                subtitle: qqMusic.isLoggedIn ? "已登录 · 同步账号资料" : "未登录 · 扫码 / 手机号 / 网页",
                icon: "music.note.list",
                isLoggedIn: qqMusic.isLoggedIn
            ) { showQQMusicLogin = true }
            Divider().padding(.leading, 52)
            platformRow(
                title: "酷狗音乐",
                subtitle: kugou.isLoggedIn ? "已登录 · 同步账号资料" : "未登录 · 扫码 / 手机号 / 网页",
                icon: "headphones",
                isLoggedIn: kugou.isLoggedIn
            ) { showKugouLogin = true }
#if os(iOS)
            Divider().padding(.leading, 52)
            platformRow(
                title: "哔哩哔哩",
                subtitle: bilibili.isLoggedIn
                    ? "已登录 · \(bilibili.membershipTitle ?? "普通账号")"
                    : "未登录 · 扫码 / 手机号 / 网页",
                icon: "play.rectangle.fill",
                isLoggedIn: bilibili.isLoggedIn
            ) { showBilibiliLogin = true }
#endif
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var platformSyncCapabilitiesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("同步能力", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
                .foregroundStyle(Theme.accent)

            Text("这里只展示已经接入并验证过的云端同步能力；没有接口的平台不会伪造“已同步”。本地最近播放和听歌时长仍会保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            syncCapabilityRow(
                title: "网易云音乐",
                detail: account.isLoggedIn ? "歌单、最近播放、听歌时长：可同步" : "未登录：无法同步"
            )
            syncCapabilityRow(
                title: "QQ 音乐",
                detail: qqMusic.isLoggedIn ? "账号已登录；用户音乐歌单/听歌时长云同步：无法同步" : "未登录；用户音乐歌单/听歌时长云同步：无法同步"
            )
            syncCapabilityRow(
                title: "酷狗音乐",
                detail: kugou.isLoggedIn ? "账号已登录；用户音乐歌单/听歌时长云同步：无法同步" : "未登录；用户音乐歌单/听歌时长云同步：无法同步"
            )
#if os(iOS)
            syncCapabilityRow(
                title: "哔哩哔哩",
                detail: bilibili.isLoggedIn ? "账号资料、视频收藏/历史可用；音乐歌单/听歌时长云同步：无法同步" : "未登录；音乐歌单/听歌时长云同步：无法同步"
            )
#endif
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func syncCapabilityRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: detail.contains("可同步") && !detail.contains("无法")
                  ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(detail.contains("可同步") && !detail.contains("无法") ? .green : .orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Brand artwork for the four account platforms; other rows keep their symbol.
    @ViewBuilder
    private func platformMark(title: String, icon: String) -> some View {
        let brand: String? = {
            if title.contains("网易") { return "BrandNetease" }
            if title.contains("QQ") { return "BrandQQ" }
            if title.contains("酷狗") { return "BrandKugou" }
            if title.contains("哔哩") { return "BrandBilibili" }
            return nil
        }()
        if let brand {
            Image(brand, bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
        } else {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34)
        }
    }
    private func platformRow(
        title: String,
        subtitle: String,
        icon: String,
        isLoggedIn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                platformMark(title: title, icon: icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isLoggedIn ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(isLoggedIn ? .green : .secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
    private var sourceOnlyNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("账号音源与同步", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(Theme.accent)
            Text("登录后可以同步账号资料、每日推荐、播放记录和听歌时长。播放设置为“自动”或“账号音源”时，会优先尝试对应平台账号能提供的完整音频；失败后才按设置回退到 LX 音源。")
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
            Text("不会强制改变音源；是否优先使用账号音源由设置中的播放来源控制。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("选择要同步的账号平台")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 10) {
                accountLoginButton("网易云音乐", systemImage: "music.note", isPrimary: true) {
                    showLogin = true
                }
                accountLoginButton("QQ 音乐", systemImage: "music.note.list") {
                    showQQMusicLogin = true
                }
                accountLoginButton("酷狗音乐", systemImage: "headphones") {
                    showKugouLogin = true
                }
#if os(iOS)
                accountLoginButton("哔哩哔哩", systemImage: "play.rectangle.fill") {
                    showBilibiliLogin = true
                }
#endif
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func accountLoginButton(
        _ title: String,
        systemImage: String,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
            }
            .foregroundStyle(isPrimary ? Color.white : Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .padding(.horizontal, 15)
            .background(
                isPrimary ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.accent.opacity(0.10)),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.pressable)
        .accessibilityHint("打开\(title)的扫码、手机号或网页登录")
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
                syncMetric(title: "状态", value: syncStore.platformStatusText)
            }
            if syncStore.remotePlayCount > 0 {
                Text("网易云云端播放次数：\(syncStore.remotePlayCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if syncStore.remoteRecordsError != nil {
                Text("网易云最近播放暂时无法读取；播放时长上报会在网络恢复后继续尝试。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("播放歌曲达到有效时长后，Moumusic 会把匹配到的歌曲播放记录和时长同步到账号。没有可用账号音频时，LX 音源负责提供回退音频地址。")
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
                    .foregroundStyle(account.lastPlaylistSyncAt == nil ? Color.secondary : Color.green)
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
                Label("选择要加入的歌单（支持全选）", systemImage: "checklist")
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
        return VStack(alignment: .leading, spacing: 5) {
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
            await syncStore.refreshRemoteRecords(uid: uid)
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

    /// Keep selection based on unique remote IDs because a playlist can appear
    /// in more than one section (for example liked + created).
    private var visiblePlaylists: [PlaylistSummary] {
        var seen = Set<Int>()
        return (likedPlaylists + createdPlaylists + subscribedPlaylists).filter {
            seen.insert($0.id).inserted
        }
    }

    private var allVisiblePlaylistsSelected: Bool {
        let ids = Set(visiblePlaylists.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: selectedIDs)
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

                HStack(spacing: 12) {
                    Text("已选择 \(selectedIDs.count) / \(visiblePlaylists.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(allVisiblePlaylistsSelected ? "取消全选" : "全选") {
                        toggleSelectAll()
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(visiblePlaylists.isEmpty || isImporting)
                }

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

    private func toggleSelectAll() {
        let ids = Set(visiblePlaylists.map(\.id))
        if allVisiblePlaylistsSelected {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
        }
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
