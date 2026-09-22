import SwiftUI
#if os(iOS)
import PhotosUI
#endif

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
#if os(iOS)
    @EnvironmentObject private var player: PlayerService
    @StateObject private var lxStore = LXSourceStore.shared
    @StateObject private var qishui = QishuiSessionStore.shared
    @StateObject private var qqMusic = QQMusicSessionStore.shared
    @StateObject private var kugou = KugouSessionStore.shared
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared
#endif
    @State private var cacheSize = "计算中…"
    private let afdianURL = URL(string: "https://afdian.com/a/moumou2026")!
#if os(iOS)
    @State private var showSourceManager = false
    @State private var showDownloads = false
    @State private var showQishuiLogin = false
    @State private var showQQMusicLogin = false
    @State private var showKugouLogin = false
#endif

    var body: some View {
        Form {
            Section("默认播放音质") {
                Picker("默认播放音质", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text("\(quality.displayName) · \(quality.sourceDisplayName)")
                            .tag(quality)
                    }
                }
                Text("播放时优先请求此档位；当前歌曲或音源不支持时，自动按实际能力向下回退，并在播放页显示真实音质。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

#if os(iOS)
            Section("账号与同步") {
                NavigationLink(value: Destination.accountSync) {
                    Label("账号同步", systemImage: "person.crop.circle.badge.checkmark")
                }
                Text("登录只同步账号资料、每日推荐、播放记录和听歌时长，不会作为音源；歌曲仍由已导入的 LX 音源播放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("汽水音乐推荐") {
                Button {
                    showQishuiLogin = true
                } label: {
                    HStack {
                        Label("汽水音乐登录", systemImage: qishui.isLoggedIn
                              ? "checkmark.circle.fill" : "person.crop.circle.badge.plus")
                        Spacer()
                        Text(qishui.isLoggedIn ? (qishui.profileName ?? "已登录") : "未登录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: 44)

                if qishui.isLoggedIn {
                    Button(role: .destructive) {
                        qishui.signOut()
                    } label: {
                        Label("退出汽水登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .frame(minHeight: 44)
                }

                Text("登录只用于获取汽水首页推荐；Cookie 保存在本机钥匙串，播放仍通过你导入的 LX 音源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("平台账号同步") {
                Button { showQQMusicLogin = true } label: {
                    HStack {
                        Label("QQ 音乐登录", systemImage: qqMusic.isLoggedIn
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
                        Label("酷狗音乐登录", systemImage: kugou.isLoggedIn
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

                Text("QQ、酷狗、汽水登录只同步资料、推荐和歌单，不作为音源。Cookie 仅保存在本机钥匙串，应用每 12 小时静默校验一次。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
#endif

            Section("播放") {
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

#if os(iOS)
            Section("LX 音源") {
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
                Text("音源管理是独立页面：可导入文件或在线链接、切换当前音源，并测试 musicUrl 接口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
#endif

            Section("外观") {
                AppearancePicker(selection: $settings.appearance)
#if os(iOS)
                Picker("播放器模式", selection: $settings.nowPlayingMode) {
                    ForEach(NowPlayingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
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
                    HStack {
                        Text("背景模糊")
                        Slider(value: $backgroundStore.blurRadius, in: 0...24, step: 1)
                        Text("\(Int(backgroundStore.blurRadius))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                    Text("图片会缩放并压缩保存到本机；开启应用同步时，首页和其他页面也会使用这张图。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
#endif
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

            Section("存储") {
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

            Section("更新") {
                Toggle("启动时自动检查更新", isOn: $settings.autoCheckUpdates)
#if os(iOS)
                Button {
                    IOSUpdater.shared.check(interactive: true)
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
#endif
            }

            Section("关于") {
                LabeledContent("Moumusic", value: appVersion)
                Text("播放、歌词和封面支持用户导入的 LX User API 音源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("赞赏与支持") {
#if os(iOS)
                NavigationLink {
                    AfdianSupportView()
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.orange.opacity(0.16))
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
        .sheet(isPresented: $showQishuiLogin) {
            QishuiLoginSheet()
                .environmentObject(qishui)
        }
        .sheet(isPresented: $showQQMusicLogin) {
            QQMusicLoginSheet()
                .environmentObject(qqMusic)
        }
        .sheet(isPresented: $showKugouLogin) {
            KugouLoginSheet()
                .environmentObject(kugou)
        }
        .onChange(of: backgroundStore.photoSelection) { _ in
            Task { await backgroundStore.importSelection() }
        }
#endif
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
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
