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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceOnlyNotice

                if account.isLoggedIn, let profile = account.profile {
                    profileCard(profile)
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
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        guard account.isLoggedIn, let uid = account.profile?.userId else { return }
        isRefreshing = true
        recordsError = nil
        await account.bootstrap()
        do {
            records = try await NeteaseAPI.playRecords(uid: uid, week: true)
        } catch {
            recordsError = "播放记录暂时无法获取，稍后可重试。"
        }
        isRefreshing = false
    }
}
