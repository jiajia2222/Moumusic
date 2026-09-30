import SwiftUI
import UniformTypeIdentifiers
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
    @ObservedObject private var dynamicWallpaper = DynamicWallpaperStore.shared
    @ObservedObject private var playerAmbience = PlayerAmbienceStore.shared
#endif
    @State private var cacheSize = "计算中…"
    private let afdianURL = URL(string: "https://afdian.com/a/moumou2026")!
    @State private var isClearingCache = false
    @State private var cacheProgress: Double?
    @State private var cacheClearMessage: String?
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
    @StateObject private var backupStore = AppDataBackupManager.shared
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var exportDocument: MoumusicBackupFileDocument?

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

                if account.isLoggedIn && !account.hasActiveVIP {
                    Label(
                        "警告：当前网易云账号不是 VIP。网易云官方账号音源不会把全景声、杜比、环绕声或 Hi-Res 当作账号权限；选择这些档位时会自动降级，或按设置切换到第三方音源。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                } else if account.hasAuthCookie && !account.vipStatusKnown {
                    Label(
                        "警告：网易云账号资料还未同步完成，VIP 状态尚未确认。确认前不会按 VIP 请求高级音质。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
                Toggle("拔出耳机自动暂停", isOn: $settings.autoPauseOnRouteChange)
                Text(settings.autoPauseOnRouteChange
                     ? "断开耳机、车载或蓝牙输出时自动暂停当前歌曲。"
                     : "断开输出设备时继续播放，请确认周围环境适合播放。")
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
                NavigationLink {
                    NavigationStack {
                        BilibiliSettingsView()
                            .environmentObject(settings)
                    }
                } label: {
                    Label("打开 B 站独立设置", systemImage: "slider.horizontal.3")
                }
                .frame(minHeight: 44)
                Text("视频、音频和首页推荐客户端已移到独立页面，不再和全局音源设置混在一起。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Toggle("锁屏沉浸封面", isOn: $settings.lockScreenImmersiveArtwork)
                Text("开启后向系统媒体中心提供高分辨率封面；锁屏展开播放器时，iOS 会按系统规则显示类似 Apple Music 的沉浸式封面。关闭后仍保留普通小封面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

            settingsGroup("动态壁纸") {
                Toggle("启用动态壁纸", isOn: $dynamicWallpaper.isEnabled)
                Picker("动态样式", selection: $dynamicWallpaper.kind) {
                    ForEach(DynamicWallpaperKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                HStack {
                    Text("动画速度")
                    Slider(value: $dynamicWallpaper.speed, in: 0.05...1.0)
                    Text(String(format: "%.2fx", dynamicWallpaper.speed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                HStack {
                    Text("显示强度")
                    Slider(value: $dynamicWallpaper.intensity, in: 0.2...1.0)
                    Text(String(format: "%.0f%%", dynamicWallpaper.intensity * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Toggle("同步到应用页面", isOn: $dynamicWallpaper.syncToApp)
                Toggle("同步到沉浸播放页", isOn: $dynamicWallpaper.syncToPlayer)
                Text("动态壁纸会在应用进入后台或开启减少动态效果时自动暂停；启用后优先显示，静态背景仍会保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingsGroup("播放器氛围") {
                Toggle("封面动态氛围", isOn: $playerAmbience.isEnabled)
                Text("来自 Beans 的封面主色光晕；它和全局动态壁纸是两套独立效果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("呼吸光晕")
                    Slider(value: $playerAmbience.breath, in: 0...1)
                    Text(String(format: "%.0f%%", playerAmbience.breath * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                Picker("背景浮尘", selection: $playerAmbience.dustMode) {
                    ForEach(MoumusicPlayerDustMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if playerAmbience.dustMode == .snow {
                    HStack {
                        Text("浮尘密度")
                        Slider(value: $playerAmbience.dustDensity, in: 0.25...2.5)
                        Text(String(format: "%.1fx", playerAmbience.dustDensity))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    HStack {
                        Text("浮尘大小")
                        Slider(value: $playerAmbience.dustSize, in: 0.6...3.2)
                        Text(String(format: "%.1fx", playerAmbience.dustSize))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }

            settingsGroup("图片背景") {
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
                Text("歌词样式、逐字歌词、翻译和同步偏移请在歌曲播放页的“歌词设置”中调整。播放页会优先使用音源提供的真实逐字时间轴，没有时间轴时只做整行高亮。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                if let cacheProgress {
                    ProgressView(value: cacheProgress)
                    Text("正在清理缓存 \(Int(cacheProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let cacheClearMessage {
                    Text(cacheClearMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    showDownloads = true
                } label: {
                    Label("下载管理", systemImage: "arrow.down.circle")
                }
#endif
            }

            settingsGroup("数据备份与恢复") {
                Toggle("自动备份到 iCloud", isOn: $backupStore.automaticICloudBackup)
                Text("只备份本地收藏、歌单和应用设置；账号 Cookie、Token 和密码不会导出或上传。未启用 iCloud 时仍可使用文件备份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button {
                        exportDocument = backupStore.prepareExportDocument()
                        isExportingBackup = exportDocument != nil
                    } label: {
                        Label("导出备份", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        isImportingBackup = true
                    } label: {
                        Label("导入恢复", systemImage: "square.and.arrow.down")
                    }
                }

                Button {
                    _ = backupStore.restoreFromICloud()
                } label: {
                    Label(
                        backupStore.isICloudAvailable ? "立即从 iCloud 恢复" : "iCloud 不可用",
                        systemImage: backupStore.isICloudAvailable ? "icloud.and.arrow.down" : "icloud.slash"
                    )
                }
                .disabled(!backupStore.isICloudAvailable)

                if let lastBackupDate = backupStore.lastBackupDate {
                    LabeledContent("上次 iCloud 备份", value: lastBackupDate.formatted(date: .abbreviated, time: .shortened))
                }
                if !backupStore.statusMessage.isEmpty {
                    Text(backupStore.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
#if os(iOS)
            // The floating player bar is rendered above this scroll view.
            // Keep the last settings group reachable instead of letting the
            // bar cover it on the smaller iPhone layouts.
            PlayerClearanceSpacer()
#endif
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
            backupStore.startAutomaticBackup()
#if os(iOS)
            // A stale Keychain cookie must not make the login row look
            // permanently authenticated and prevent the user from scanning a
            // fresh QR code.
            await bilibili.refreshProfile()
#endif
        }
        .fileExporter(
            isPresented: $isExportingBackup,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Moumusic-Backup"
        ) { result in
            if case .failure(let error) = result {
                backupStore.setStatusMessage("备份导出失败：\(error.localizedDescription)")
            }
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result {
                    backupStore.setStatusMessage("备份导入失败：\(error.localizedDescription)")
                }
                return
            }

            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            do {
                try backupStore.importBackup(data: Data(contentsOf: url))
            } catch {
                backupStore.setStatusMessage("备份导入失败：\(error.localizedDescription)")
            }
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
        Task { @MainActor in
            let summary = await AppCacheManager.shared.summary()
            cacheSize = ByteCountFormatter.string(fromByteCount: summary.byteCount, countStyle: .file)
        }
    }

    private func clearCache() {
        guard !isClearingCache else { return }
        isClearingCache = true
        cacheProgress = 0
        cacheClearMessage = nil
        Task { @MainActor in
            let result = await AppCacheManager.shared.clearAll { value in
                await MainActor.run {
                    cacheProgress = value
                }
            }
            cacheSize = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
            cacheProgress = nil
            isClearingCache = false
            cacheClearMessage = "已清理 \(result.fileCount) 个缓存文件"
            ToastCenter.shared.show("缓存已清除")
        }
    }

    private func updateCacheSizeLegacy() {
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

    private func clearCacheLegacy() {
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
