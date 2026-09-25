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
    @State private var showEqualizer = false
    @ObservedObject private var equalizer = MoumusicEqualizer.shared
#if os(iOS)
    @State private var showSourceManager = false
    @State private var showDownloads = false
    @State private var showQQMusicLogin = false
    @State private var showKugouLogin = false
    @State private var showBilibiliLogin = false
    @State private var showPlayerLayoutEditor = false
#endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            settingsGroup("音源与音质") {
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

                Label("重要：自动模式先请求已登录账号能提供的完整音频；如果官方接口只返回试听片段或目标音质不可用，再回退到已启用的三方音源，避免歌曲播放 30 秒后停止。", systemImage: "exclamationmark.triangle.fill")
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
                Text("自动模式先尝试对应平台已登录账号的官方音源；账号不可用时再按顺序回退到 LX。最终显示以接口实际返回的音质为准，不会把请求档位当成真实音质。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

#if os(iOS)
            settingsGroup("账号与同步") {
                NavigationLink(value: Destination.accountSync) {
                    Label("账号同步", systemImage: "person.crop.circle.badge.checkmark")
                }
                Text("网易云、QQ 音乐和酷狗登录后，可在对应平台歌曲上使用官方账号音源；自动模式优先尝试账号音源，失败后才按顺序回退到已启用的 LX 音源。哔哩哔哩当前用于账号同步和视频内容。")
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

                if bilibili.isLoggedIn {
                    HStack {
                        Label("哔哩哔哩账号已同步", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Text(bilibili.profileName ?? "已登录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minHeight: 44)
                } else {
                    Button { showBilibiliLogin = true } label: {
                        HStack {
                            Label("哔哩哔哩账号同步", systemImage: "person.crop.circle.badge.plus")
                            Spacer()
                            Text("扫码或网页登录")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(minHeight: 44)
                }

                if bilibili.isLoggedIn {
                    Button(role: .destructive) { bilibili.signOut() } label: {
                        Label("退出哔哩哔哩登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .frame(minHeight: 44)
                }

                Text("网易云、QQ 音乐和酷狗支持对应平台歌曲的官方账号音源；哔哩哔哩登录仅用于资料同步和视频服务。登录成功后会保留本机钥匙串会话，不会重复要求登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
#endif

            settingsGroup("播放设置") {
#if os(iOS)
                Toggle("播放失败时切换平台", isOn: $settings.enableSourcePlatformFallback)
                Text(settings.enableSourcePlatformFallback
                     ? "当前平台无法播放时，允许音源尝试其他平台的同名歌曲。"
                     : "单平台模式：只使用歌曲标记的平台，不跨平台匹配。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
#endif
                Button {
                    showEqualizer = true
                } label: {
                    HStack {
                        Label("均衡器", systemImage: "waveform.path.ecg")
                        Spacer()
                        Text(equalizer.isEnabled ? "已开启" : "已关闭")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44)
                Text("音频会按播放来源设置选择账号音源或已导入的 LX 音源；歌词、封面和评论仍按歌曲平台获取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("音质在歌曲播放页调整；可用档位由账号接口或当前 LX 音源实际返回的数据共同决定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingsGroup("哔哩哔哩") {
                Toggle("看哔哩哔哩", isOn: $settings.bilibiliVideoEnabled)
                Toggle("听哔哩哔哩", isOn: $settings.bilibiliAudioEnabled)
                Text("“看”控制视频入口；“听”控制视频页的仅听音频和字幕。首页推荐配置只在首页本身调整。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

#if os(iOS)
            settingsGroup("LX 音源") {
                sourceManagerRow
                Text("音源管理是独立页面：可导入文件或在线链接、切换当前音源，并测试 musicUrl 接口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
#endif

            settingsGroup("主题模式") {
                AppearancePicker(selection: $settings.appearance)
            }

#if os(iOS)
            settingsGroup("播放器模式") {
                Picker("播放器模式", selection: $settings.nowPlayingMode) {
                    ForEach(NowPlayingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("选择播放页的布局风格；沉浸、经典、简洁、歌词和唱片模式互不覆盖。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    showPlayerLayoutEditor = true
                } label: {
                    Label("自定义当前播放器布局", systemImage: "slider.horizontal.3")
                }
                .frame(minHeight: 44)
                Text("来自 Beans 的组件布局机制：封面、歌曲信息、歌词、进度、音量和播放控制可分别调整，并按播放器模式单独保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingsGroup("动态壁纸与背景") {
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

            settingsGroup("歌词显示") {
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

            settingsGroup("存储与下载") {
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

            settingsGroup("更新") {
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

            settingsGroup("关于") {
                LabeledContent("Moumusic", value: appVersion)
                Text("播放、歌词和封面支持用户导入的 LX User API 音源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingsGroup("赞赏与支持") {
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
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Color.clear)
#if os(iOS)
        .tint(Theme.accent)
#endif
#if os(macOS)
        .frame(width: 440, height: 520)
#endif
        .task {
            updateCacheSize()
#if os(iOS)
            // A stale Keychain cookie must not make the login row look
            // permanently authenticated and prevent the user from scanning a
            // fresh QR code.
            await bilibili.refreshProfile()
#endif
        }
        .sheet(isPresented: $showEqualizer) {
            EqualizerView()
        }
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
        .sheet(isPresented: $showPlayerLayoutEditor) {
            PlayerLayoutEditorView()
                .environmentObject(settings)
        }
        .onChange(of: backgroundStore.photoSelection) { _ in
            Task { await backgroundStore.importSelection() }
        }
#endif
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline.weight(.semibold))
                .padding(.horizontal, 5)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .compatGlass(interactive: true, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
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
