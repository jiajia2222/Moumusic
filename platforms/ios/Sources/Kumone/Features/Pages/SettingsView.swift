import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
#if os(iOS)
    @EnvironmentObject private var player: PlayerService
    @StateObject private var lxStore = LXSourceStore.shared
#endif
    @State private var cacheSize = "计算中…"
#if os(iOS)
    @State private var showSourceManager = false
    @State private var showDownloads = false
#endif

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
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
