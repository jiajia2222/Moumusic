import SwiftUI

/// 缓存分类。清理只动可再生成的缓存，不碰登录信息、设置、壁纸、自定义封面、下载文件和本地音乐。
enum BeansCacheCategory: String, CaseIterable, Identifiable {
    case images
    case pageData
    case video
    case lockScreen
    case temporary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: return "封面与图片缓存"
        case .pageData: return "首页与详情数据"
        case .video: return "视频与弹幕资源"
        case .lockScreen: return "锁屏沉浸素材"
        case .temporary: return "临时文件"
        }
    }

    var icon: String {
        switch self {
        case .images: return "photo.on.rectangle"
        case .pageData: return "rectangle.stack"
        case .video: return "play.rectangle"
        case .lockScreen: return "lock.rectangle"
        case .temporary: return "clock.arrow.circlepath"
        }
    }
}

struct BeansCacheUsage: Identifiable {
    let category: BeansCacheCategory
    let bytes: Int64
    /// 正在使用而被保留的字节数（例如当前播放的视频、当前锁屏素材）。
    let protectedBytes: Int64
    var id: String { category.rawValue }
}

@MainActor
final class BeansCacheManager: ObservableObject {
    static let shared = BeansCacheManager()

    @Published private(set) var usages: [BeansCacheUsage] = []
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?

    /// 其他模块把“正在使用”的文件路径登记在这里，清理时跳过。
    private var protectedPaths: [BeansCacheCategory: Set<String>] = [:]

    nonisolated static var cachesRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// 视频/弹幕、锁屏素材各自独立的目录，便于统计与清理。
    nonisolated static func directory(for category: BeansCacheCategory) -> URL? {
        switch category {
        case .video: return ensure("BeansVideo")
        case .lockScreen: return ensure("BeansLockScreen")
        case .images: return ensure("BeansImages")
        default: return nil
        }
    }

    nonisolated private static func ensure(_ name: String) -> URL {
        let url = cachesRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func protect(_ url: URL, in category: BeansCacheCategory) {
        protectedPaths[category, default: []].insert(url.standardizedFileURL.path)
    }

    func unprotect(_ url: URL, in category: BeansCacheCategory) {
        protectedPaths[category]?.remove(url.standardizedFileURL.path)
    }

    // MARK: 统计

    func refresh() async {
        isWorking = true
        defer { isWorking = false }
        let protected = protectedPaths
        let result = await Task.detached(priority: .utility) { () -> [BeansCacheUsage] in
            BeansCacheCategory.allCases.map { category in
                let guarded = protected[category] ?? []
                return BeansCacheUsage(
                    category: category,
                    bytes: Self.measure(category, excluding: []),
                    protectedBytes: Self.measure(category, excluding: guarded, onlyExcluded: true)
                )
            }
        }.value
        usages = result
        lastError = nil
    }

    var totalBytes: Int64 { usages.reduce(0) { $0 + $1.bytes } }

    nonisolated private static func measure(_ category: BeansCacheCategory, excluding: Set<String>, onlyExcluded: Bool = false) -> Int64 {
        switch category {
        case .pageData:
            if onlyExcluded { return 0 }
            let d = UserDefaults.standard
            return ["beans.detailSongsCache.v1", "beans.syncedPlaylistCache.playlists.v1", "beans.syncedPlaylistCache.songs.v1"]
                .reduce(Int64(0)) { $0 + Int64(d.data(forKey: $1)?.count ?? 0) }
        case .temporary:
            if onlyExcluded { return 0 }
            return directorySize(FileManager.default.temporaryDirectory, excluding: [])
        case .images:
            if onlyExcluded { return 0 }
            return Int64(URLCache.shared.currentDiskUsage) + directorySize(cachesRoot.appendingPathComponent("BeansImages"), excluding: [])
        case .video, .lockScreen:
            guard let dir = directory(for: category) else { return 0 }
            if onlyExcluded {
                return excluding.reduce(Int64(0)) { $0 + fileSize(URL(fileURLWithPath: $1)) }
            }
            return directorySize(dir, excluding: [])
        }
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }

    nonisolated private static func directorySize(_ url: URL, excluding: Set<String>) -> Int64 {
        guard let it = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in it {
            if excluding.contains(file.standardizedFileURL.path) { continue }
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    // MARK: 清理

    func clear(_ category: BeansCacheCategory) async {
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        switch category {
        case .pageData:
            DiscoverCache.shared.removeAll()
            DetailSongsCache.shared.removeAll()
            SyncedPlaylistCache.shared.removeAll()
        case .images:
            URLCache.shared.removeAllCachedResponses()
            BeansImageFileCache.removeAll()
            removeContents(of: Self.cachesRoot.appendingPathComponent("BeansImages"), keeping: [])
        case .temporary:
            removeContents(of: FileManager.default.temporaryDirectory, keeping: [])
        case .video, .lockScreen:
            if let dir = Self.directory(for: category) {
                removeContents(of: dir, keeping: protectedPaths[category] ?? [])
            }
        }
        await refresh()
    }

    func clearAll() async {
        for category in BeansCacheCategory.allCases { await clear(category) }
    }

    private func removeContents(of dir: URL, keeping: Set<String>) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items {
            let path = item.standardizedFileURL.path
            // 保留正在使用的文件（或包含它们的目录）。
            if keeping.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) { continue }
            do { try FileManager.default.removeItem(at: item) }
            catch { lastError = "分类缓存清理失败" }
        }
    }
}

@MainActor
struct CacheManagementView: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = BeansCacheManager.shared
    @State private var confirmClearAll = false

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(ByteCountFormatter.string(fromByteCount: manager.totalBytes, countStyle: .file))
                                    .font(BeansFont.appFont(30, .bold)).foregroundStyle(Color.beansLabel)
                                Text("保留登录信息、设置、壁纸、自定义封面、下载文件、本地音乐及正在使用的播放素材。")
                                    .font(BeansFont.appFont(12)).foregroundStyle(Color.beansComment)
                            }
                        }
                        if let error = manager.lastError {
                            Text(error).font(BeansFont.appFont(12)).foregroundStyle(Color.red)
                        }
                        ForEach(manager.usages) { usage in
                            GlassCard {
                                HStack(spacing: 12) {
                                    Image(systemName: usage.category.icon)
                                        .font(.system(size: 18)).foregroundStyle(Color.beansAmber).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(usage.category.title).font(BeansFont.appFont(15, .semibold)).foregroundStyle(Color.beansLabel)
                                        Text(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
                                             + (usage.protectedBytes > 0 ? " · 含正在使用 \(ByteCountFormatter.string(fromByteCount: usage.protectedBytes, countStyle: .file))" : ""))
                                            .font(BeansFont.appFont(12)).foregroundStyle(Color.beansComment)
                                    }
                                    Spacer()
                                    Button("清理") { Task { await manager.clear(usage.category); BeansHaptics.success() } }
                                        .font(BeansFont.appFont(13, .semibold))
                                        .disabled(manager.isWorking || usage.bytes == 0)
                                }
                            }
                        }
                        HStack(spacing: 10) {
                            GlassButton(title: "刷新缓存统计", systemName: "arrow.clockwise") { Task { await manager.refresh() } }
                            GlassButton(title: "清理全部缓存", systemName: "trash", prominent: true) { confirmClearAll = true }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("清理缓存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task { await manager.refresh() }
        .alert("清理全部缓存？", isPresented: $confirmClearAll) {
            Button("清理", role: .destructive) { Task { await manager.clearAll(); ToastCenter.shared.show("缓存已清理") } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会清理可重新生成的缓存。")
        }
    }
}
