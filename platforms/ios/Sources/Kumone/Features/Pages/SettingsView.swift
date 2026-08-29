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
                Text("无损与 Hi-Res 是否可用取决于音源和账号权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("灰色歌曲解锁", isOn: $settings.enableUnblock)
                Text("开启后，无法播放的歌曲会尝试 Kumone 的兼容解锁流程。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

#if os(iOS)
            Section {
                Picker(selection: $settings.homeRecommendationMode) {
                    ForEach(HomeRecommendationMode.allCases) { mode in
                        Text(verbatim: mode.displayName).tag(mode)
                    }
                } label: {
                    Text(String(localized: "推荐来源"))
                }
                Text(String(localized: "默认使用 LX 聚合推荐；网易云推荐仅在你主动选择时读取网易云接口。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "首页推荐"))
            }
#endif

#if os(iOS)
            Section {
                if lxStore.sources.isEmpty {
                    Text(String(localized: "没有内置音源，请导入 LX User API 文件。"))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("当前音源", selection: Binding(
                        get: { lxStore.selectedID ?? "" },
                        set: { lxStore.select($0.isEmpty ? nil : $0) }
                    )) {
                        Text(String(localized: "不启用")).tag("")
                        ForEach(lxStore.sources) { source in
                            Text(verbatim: source.name).tag(source.id)
                        }
                    }
                    ForEach(lxStore.sources) { source in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: source.name).font(.body.weight(.medium))
                                let detail = [source.author, source.version]
                                    .filter { !$0.isEmpty }.joined(separator: " · ")
                                if !detail.isEmpty {
                                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                                }
                                if !source.description.isEmpty {
                                    Text(verbatim: source.description)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                             Button(role: .destructive) { lxStore.remove(source) } label: {
                                 Text(String(localized: "删除"))
                             }
                                 .font(.caption)
                        }
                    }
                    }
                    Button {
                        isImportingLX = true
                    } label: {
                        Label {
                        Text(String(localized: "导入 LX User API"))
                        } icon: {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                Text(String(localized: "音源由用户自行添加；支持 LX 导出的 JSON 或原始 JavaScript 文件。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "LX 音源"))
            } footer: {
                Text(String(localized: "导入后请选择一个音源启用；播放、歌词和音质由该音源提供。"))
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
                Text("about.description")
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
                LXUserAPIService.shared.loadSelectedSource()
            } catch {
                lxError = error.localizedDescription
            }
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
