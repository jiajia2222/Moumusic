import SwiftUI
#if os(iOS)
import PhotosUI
#endif

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
#if os(iOS)
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @StateObject private var lxStore = LXSourceStore.shared
    @StateObject private var qqMusic = QQMusicSessionStore.shared
    @StateObject private var kugou = KugouSessionStore.shared
    @StateObject private var bilibili = BilibiliSessionStore.shared
    @StateObject private var updateLog = IOSUpdateLogStore.shared
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared
#endif
    @State private var cacheSize = "计算中…"
    private let afdianURL = URL(string: "https://afdian.com/a/moumou2026")!
#if os(iOS)
    @State private var showSourceManager = false
    @State private var showDownloads = false
    @State private var showQQMusicLogin = false
    @State private var showKugouLogin = false
    @State private var showBilibiliLogin = false
#endif
    // Keep the main controls visible on first launch. Every section remains
    // collapsible, but opening the settings page with every group closed makes
    // the app look empty and hides the controls users came here to change.
    @State private var expandedSections: Set<String> = [
        "audio", "accounts", "playback", "home", "sources",
        "appearance", "player", "background", "lyrics"
    ]

    var body: some View {
        Form {
            SettingsDisclosureSection("音源与音质", isExpanded: sectionBinding("audio")) {
                Picker("播放来源", selection: $settings.playbackSourceMode) {
                    ForEach(PlaybackSourceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
#if os(iOS)
                .pickerStyle(.segmented)
#endif
                Text(settings.playbackSourceMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label("重要：网易云 VIP 歌曲在自动模式下优先使用三方音源；官方接口如果只返回试听片段，会被拒绝播放，避免歌曲播放 30 秒后停止。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

#if os(iOS)
                HStack(spacing: 8) {
                    Image(systemName: account.isLoggedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.xmark")
                        .foregroundStyle(account.isLoggedIn ? .green : .secondary)
                    Text(account.isLoggedIn
                         ? "网易云账号已登录；对应歌曲可使用官方账号音源"
                         : "未登录网易云账号，对应歌曲将使用 LX 音源")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
#endif

                Picker("默认播放音质", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text("\(quality.displayName) · \(quality.sourceDisplayName)")
                            .tag(quality)
                    }
                }
                Text("自动模式先尝试已启用的 LX 音源；失败后才使用对应平台已登录账号的官方音源。最终显示以实际返回的音质为准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

#if os(iOS)
            SettingsDisclosureSection("账号与同步", isExpanded: sectionBinding("accounts")) {
                NavigationLink(value: Destination.accountSync) {
                    Label("账号同步", systemImage: "person.crop.circle.badge.checkmark")
                }
                Text("网易云、QQ 音乐和酷狗登录后，可在对应平台歌曲上使用官方账号音源；自动模式仍优先使用已启用的 LX 音源。哔哩哔哩当前用于账号同步和视频内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { showQQMusicLogin = true } label: {
                    HStack {
                        Label("QQ 音乐账号播放与同步", systemImage: qqMusic.isLoggedIn
                              ? "checkmark.circle.fill" : "person.crop.circle.badge.plus")
                        Spacer()
                        Text(qqMusic.isLoggedIn ? (qqMusic.profileName ?? "已登录") : "未登录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: 44)

                if qqMusic.isLoggedIn {
                    Button(role: .destructive) { qqMusic.signOut() } label: {
                        Label("退出 QQ 音乐登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .frame(minHeight: 44)
                }

                Button { showKugouLogin = true } label: {
                    HStack {
                        Label("酷狗音乐账号播放与同步", systemImage: kugou.isLoggedIn
                              ? "checkmark.circle.fill" : "person.crop.circle.badge.plus")
                        Spacer()
                        Text(kugou.isLoggedIn ? (kugou.profileName ?? "已登录") : "未登录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: 44)

                if kugou.isLoggedIn {
                    Button(role: .destructive) { kugou.signOut() } label: {
                        Label("退出酷狗音乐登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .frame(minHeight: 44)
                }

                Button { showBilibiliLogin = true } label: {
                    HStack {
                        Label("哔哩哔哩账号同步（仅资料）", systemImage: bilibili.isLoggedIn
                              ? "checkmark.circle.fill" : "person.crop.circle.badge.plus")
                        Spacer()
                        Text(bilibili.isLoggedIn ? (bilibili.profileName ?? "已登录") : "扫码登录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: 44)

                if bilibili.isLoggedIn {
                    Button(role: .destructive) { bilibili.signOut() } label: {
                        Label("退出哔哩哔哩登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .frame(minHeight: 44)
                }

                Text("网易云、QQ 音乐和酷狗支持对应平台歌曲的官方账号音源；哔哩哔哩用于账号资料、视频推荐和同步。汽水音乐已移除登录和播放，仅保留公开歌单导入；凭据仅保存在本机钥匙串。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
#endif

            SettingsDisclosureSection("播放设置", isExpanded: sectionBinding("playback")) {
#if os(iOS)
                Toggle("播放失败时切换平台", isOn: $settings.enableSourcePlatformFallback)
                Text(settings.enableSourcePlatformFallback
                     ? "当前平台无法播放时，允许音源尝试其他平台的同名歌曲。"
                     : "单平台模式：只使用歌曲标记的平台，不跨平台匹配。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
#endif
                Text("音频通过已导入的 LX 音源解析；歌词和封面按歌曲平台获取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("音质在歌曲播放页调整；可用档位由当前 LX 音源声明。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsDisclosureSection("首页推荐", isExpanded: sectionBinding("home")) {
                Picker("推荐内容", selection: $settings.homeRecommendationMode) {
                    ForEach(HomeRecommendationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("推荐平台", selection: $settings.homeRecommendationPlatform) {
                    ForEach(LXCatalogPlatform.catalogueCases.filter { $0 != .aggregate }) { platform in
                        Text(platform.displayName).tag(platform)
                    }
                }
                Text("聚合搜索只属于搜索页；首页始终使用你选定的一个推荐平台，并在每次刷新时重新读取内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

#if os(iOS)
            SettingsDisclosureSection("LX 音源", isExpanded: sectionBinding("sources")) {
                sourceManagerRow
                Text("音源管理是独立页面：可导入文件或在线链接、切换当前音源，并测试 musicUrl 接口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
#endif

            SettingsDisclosureSection("主题模式", isExpanded: sectionBinding("appearance")) {
                AppearancePicker(selection: $settings.appearance)
            }

#if os(iOS)
            SettingsDisclosureSection("播放器模式", isExpanded: sectionBinding("player")) {
                Picker("播放器模式", selection: $settings.nowPlayingMode) {
                    ForEach(NowPlayingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("选择播放页的布局风格；沉浸、经典、简洁、歌词和唱片模式互不覆盖。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsDisclosureSection("动态壁纸与背景", isExpanded: sectionBinding("background")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Label("背景图片", systemImage: "photo.on.rectangle.angled")
                        Spacer()
                        if backgroundStore.image != nil {
                            Text("已设置")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let image = backgroundStore.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 92)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(.white.opacity(0.18), lineWidth: 1)
                            }
                            .accessibilityHidden(true)
                    }

                    HStack(spacing: 12) {
                        PhotosPicker(selection: $backgroundStore.photoSelection,
                                     matching: .images,
                                     photoLibrary: .shared()) {
                            Label("选择图片", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .disabled(backgroundStore.isImporting)

                        if backgroundStore.image != nil {
                            Button(role: .destructive) {
                                backgroundStore.clear()
                            } label: {
                                Label("移除", systemImage: "trash")
                            }
                            .frame(minHeight: 44)
                        }
                    }

                    Toggle("同步到播放页", isOn: $backgroundStore.syncToPlayer)
                    Toggle("同步到应用页面", isOn: $backgroundStore.syncToApp)
                    backgroundBlurControl
                    Text("图片会缩放并压缩保存到本机；开启应用同步时，首页和其他页面也会使用这张图。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
#endif

            SettingsDisclosureSection("歌词显示", isExpanded: sectionBinding("lyrics")) {
                Picker("歌词样式", selection: $settings.lyricsDisplayStyle) {
                    ForEach(LyricsDisplayStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Text(settings.lyricsDisplayStyle.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("显示歌词翻译", isOn: $settings.showLyricsTranslation)
                Toggle("逐字歌词（卡拉 OK）", isOn: $settings.verbatimLyrics)
                Picker("日文歌词注音", selection: $settings.lyricsAnnotation) {
                    ForEach(LyricsAnnotation.allCases) { annotation in
                        Text(annotation.displayName).tag(annotation)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("歌词同步")
                        Spacer()
                        Text(String(format: "%+.2f 秒", settings.lyricsOffset))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.lyricsOffset, in: -2...2, step: 0.05)
#if os(iOS)
                        .onChange(of: settings.lyricsOffset) { _ in
                            player.refreshLyricsCursor()
                        }
#endif
                    Text("正值让歌词提前，负值让歌词延后；不同音源版本可分别试听调整。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
#if os(macOS)
                Toggle("桌面歌词", isOn: $settings.showDesktopLyrics)
                Toggle("桌面歌词水平居中", isOn: $settings.desktopLyricsCentered)
                    Text("开启后仅保留垂直位置，桌面歌词始终位于屏幕水平中心。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
#endif
            }

            SettingsDisclosureSection("存储与下载", isExpanded: sectionBinding("storage")) {
                LabeledContent("图片缓存", value: cacheSize)
                Button("清除缓存") { clearCache() }
#if os(iOS)
                Button {
                    showDownloads = true
                } label: {
                    Label("下载管理", systemImage: "arrow.down.circle")
                }
#endif
            }

            SettingsDisclosureSection("更新", isExpanded: sectionBinding("updates")) {
                Toggle("启动时自动检查更新", isOn: $settings.autoCheckUpdates)
#if os(iOS)
                Button {
                    IOSUpdater.shared.check(interactive: true)
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    updateLog.present()
                } label: {
                    Label("查看更新日志", systemImage: "doc.text.magnifyingglass")
                }
#endif
            }

            SettingsDisclosureSection("关于", isExpanded: sectionBinding("about")) {
                LabeledContent("Moumusic", value: appVersion)
                Text("播放、歌词和封面支持用户导入的 LX User API 音源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsDisclosureSection("赞赏与支持", isExpanded: sectionBinding("support")) {
#if os(iOS)
                supportLink
#else
                Link(destination: afdianURL) {
                    HStack(spacing: 12) {
                        CachedAsyncImage(
                            url: URL(string: "https://afdian.com/favicon.ico"),
                            animated: false
                        ) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(Color.orange.opacity(0.16))
                                Image(systemName: "heart.fill")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("在爱发电支持 Moumusic")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("每一份支持都会帮助我继续维护项目")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("在爱发电支持 Moumusic")
                .accessibilityHint("打开爱发电支持页面")
#endif
            }
        }
        .formStyle(.grouped)
#if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Material.thin)
        )
        .tint(Theme.accent)
#endif
#if os(macOS)
        .frame(width: 440, height: 520)
#endif
        .task { updateCacheSize() }
#if os(iOS)
        .sheet(isPresented: $showSourceManager) {
            NavigationStack {
                LXSourceManagerView()
            }
        }
        .sheet(isPresented: $showDownloads) {
            DownloadsView()
                .environmentObject(player)
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
        .onChange(of: backgroundStore.photoSelection) { _ in
            Task { await backgroundStore.importSelection() }
        }
#endif
    }

    private var appVersion: String {
        ReleaseChecker.currentDisplayVersion
    }

#if os(iOS)
    private var supportLink: some View {
        NavigationLink {
            AfdianSupportView()
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.orange.opacity(0.16))
                    .overlay {
                        Image(systemName: "heart.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("赞助者名单与支持")
                        .font(.headline.weight(.semibold))
                    Text("查看真实支持者、金额并在应用内支持")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sourceManagerRow: some View {
        Button {
            showSourceManager = true
        } label: {
            HStack {
                Label("管理 / 导入 LX 音源", systemImage: "waveform.badge.plus")
                Spacer()
                Text(lxStore.selectedSource?.name ?? "未启用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 44)
    }

    private var backgroundBlurControl: some View {
        HStack {
            Text("背景模糊")
            Slider(value: $backgroundStore.blurRadius, in: 0...24, step: 1)
            Text(Int(backgroundStore.blurRadius), format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
#endif

    private func sectionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(id) },
            set: { expanded in
                if expanded {
                    expandedSections.insert(id)
                } else {
                    expandedSections.remove(id)
                }
            }
        )
    }

    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("im.missuo.Kumone/images", isDirectory: true)
    }

    private func updateCacheSize() {
        let directory = cacheDirectory
        DispatchQueue.global(qos: .utility).async {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            let bytes = files.reduce(0) {
                $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            DispatchQueue.main.async { cacheSize = formatted }
        }
    }

    private func clearCache() {
        let directory = cacheDirectory
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                cacheSize = "0 字节"
                ToastCenter.shared.show("缓存已清除")
            }
        }
    }
}

private struct SettingsDisclosureSection<Content: View>: View {
    private let title: String
    @Binding private var isExpanded: Bool
    private let content: () -> Content

    init(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                content()
            } label: {
                Text(title)
                    .font(.headline.weight(.semibold))
            }
        }
    }
}

/// A compact three-way control matching the native settings pattern in the
/// reference UI. The binding applies the same transition whether the user
/// taps a segment or changes the value from an accessibility action.
private struct AppearancePicker: View {
    @Binding var selection: AppAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Picker("主题", selection: appearanceBinding) {
            ForEach(AppAppearance.allCases) { appearance in
                Text(appearance.displayName)
                    .tag(appearance)
            }
        }
        .pickerStyle(.segmented)
        .tint(Theme.accent)
        .animation(reduceMotion ? nil : AppAnimation.smooth, value: selection)
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { selection },
            set: { newValue in
                guard newValue != selection else { return }
                if reduceMotion {
                    selection = newValue
                } else {
                    withAnimation(AppAnimation.smooth) {
                        selection = newValue
                    }
                }
            }
        )
    }
}
