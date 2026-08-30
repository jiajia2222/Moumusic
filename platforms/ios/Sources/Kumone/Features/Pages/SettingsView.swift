import SwiftUI
#if os(iOS)
import UniformTypeIdentifiers
#endif

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var account: AccountStore
    @State private var cacheSize = "计算中…"
#if os(iOS)
    @StateObject private var lxStore = LXSourceStore.shared
    @State private var isImportingLX = false
    @State private var isShowingOnlineLX = false
    @State private var onlineSourceURL = ""
    @State private var isLoadingOnline = false
    @State private var lxError: String?
#endif

    var body: some View {
        Form {
            Section("播放") {
                Picker("音质", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Text("音质在这里统一设置。实际可用等级由当前播放音源返回的音质列表决定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("灰色歌曲解锁", isOn: $settings.enableUnblock)
                Text("仅在歌曲无法由当前音源解析时尝试第三方解锁。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

#if os(iOS)
            Section("首页推荐") {
                Picker("首页内容", selection: $settings.homeRecommendationMode) {
                    ForEach(HomeRecommendationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if settings.homeRecommendationMode == .lx {
                    Picker("LX 推荐平台", selection: $settings.homeRecommendationPlatform) {
                        ForEach(LXCatalogPlatform.allCases.filter { $0 != .aggregate }) { platform in
                            Text(platform.displayName).tag(platform)
                        }
                    }
                    Text("LX 推荐只使用一个平台。聚合搜索和热门推荐只在搜索页使用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("首页显示网易云推荐内容；搜索页仍可单独选择 LX 平台或聚合搜索。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if lxStore.sources.isEmpty {
                    Text("还没有播放音源。请导入 LX User API 文件，或粘贴在线音源链接。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("当前播放音源", selection: Binding(
                        get: { lxStore.selectedID ?? "" },
                        set: { lxStore.select($0.isEmpty ? nil : $0) }
                    )) {
                        Text("不使用 LX 音源").tag("")
                        ForEach(lxStore.sources) { source in
                            Text(source.name).tag(source.id)
                        }
                    }

                    ForEach(lxStore.sources) { source in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.name)
                                    .font(.body.weight(.medium))
                                let detail = [source.author, source.version]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " · ")
                                if !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !source.description.isEmpty {
                                    Text(source.description)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                                if let sourceURL = source.sourceURL,
                                   let url = URL(string: sourceURL) {
                                    Link(destination: url) {
                                        Label("查看在线链接", systemImage: "link")
                                            .font(.caption)
                                    }
                                } else if let homepage = URL(string: source.homepage), !source.homepage.isEmpty {
                                    Link(destination: homepage) {
                                        Label("查看主页", systemImage: "link")
                                            .font(.caption)
                                    }
                                }
                            }
                            Spacer(minLength: 8)
                            Button("删除", role: .destructive) {
                                lxStore.remove(source)
                            }
                            .font(.caption)
                            .frame(minHeight: 44)
                        }
                    }
                }

                HStack {
                    Button {
                        isImportingLX = true
                    } label: {
                        Label("导入文件", systemImage: "doc.badge.plus")
                    }
                    .frame(minHeight: 44)

                    Button {
                        onlineSourceURL = ""
                        isShowingOnlineLX = true
                    } label: {
                        Label("在线链接", systemImage: "link.badge.plus")
                    }
                    .frame(minHeight: 44)
                }
            } header: {
                Text("LX 播放音源")
            } footer: {
                Text("这里只管理用户添加的 LX User API 脚本和在线链接，不设置音质、不设置首页推荐。导入后请选择一个当前播放音源。")
            }
#endif

            Section("外观") {
                Picker("主题", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
#if os(iOS)
                Picker("播放页模式", selection: $settings.nowPlayingMode) {
                    ForEach(NowPlayingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
#endif
                Toggle("显示歌词翻译", isOn: $settings.showLyricsTranslation)
                Toggle("逐字歌词（卡拉 OK）", isOn: $settings.verbatimLyrics)
                Toggle("显示日文歌词罗马音", isOn: $settings.showLyricsRomaji)
#if os(macOS)
                Toggle("桌面歌词", isOn: $settings.showDesktopLyrics)
#endif
            }

            Section("存储") {
                LabeledContent("图片缓存", value: cacheSize)
                Button("清除缓存") { clearCache() }
            }

            Section("账号") {
                if let profile = account.profile {
                    LabeledContent("当前账号", value: profile.nickname)
                    Button("退出登录", role: .destructive) {
                        Task { await AccountStore.shared.logout() }
                    }
                } else {
                    Text("未登录").foregroundStyle(.secondary)
                }
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
                Text("iOS 使用原生 SwiftUI 界面；播放、歌词和图片解析支持用户导入的 LX User API 音源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
#if os(macOS)
        .frame(width: 440, height: 520)
#endif
        .task { updateCacheSize() }
#if os(iOS)
        .fileImporter(isPresented: $isImportingLX,
                      allowedContentTypes: [.plainText, .json, .sourceCode,
                                            UTType(filenameExtension: "js") ?? .plainText]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                try lxStore.importScript(data, suggestedName: url.deletingPathExtension().lastPathComponent)
            } catch {
                lxError = error.localizedDescription
            }
        }
        .sheet(isPresented: $isShowingOnlineLX) {
            NavigationStack {
                Form {
                    Section("音源链接") {
                        TextField("https://example.com/source.js", text: $onlineSourceURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Text("只下载并保存脚本，播放时使用本地副本；不会在每次播放时重复请求这个链接。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button {
                            importOnlineSource()
                        } label: {
                            if isLoadingOnline {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("下载并导入")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(isLoadingOnline || onlineSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .navigationTitle("在线导入 LX 音源")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { isShowingOnlineLX = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("LX 音源", isPresented: Binding(
            get: { lxError != nil },
            set: { if !$0 { lxError = nil } }
        )) {
            Button("关闭", role: .cancel) { lxError = nil }
        } message: {
            Text(lxError ?? "导入失败")
        }
#endif
    }

#if os(iOS)
    private func importOnlineSource() {
        isLoadingOnline = true
        Task {
            do {
                try await lxStore.importOnlineScript(onlineSourceURL)
                isLoadingOnline = false
                isShowingOnlineLX = false
            } catch {
                isLoadingOnline = false
                lxError = error.localizedDescription
            }
        }
    }
#endif

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
