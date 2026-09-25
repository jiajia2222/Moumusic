#if os(iOS)
import SwiftUI

/// Beans-style “我的” surface.  It is intentionally a real navigation hub,
/// not a decorative replacement for Settings: every card opens the existing
/// Moumusic feature and keeps the account/source separation intact.
struct MyProfileView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var qqMusic: QQMusicSessionStore
    @EnvironmentObject private var kugou: KugouSessionStore
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @Environment(\.openLogin) private var openLogin
    @StateObject private var syncStore = ListeningSyncStore.shared
    @State private var showDownloads = false
    @State private var showQQMusicLogin = false
    @State private var showKugouLogin = false
    @State private var showBilibiliLogin = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                accountCard
                accountSourcesCard
                listeningCard
                quickLinks
                appearanceCard
                supportCard
                PlayerClearanceSpacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDownloads) {
            NavigationStack {
                DownloadsView()
                    .environmentObject(player)
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
        .sheet(isPresented: $showBilibiliLogin) {
            BilibiliLoginSheet()
                .environmentObject(bilibili)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("我的")
                .font(.system(size: 38, weight: .bold, design: .rounded))
            Spacer()
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.primary.opacity(0.10), lineWidth: 1))
            }
            .accessibilityLabel("设置")
        }
    }

    private var accountCard: some View {
        MouGlassCard(cornerRadius: 28) {
            HStack(spacing: 14) {
                if let profile = account.profile {
                    CachedAsyncImage(url: profile.avatarUrl?.resizedImageURL(192)) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 68, height: 68)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.secondary)
                        .frame(width: 68, height: 68)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(account.profile?.nickname ?? "未登录")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    Text(account.isLoggedIn ? "账号资料与歌单已同步" : "登录以同步歌单和听歌记录")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                NavigationLink(value: Destination.accountSync) {
                    Image(systemName: account.isLoggedIn ? "checkmark.circle.fill" : "person.badge.plus")
                        .font(.title2)
                        .foregroundStyle(account.isLoggedIn ? .green : Theme.accent)
                }
                .accessibilityLabel(account.isLoggedIn ? "查看账号同步" : "登录账号")
            }
        }
    }

    private var listeningCard: some View {
        MouGlassCard {
            VStack(alignment: .leading, spacing: 13) {
                Label("听歌时长", systemImage: "waveform.path.ecg")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                HStack(spacing: 10) {
                    metric(title: "累计时长", value: syncStore.formattedDuration)
                    metric(title: "已同步歌曲", value: "\(syncStore.syncedTrackCount)")
                    metric(title: "状态", value: syncStore.statusText)
                }
                Text("仅同步账号资料、歌单和听歌记录；播放地址仍由用户导入的 LX 音源提供。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountSourcesCard: some View {
        MouGlassCard(padding: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Label("账号音源与同步", systemImage: "person.2.wave.2")
                    .font(.headline.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)

                accountSourceRow(
                    title: "网易云音乐",
                    subtitle: account.isLoggedIn ? (account.profile?.nickname ?? "已登录") : "未登录 · 同步歌单与听歌记录",
                    icon: "music.note",
                    isLoggedIn: account.isLoggedIn,
                    action: { openLogin() },
                    destination: .accountSync
                )
                Divider().padding(.leading, 48)

                accountSourceRow(
                    title: "QQ 音乐",
                    subtitle: qqMusic.isLoggedIn ? (qqMusic.profileName ?? "已登录") : "未登录 · 扫码同步账号资料",
                    icon: "music.quarternote.3",
                    isLoggedIn: qqMusic.isLoggedIn
                ) {
                    showQQMusicLogin = true
                }
                Divider().padding(.leading, 48)

                accountSourceRow(
                    title: "酷狗音乐",
                    subtitle: kugou.isLoggedIn ? (kugou.profileName ?? "已登录") : "未登录 · 扫码同步账号资料",
                    icon: "headphones",
                    isLoggedIn: kugou.isLoggedIn
                ) {
                    showKugouLogin = true
                }
                Divider().padding(.leading, 48)

                accountSourceRow(
                    title: "哔哩哔哩",
                    subtitle: bilibili.isLoggedIn ? (bilibili.profileName ?? "已登录") : "未登录 · 同步资料与视频服务",
                    icon: "play.rectangle.fill",
                    isLoggedIn: bilibili.isLoggedIn
                ) {
                    showBilibiliLogin = true
                }

                Text("账号登录只负责同步资料、歌单和历史；播放地址仍按播放设置使用账号能力或用户导入的 LX 音源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private func accountSourceRow(
        title: String,
        subtitle: String,
        icon: String,
        isLoggedIn: Bool,
        action: @escaping () -> Void,
        destination: Destination? = nil
    ) -> some View {
        let row = HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isLoggedIn ? .green : Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: isLoggedIn ? "checkmark.circle.fill" : "chevron.right")
                .foregroundStyle(isLoggedIn ? .green : .tertiary)
        }
        .contentShape(Rectangle())
        .frame(minHeight: 58)

        if let destination {
            NavigationLink(value: destination) {
                row
            }
            .buttonStyle(.plain)
        } else {
            Button(action: action) {
                row
            }
            .buttonStyle(.plain)
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickLinks: some View {
        MouGlassCard(padding: 8) {
            VStack(spacing: 0) {
                profileRow("红心歌曲", icon: "heart.fill", tint: .pink, destination: .likedSongs)
                divider
                profileRow("最近播放", icon: "clock.fill", tint: .orange, destination: .recents)
                divider
                profileRow("我的歌单", icon: "music.note.list", tint: Theme.accent, destination: .localPlaylists)
                divider
                Button { showDownloads = true } label: {
                    rowLabel("下载管理", icon: "arrow.down.circle.fill", tint: .blue)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 52)
            }
        }
    }

    private var appearanceCard: some View {
        MouGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("主题模式", systemImage: "circle.lefthalf.filled")
                    .font(.headline.weight(.semibold))
                Picker("主题模式", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                Text("外观切换会同步应用页面、播放器和设置页。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var supportCard: some View {
        MouGlassCard {
            VStack(alignment: .leading, spacing: 11) {
                Label("项目支持", systemImage: "heart.circle.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                NavigationLink {
                    AfdianSupportView()
                } label: {
                    rowLabel("赞赏与支持", icon: "heart.fill", tint: Theme.accent)
                }
                .buttonStyle(.plain)
                Text("感谢每一位支持 Moumusic 的用户。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func profileRow(_ title: String, icon: String, tint: Color, destination: Destination) -> some View {
        NavigationLink(value: destination) {
            rowLabel(title, icon: icon, tint: tint)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 52)
    }

    private func rowLabel(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(title)
                .font(.body.weight(.medium))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var divider: some View {
        Divider().padding(.leading, 40)
    }
}
#endif
