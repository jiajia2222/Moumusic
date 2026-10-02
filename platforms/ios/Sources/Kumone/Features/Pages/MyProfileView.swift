#if os(iOS)
import SwiftUI

/// Beans-style 闂傚倸鍊烽懗鍫曞磻閵娾晛纾块柤纰卞墮閸ㄦ繄鈧箍鍎遍ˇ顖炲垂閸屾稓绡€濠电姴鍊绘晶娑㈡煕鎼达紕效闁哄本鐩鏉懳熼崫鍕庛劑姊?surface.  It is intentionally a real navigation hub,
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
    @StateObject private var moumusicServer = MoumusicServerStore.shared
    @State private var showDownloads = false
    @State private var showMoumusicAdminLogin = false
    @State private var showMoumusicAdminUsers = false
    @State private var showQQMusicLogin = false
    @State private var showKugouLogin = false
    @State private var showBilibiliLogin = false
    @State private var showMoumusicProfileEditor = false
    @ObservedObject private var deviceReporter = DeviceReporter.shared
    @State private var showDeviceCode = false
    @State private var showCustomize = false
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appearance = ProfileAppearanceStore.shared
    @State private var signedInTarget: SignedInTarget?
    @State private var showAccountPlaylists = false
    private enum SignedInTarget: String, Identifiable { case qq, kugou, bilibili; var id: String { rawValue } }
    @ObservedObject private var stats = ListeningStatsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                compactIdentity
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
        .task {
            _ = await moumusicServer.start()
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDownloads) {
            NavigationStack {
                DownloadsView()
                    .environmentObject(player)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showMoumusicAdminLogin) {
            MoumusicAdminLoginView()
                .environmentObject(moumusicServer)
        }
        .sheet(isPresented: $showMoumusicAdminUsers) {
            MoumusicAdminUsersView()
                .environmentObject(moumusicServer)
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
        .sheet(isPresented: $showCustomize) {
            ProfileCustomizeSheet()
        }
        .sheet(isPresented: $showDeviceCode) {
            DeviceCodeSheet()
        }
        .navigationDestination(isPresented: $showAccountPlaylists) {
            AccountPlaylistsView()
        }
        .confirmationDialog(
            signedInTarget.map { "\(signedInTitle($0)) 已登录" } ?? "",
            isPresented: Binding(get: { signedInTarget != nil }, set: { if !$0 { signedInTarget = nil } }),
            titleVisibility: .visible
        ) {
            if signedInTarget == .qq || signedInTarget == .kugou {
                Button("查看账号歌单") { showAccountPlaylists = true }
            }
            Button("退出登录", role: .destructive) {
                switch signedInTarget {
                case .qq: qqMusic.signOut()
                case .kugou: kugou.signOut()
                case .bilibili: bilibili.signOut()
                case nil: break
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showMoumusicProfileEditor) {
            MoumusicProfileEditorView()
                .environmentObject(moumusicServer)
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

    /// One compact card: who you are, account state and listening totals. The
    /// large profile card lives behind the "名片" button.
    private func signedInTitle(_ target: SignedInTarget) -> String {
        switch target {
        case .qq: return "QQ 音乐"
        case .kugou: return "酷狗音乐"
        case .bilibili: return "哔哩哔哩"
        }
    }

    private var compactIdentity: some View {
        let hasBackground = appearance.background != nil
        return MouGlassCard(cornerRadius: 24, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Group {
                        if let custom = appearance.avatar {
                            Image(uiImage: custom).resizable().scaledToFill()
                        } else if let profile = account.profile {
                            CachedAsyncImage(url: profile.avatarUrl?.resizedImageURL(160)) {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable().scaledToFit().foregroundStyle(.secondary)
                            }
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable().scaledToFit().foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.profile?.nickname ?? "Moumusic 用户")
                            .font(.headline)
                            .lineLimit(1)
                        Button {
                            showDeviceCode = true
                        } label: {
                            Text("ID \(String(deviceReporter.displayID.prefix(14))) · 设备码")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 8)
                    Button {
                        showCustomize = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("自定义头像和背景")
                }
                HStack(spacing: 10) {
                    metric(title: "本机听歌时长", value: stats.formattedDuration)
                    metric(title: "播放歌曲", value: "\(stats.totalPlayCount) 首")
                    metric(title: "连续听歌", value: "\(stats.streakDays) 天")
                }
            }
        }
        .background {
            if let image = appearance.background {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .overlay(Color.black.opacity(0.38))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
        .environment(\.colorScheme, hasBackground ? .dark : colorScheme)
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
                    Text(account.isLoggedIn ? "账号资料与歌单已同步" : "登录后同步歌单与播放记录")
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
                .accessibilityLabel(account.isLoggedIn ? "查看账号同步" : "登录")
            }
        }
    }

    private var moumusicIdentityCardLegacy: some View {
#if false
        MouGlassCard(cornerRadius: 28) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    if let value = moumusicServer.profile?.avatarURL, let url = URL(string: value) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, height: 64)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(moumusicServer.profile?.nickname ?? "Moumusic 用户")
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        Text("ID 闂?\(moumusicServer.displayID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: moumusicServer.isAdmin ? "checkmark.seal.fill" : "person.crop.circle.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(moumusicServer.isAdmin ? .orange : Theme.accent)
                }

                Divider()
                HStack {
                    Label("个人资料服务", systemImage: "server.rack")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(moumusicServer.statusText)
                        .font(.caption)
                        .foregroundStyle(moumusicServer.config == nil ? .secondary : Theme.accent)
                        .lineLimit(1)
                }

                if moumusicServer.isAdmin {
                    Toggle(isOn: Binding(
                        get: { moumusicServer.config?.downloadsEnabled ?? true },
                        set: { value in Task { await moumusicServer.setDownloadsEnabled(value) } }
                    )) {
                        Label("允许公开下载", systemImage: "arrow.down.circle")
                            .font(.subheadline)
                    }
                    .tint(Theme.accent)
                }
            }
        }

#endif
        return EmptyView()
    }

    private var moumusicIdentityCard: some View {
        MouGlassCard(cornerRadius: 28) {
            ZStack {
                if let background = moumusicServer.profile?.backgroundURL,
                   let url = URL(string: background), !background.isEmpty {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(Color.black.opacity(0.26))
                    .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    if let avatar = moumusicServer.profile?.avatarURL, let url = URL(string: avatar) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.secondary)
                            .frame(width: 64, height: 64)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(moumusicServer.profile?.nickname ?? "Moumusic 用户")
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        Text("个人 ID：\(moumusicServer.displayID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        showMoumusicProfileEditor = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑个人资料")
                    Image(systemName: moumusicServer.isAdmin ? "checkmark.seal.fill" : "person.crop.circle.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(moumusicServer.isAdmin ? .orange : Theme.accent)
                }

                Divider()
                HStack {
                    Label("Moumusic 服务", systemImage: "server.rack")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(moumusicServer.statusText)
                        .font(.caption)
                        .foregroundStyle(moumusicServer.config == nil ? .secondary : Theme.accent)
                        .lineLimit(1)
                }

                if let info = moumusicServer.config?.serverInfo {
                    VStack(alignment: .leading, spacing: 4) {
                        if let ipv4 = info.ipv4 { Text("IPv4  \(ipv4)") }
                        if let ipv6 = info.ipv6 { Text("IPv6  \(ipv6)") }
                        HStack(spacing: 12) {
                            if let cpu = info.cpuCores { Text("CPU  \(cpu) cores") }
                            if let memory = info.memoryMB { Text("RAM  \(memory) MB") }
                        }
                        HStack(spacing: 12) {
                            if let storage = info.storageGB { Text("Storage  \(storage) GB") }
                            if let network = info.networkPortMbps { Text("Network  \(network) Mbps") }
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }

                if moumusicServer.isAdmin {
                    Toggle(isOn: Binding(
                        get: { moumusicServer.config?.downloadsEnabled ?? true },
                        set: { value in Task { await moumusicServer.setDownloadsEnabled(value) } }
                    )) {
                            Label("允许公开下载", systemImage: "arrow.down.circle")
                            .font(.subheadline)
                    }
                    .tint(Theme.accent)
                    Button {
                        showMoumusicAdminUsers = true
                    } label: {
                        Label("管理用户资料与 ID", systemImage: "person.2.badge.gearshape")
                    }
                    .foregroundStyle(Theme.accent)
                } else {
                    Button("管理员登录") {
                        showMoumusicAdminLogin = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
                }
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
                    // The local counters survive logout, but they must not
                    // claim that the current account is still synchronized.
                    metric(title: "状态", value: syncStore.platformStatusText)
                }
                Text("网易云音乐账号负责同步最近播放与听歌时长；播放仍使用已选择的 LX 音源。未登录时不会尝试同步。")
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
                    subtitle: account.isLoggedIn ? (account.profile?.nickname ?? "已登录") : "未登录 · 同步歌单与播放记录",
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
                    if qqMusic.isLoggedIn { signedInTarget = .qq } else { showQQMusicLogin = true }
                }
                Divider().padding(.leading, 48)

                accountSourceRow(
                    title: "酷狗音乐",
                    subtitle: kugou.isLoggedIn ? ((kugou.profileName ?? "已登录") + (kugou.isVIP ? " · 会员" : " · 非会员")) : "未登录 · 扫码同步账号资料",
                    icon: "headphones",
                    isLoggedIn: kugou.isLoggedIn
                ) {
                    if kugou.isLoggedIn { signedInTarget = .kugou } else { showKugouLogin = true }
                }
                Divider().padding(.leading, 48)

                accountSourceRow(
                    title: "哔哩哔哩",
                    subtitle: bilibili.isLoggedIn ? (bilibili.profileName ?? "已登录") : "未登录 · 同步账号资料与视频服务",
                    icon: "play.rectangle.fill",
                    isLoggedIn: bilibili.isLoggedIn
                ) {
                    if bilibili.isLoggedIn { signedInTarget = .bilibili } else { showBilibiliLogin = true }
                }

                Text("账号登录只用于同步资料、歌单和播放记录；播放继续使用账号能力或已导入的 LX 音源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private func accountMark(title: String, icon: String, isLoggedIn: Bool) -> some View {
        let brand: String? = {
            if title.contains("网易") { return "BrandNetease" }
            if title.contains("QQ") { return "BrandQQ" }
            if title.contains("酷狗") { return "BrandKugou" }
            if title.contains("哔哩") { return "BrandBilibili" }
            return nil
        }()
        if let brand {
            BrandIconView(name: brand).frame(width: 30, height: 30)
        } else {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isLoggedIn ? .green : Theme.accent)
                .frame(width: 30)
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
            accountMark(title: title, icon: icon, isLoggedIn: isLoggedIn)
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
                .foregroundStyle(isLoggedIn ? .green : .secondary)
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
                profileRow("收藏的歌单与专辑", icon: "bookmark.fill", tint: .yellow, destination: .collections)
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
                Label("外观", systemImage: "circle.lefthalf.filled")
                    .font(.headline.weight(.semibold))
                Picker("外观", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                Text("外观设置会同步应用、播放器和设置页面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var supportCard: some View {
        MouGlassCard {
            VStack(alignment: .leading, spacing: 11) {
                Label("支持项目", systemImage: "heart.circle.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                NavigationLink {
                    AfdianSupportView()
                } label: {
                    rowLabel("赞赏支持项目", icon: "heart.fill", tint: Theme.accent)
                }
                .buttonStyle(.plain)
                Text("感谢每一位支持 Moumusic 的朋友。")
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

private struct MoumusicProfileEditorView: View {
    @EnvironmentObject private var server: MoumusicServerStore
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var backgroundURL = ""
    @State private var signature = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("个人资料") {
                    TextField("昵称", text: $nickname)
                    TextField("个性签名", text: $signature, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("个人卡片背景") {
                    TextField("图片 URL", text: $backgroundURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    if let url = URL(string: backgroundURL), !backgroundURL.isEmpty {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Color.secondary.opacity(0.12)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    Text("保存后会用于 Moumusic 个人 ID 卡片。建议使用稳定的 HTTPS 图片地址。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("编辑个人卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isSaving = true
                        Task {
                            await server.updateProfile(
                                nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                                signature: signature.trimmingCharacters(in: .whitespacesAndNewlines),
                                backgroundURL: backgroundURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? nil
                                    : backgroundURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView()
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .task {
                guard let profile = server.profile else { return }
                nickname = profile.nickname
                signature = profile.signature ?? ""
                backgroundURL = profile.backgroundURL ?? ""
            }
        }
    }
}
#endif
