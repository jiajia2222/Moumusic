#if os(iOS)
import SwiftUI

/// Account page of one music platform (QQ 音乐 / 酷狗音乐), opened from that platform's own
/// home page. Login, membership and cloud playlists live here, not in a mixed account list.
struct PlatformAccountPage: View {
    let platform: LXCatalogPlatform

    @EnvironmentObject private var qqMusic: QQMusicSessionStore
    @EnvironmentObject private var kugou: KugouSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLogin = false
    @State private var confirmSignOut = false

    private var title: String { platform == .kg ? "酷狗音乐" : "QQ 音乐" }
    private var brand: String { platform == .kg ? "BrandKugou" : "BrandQQ" }
    private var isLoggedIn: Bool { platform == .kg ? kugou.isLoggedIn : qqMusic.isLoggedIn }

    private var statusText: String {
        guard isLoggedIn else { return "未登录 · 扫码 / 手机号 / 网页登录" }
        if platform == .kg {
            return (kugou.profileName ?? "已登录") + (kugou.isVIP ? " · 会员" : " · 非会员")
        }
        let vip = qqMusic.isVIP.map { $0 ? " · 会员" : " · 非会员" } ?? ""
        return (qqMusic.profileName ?? "已登录") + vip
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MouGlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 14) {
                                BrandIconView(name: brand).frame(width: 52, height: 52)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title).font(.title3.weight(.semibold))
                                    Text(statusText)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                if isLoggedIn {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                                }
                            }
                            if isLoggedIn {
                                Button(role: .destructive) { confirmSignOut = true } label: {
                                    Text("退出登录").frame(maxWidth: .infinity, minHeight: 40)
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button { showLogin = true } label: {
                                    Text("登录\(title)").frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Text("账号登录只用于同步资料、歌单和播放记录；播放来源由设置里的播放来源决定。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)

                    if isLoggedIn {
                        PlatformAccountPlaylists(platform: platform)
                    }
                    PlayerClearanceSpacer()
                }
                .padding(.top, 12)
            }
            .navigationTitle("\(title)账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .sheet(isPresented: $showLogin) {
                if platform == .kg {
                    KugouLoginSheet().environmentObject(kugou)
                } else {
                    QQMusicLoginSheet().environmentObject(qqMusic)
                }
            }
            .confirmationDialog("退出\(title)登录？", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    if platform == .kg { kugou.signOut() } else { qqMusic.signOut() }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}
/// Bilibili account page: membership, sign-out and 收藏夹 sync.
struct BilibiliAccountPage: View {
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MouGlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 14) {
                                BrandIconView(name: "BrandBilibili").frame(width: 52, height: 52)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("哔哩哔哩").font(.title3.weight(.semibold))
                                    Text((bilibili.profileName ?? "已登录") + " · " + (bilibili.membershipTitle ?? "非会员"))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                            }
                            Button(role: .destructive) { confirmSignOut = true } label: {
                                Text("退出登录").frame(maxWidth: .infinity, minHeight: 40)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)

                    BilibiliCloudPlaylistsCard().environmentObject(bilibili)
                    PlayerClearanceSpacer()
                }
                .padding(.top, 12)
            }
            .navigationTitle("哔哩哔哩账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .confirmationDialog("退出哔哩哔哩登录？", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    bilibili.signOut()
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}
#endif