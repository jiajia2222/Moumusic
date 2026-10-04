import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import AVFoundation
import PhotosUI
#endif

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
#if os(iOS)
    @EnvironmentObject private var player: PlayerService
    @StateObject private var lxStore = LXSourceStore.shared
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
    @State private var cacheSummaries: [String: AppCacheManager.Summary] = [:]
    @State private var showEqualizer = false
    @ObservedObject private var equalizer = MoumusicEqualizer.shared
    /// Re-renders the quality list when the selected source's capability check finishes.
    @ObservedObject private var lxSupport = LXUserAPIService.shared
#if os(iOS)
    @State private var showSourceManager = false
    @State private var showDownloads = false
    @State private var showPlayerLayoutEditor = false
    @State private var isImportingBackgroundFile = false
    @State private var waterPhoto: PhotosPickerItem?
    @State private var showFeedback = false
    @State private var showDeveloperTools = false
    @ObservedObject private var deviceReporter = DeviceReporter.shared
    @ObservedObject private var highRefresh = HighRefreshController.shared
    @AppStorage(AppAppearanceKeys.accent) private var accentRaw = AppAccent.red.rawValue
    @AppStorage(AppAppearanceKeys.disableLiquid) private var disableLiquid = false
    @AppStorage(AppAppearanceKeys.floatingEffects) private var floatingEffects = false
    @AppStorage("moumusic.tabBarMinimize") private var tabBarMinimizes = true
    @AppStorage("moumusic.appLanguage") private var appLanguage = "system"
    @AppStorage("moumusic.mixWithOthers") private var mixWithOthers = false
    @AppStorage("moumusic.hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("moumusic.autoPlayLast") private var autoPlayLast = false
    @AppStorage("moumusic.vipReminder") private var vipReminder = true
    @AppStorage("moumusic.qualityDowngradeNotice") private var qualityDowngradeNotice = true
    @AppStorage("moumusic.vipThirdPartyFallback") private var vipThirdPartyFallback = false
    @AppStorage("moumusic.fadeEnabled") private var fadeEnabled = true
    @AppStorage("moumusic.netease.autoSignIn") private var neteaseAutoSignIn = true
    @AppStorage("moumusic.showDeveloperTools") private var showDeveloperToolsEntry = true
#endif
    @StateObject private var backupStore = AppDataBackupManager.shared
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var exportDocument: MoumusicBackupFileDocument?
    /// Accordion state is remembered across launches (comma-joined titles in
    /// UserDefaults; `nil` means the user never changed it, so use the defaults).
    @AppStorage("moumusic.settings.collapsed") private var collapsedStorage: String = "播放器氛围|图片背景|歌词显示|存储与下载|数据备份与恢复|更新|关于|赞赏与支持"
    private var collapsedSettings: Set<String> {
        get { Set(collapsedStorage.split(separator: "|").map(String.init)) }
        nonmutating set { collapsedStorage = newValue.sorted().joined(separator: "|") }
    }

    @State private var settingsQuery = ""
    @State private var settingsPage: SettingsCategory?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
#if os(iOS)
            settingsNavigator
#endif
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

                Picker("默认播放音质", selection: Binding(
                    get: { settings.audioQuality },
                    set: { settings.audioQuality = $0; QualitySupport.rememberChoice($0) }
                )) {
                    // Only tiers the selected source / accounts can actually deliver.
                    ForEach(QualitySupport.audioQualities(for: settings.playbackSourceMode)) { quality in
                        Text("\(quality.displayName) · \(quality.sourceDisplayName)")
                            .tag(quality)
                    }
                }
                .onAppear {
                    LXUserAPIService.shared.recomputeCombinedSupport()
                    if !LXUserAPIService.shared.sourceSupportKnown { LXUserAPIService.shared.refreshAllSourceSupport() }
                    QualitySupport.normalizeSelection()
                }
                .onChange(of: settings.playbackSourceMode) { _ in QualitySupport.normalizeSelection() }
                .onChange(of: lxSupport.sourceTierSupport) { _ in QualitySupport.normalizeSelection() }
                Text("上面只列出已启用的音源（或已登录账号）声明支持的音质，各音源声明的内容可在诊断日志「音源能力」里查看。自动模式先尝试对应平台已登录账号的官方音源；账号不可用时再按顺序回退到 LX。最终显示以接口实际返回的音质为准，不会把请求档位当成真实音质。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingsGroup("播放设置") {
#if os(iOS)
                Toggle("播放失败时切换平台", isOn: $settings.enableSourcePlatformFallback)
                Text(settings.enableSourcePlatformFallback
                     ? "当前平台无法播放时，允许音源尝试其他平台的同名歌曲。"
                     : "单平台模式：只使用歌曲标记的平台，不跨平台匹配。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("与其他音频同时播放", isOn: $mixWithOthers)
                    .onChange(of: mixWithOthers) { value in
                        let options: AVAudioSession.CategoryOptions = value ? [.mixWithOthers] : []
                        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: options)
                    }
                Toggle("播放暂停淡入淡出", isOn: $fadeEnabled)
                Toggle("网易云每日自动签到", isOn: $neteaseAutoSignIn)
                Toggle("触感反馈", isOn: $hapticsEnabled)
                Toggle("启动时自动播放上次歌曲", isOn: $autoPlayLast)
                Toggle("第三方音源播放会员歌时提醒", isOn: $vipReminder)
                Toggle("音质降级时提示", isOn: $qualityDowngradeNotice)
                Text("所选音质（如母带、环绕声）这首歌没有、改按较低音质播放时，是否弹出提示。关闭后只在诊断日志里记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("账号模式下用第三方音源播放会员歌曲", isOn: $vipThirdPartyFallback)
                Text("仅在播放来源为「账号音源（官方）」、账号不是会员、而歌曲需要会员时生效；会员账号始终使用账号音源播放会员歌曲。")
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
                Toggle("启用动态壁纸", isOn: Binding(
                    get: { dynamicWallpaper.isEnabled },
                    set: { enabled in
                        dynamicWallpaper.isEnabled = enabled
                        if enabled {
                            dynamicWallpaper.syncToApp = true
                        }
                    }
                ))
                Picker("动态样式", selection: $dynamicWallpaper.kind) {
                    ForEach(DynamicWallpaperKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                Text(dynamicWallpaper.kind.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if dynamicWallpaper.kind == .dots {
                    Picker("点阵样式", selection: $dynamicWallpaper.dotsStyleRaw) {
                        Text("波浪").tag("wavy")
                        Text("山脉").tag("mountains")
                        Text("海洋").tag("ocean")
                        Text("站立波").tag("standing")
                        Text("流动").tag("flow")
                        Text("等离子").tag("plasma")
                        Text("蛇形").tag("snake")
                    }
                    .pickerStyle(.menu)
                }
                if dynamicWallpaper.kind == .water {
                    PhotosPicker(selection: $waterPhoto, matching: .images) {
                        Label("上传一张图片作为水面内容", systemImage: "photo")
                    }
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

                    VStack(alignment: .leading, spacing: 10) {
                        PhotosPicker(selection: $backgroundStore.photoSelection,
                                     matching: .images,
                                     photoLibrary: .shared()) {
                            Label("选择图片", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(backgroundStore.isImporting)

                        Button {
                            isImportingBackgroundFile = true
                        } label: {
                            Label("从文件选择", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(backgroundStore.isImporting)

                        if backgroundStore.image != nil {
                            Button(role: .destructive) {
                                backgroundStore.clear()
                            } label: {
                                Label("移除", systemImage: "trash")
                            }
                            .frame(minHeight: 44)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

                Picker("歌词样式", selection: $settings.lyricsDisplayStyle) {
                    ForEach(LyricsDisplayStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Toggle("显示逐字歌词", isOn: $settings.verbatimLyrics)
                Toggle("显示歌词翻译", isOn: $settings.showLyricsTranslation)
                Picker("日文歌词注音", selection: $settings.lyricsAnnotation) {
                    ForEach(LyricsAnnotation.allCases) { annotation in
                        Text(annotation.displayName).tag(annotation)
                    }
                }
                HStack {
                    Text("歌词同步")
                    Spacer()
                    Text(String(format: "%+.2f 秒", settings.lyricsOffset))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.lyricsOffset, in: -2...2, step: 0.05)
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
                ForEach(AppCacheManager.CacheCategory.allCases) { category in
                    Button {
                        clearCache(category)
                    } label: {
                        HStack(spacing: 10) {
                            Label(category.displayName, systemImage: category.symbolName)
                            Spacer(minLength: 8)
                            if let summary = cacheSummaries[category.rawValue] {
                                Text("\(summary.fileCount) · \(ByteCountFormatter.string(fromByteCount: summary.byteCount, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                    .disabled(isClearingCache)
                    .frame(minHeight: 44)
                }
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

#if os(iOS)
            settingsGroup("界面与颜色") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("强调色").font(.subheadline.weight(.semibold))
                    HStack(spacing: 12) {
                        ForEach(AppAccent.allCases) { accent in
                            Button {
                                accentRaw = accent.rawValue
                                settings.objectWillChange.send()
                            } label: {
                                Circle()
                                    .fill(accent.color)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if accentRaw == accent.rawValue {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accent.displayName)
                        }
                    }
                    Text("部分界面需重新打开页面后才会应用新颜色。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("关闭液态模式", isOn: $disableLiquid)
                Text("关闭后卡片和按钮使用普通半透明材质，更省电。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("全局漂浮特效", isOn: $floatingEffects)
                Toggle("滚动时收起底栏", isOn: $tabBarMinimizes)
                Picker("语言", selection: $appLanguage) {
                    Text("跟随系统").tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                .onChange(of: appLanguage) { value in
                    if value == "system" {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([value], forKey: "AppleLanguages")
                    }
                    ToastCenter.shared.show("语言将在重新打开 App 后生效")
                }
            }
            settingsGroup("显示与性能") {
                Toggle("强制 120Hz", isOn: $highRefresh.isForced)
                Text("默认跟随系统；开启后保持最高刷新率，耗电会增加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

#endif

            settingsGroup("关于与支持") {
                LabeledContent("版本", value: appVersion)
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
                    Label("更新日志", systemImage: "doc.text.magnifyingglass")
                }
                NavigationLink {
                    DiagnosticLogView()
                } label: {
                    Label("诊断日志", systemImage: "waveform.path.ecg")
                }
                Button {
                    showFeedback = true
                } label: {
                    Label("提交反馈", systemImage: "bubble.left.and.text.bubble.right")
                }
                if deviceReporter.isDeveloper {
                    Toggle("显示开发者工具", isOn: $showDeveloperToolsEntry)
                    if showDeveloperToolsEntry {
                        Button {
                            showDeveloperTools = true
                        } label: {
                            Label("开发者工具", systemImage: "hammer")
                        }
                    }
                }
                supportLink
#else
                Link(destination: afdianURL) {
                    Label("在爱发电支持 Moumusic", systemImage: "heart")
                }
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
#if os(iOS)
        .fileImporter(
            isPresented: $isImportingBackgroundFile,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let imageData = try Data(contentsOf: url)
                guard backgroundStore.save(data: imageData) else {
                    ToastCenter.shared.show("背景图片导入失败")
                    return
                }
                backgroundStore.syncToApp = true
                backgroundStore.syncToPlayer = true
                ToastCenter.shared.show("背景图片已导入")
            } catch {
                ToastCenter.shared.show("背景图片导入失败")
            }
        }
#endif
        .sheet(isPresented: $showEqualizer) {
            EqualizerView()
        }
#if os(iOS)
        .sheet(isPresented: $showFeedback) {
            FeedbackSheet()
        }
        .sheet(isPresented: $showDeveloperTools) {
            DeveloperToolsView()
        }
        .sheet(isPresented: $showSourceManager) {
            NavigationStack {
                LXSourceManagerView()
            }
        }
        .sheet(isPresented: $showDownloads) {
            DownloadsView()
                .environmentObject(player)
        }
        .sheet(isPresented: $showPlayerLayoutEditor) {
            PlayerLayoutEditorView()
                .environmentObject(settings)
        }
        .onChange(of: waterPhoto) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    dynamicWallpaper.setWaterImage(data)
                    ToastCenter.shared.show("水面壁纸已更新")
                }
                waterPhoto = nil
            }
        }
        .onChange(of: backgroundStore.photoSelection) { _ in
            Task { await backgroundStore.importSelection() }
        }
#endif
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isExpanded = !collapsedSettings.contains(title) || !settingsQuery.isEmpty
        if isSettingsGroupVisible(title) {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        collapsedSettings.insert(title)
                    } else {
                        collapsedSettings.remove(title)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 2)
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Non-interactive: an interactive glass container swallows taps meant
        // for the header button inside it (intermittent missed taps).
        .compatGlass(interactive: false, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
    }

    private var appVersion: String {
        ReleaseChecker.currentDisplayVersion
    }

    /// Beans-style two-level settings: category home -> category page, with
    /// a search box that shows matching groups from every category.
    enum SettingsCategory: String, CaseIterable, Identifiable {
        case appearance = "外观与界面"
        case playback = "播放与音效"
        case accounts = "账号与平台"
        case about = "关于与支持"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .appearance: return "paintbrush"
            case .playback: return "speaker.wave.3"
            case .accounts: return "person.2"
            case .about: return "info.circle"
            }
        }

        var summary: String {
            switch self {
            case .appearance: return "主题、播放器、动态壁纸、歌词显示、刷新率"
            case .playback: return "音源与音质、播放设置、LX 音源"
            case .accounts: return "账号登录、同步、哔哩哔哩"
            case .about: return "缓存与备份、反馈、更新与诊断、关于"
            }
        }

        var groups: [String] {
            switch self {
            case .appearance:
                return ["界面与颜色", "主题模式", "播放器模式", "动态壁纸", "播放器氛围", "图片背景", "歌词显示", "显示与性能"]
            case .playback:
                return ["音源与音质", "播放设置", "LX 音源"]
            case .accounts:
                return ["哔哩哔哩"]
            case .about:
                return ["存储与下载", "数据备份与恢复", "关于与支持"]
            }
        }
    }

    private static let settingsKeywords: [String: String] = [
        "音源与音质": "播放来源 播放音质 第三方音源 网络 wifi 蜂窝 回退 切换平台",
        "账号与同步": "登录 网易云 QQ 酷狗 平台显示 同步",
        "播放设置": "触感 启动自动播放 均衡器 睡眠 定时 与其他音频同时播放",
        "哔哩哔哩": "b站 bilibili 视频 登录",
        "LX 音源": "lx user api 脚本 导入",
        "主题模式": "深色 浅色 外观 颜色",
        "播放器模式": "唱片 布局 封面",
        "动态壁纸": "壁纸 metal 流体 云层",
        "播放器氛围": "氛围 背景 光效",
        "图片背景": "背景 自定义 同步",
        "歌词显示": "逐字 偏移 注音 翻译 同步",
        "存储与下载": "缓存 清理 下载 空间",
        "数据备份与恢复": "备份 导入 导出 恢复",
        "更新": "检查更新 更新日志 诊断 日志 崩溃 卡死",
        "显示与性能": "高刷新率 120hz 帧率 性能",
        "界面与颜色": "强调色 颜色 液态 玻璃 漂浮 特效 底栏 语言",
        "关于与支持": "版本 更新 检查更新 日志 诊断 崩溃 卡死 反馈 工单 开发者工具 赞助 爱发电 支持 捐赠",
        "关于": "版本 免责声明 运行环境",
        "赞赏与支持": "赞助 爱发电 捐赠 支持"
    ]

    private func isSettingsGroupVisible(_ title: String) -> Bool {
#if os(iOS)
        let query = settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            let haystack = (title + " " + (Self.settingsKeywords[title] ?? "")).lowercased()
            return haystack.contains(query)
        }
        return true
#else
        return true
#endif
    }

#if os(iOS)
    @ViewBuilder
    private var settingsNavigator: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索设置", text: $settingsQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !settingsQuery.isEmpty {
                Button {
                    settingsQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .compatGlass(interactive: true, in: Capsule())
    }
#endif
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
            var values: [String: AppCacheManager.Summary] = [:]
            for category in AppCacheManager.CacheCategory.allCases {
                values[category.rawValue] = await AppCacheManager.shared.summary(for: category)
            }
            cacheSummaries = values
        }
    }

    private func clearCache(_ category: AppCacheManager.CacheCategory? = nil) {
        guard !isClearingCache else { return }
        isClearingCache = true
        cacheProgress = 0
        cacheClearMessage = nil
        Task { @MainActor in
            let result: AppCacheManager.ClearResult
            if let category {
                result = await AppCacheManager.shared.clear(category) { value in
                    await MainActor.run {
                        cacheProgress = value
                    }
                }
            } else {
                result = await AppCacheManager.shared.clearAll { value in
                    await MainActor.run {
                        cacheProgress = value
                    }
                }
            }
            updateCacheSize()
            cacheProgress = nil
            isClearingCache = false
            cacheClearMessage = category.map { "已清理 \($0.displayName) · \(result.fileCount) 个文件" }
                ?? "已清理全部缓存 · \(result.fileCount) 个文件"
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
