import Foundation

/// Owns disposable application caches without touching user-owned downloads,
/// playlists, settings, or account credentials.
///
/// The Bilibili player writes signed-url staging files to `tmp`, while image
/// and other transient data live under `Library/Caches`. Both locations are
/// included here, so the Settings screen can report and clear them together.
actor AppCacheManager {
    static let shared = AppCacheManager()

    enum CacheCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
        case artwork
        case catalogue
        case media
        case temporary
        /// The local copies of streamed FLACs (`Caches/MoumusicFLAC`). Songs the user downloaded are NOT here: they live in
        /// Application Support/Moumusic/Downloads, which this manager never touches.
        case playback

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .artwork: return "封面与图片"
            case .catalogue: return "推荐与目录"
            case .media: return "音频与视频临时文件"
            case .temporary: return "临时文件"
            case .playback: return "播放时下载的 FLAC 副本"
            }
        }

        var symbolName: String {
            switch self {
            case .artwork: return "photo"
            case .catalogue: return "rectangle.stack"
            case .media: return "waveform"
            case .temporary: return "clock.arrow.circlepath"
            case .playback: return "arrow.down.circle"
            }
        }
    }

    struct Summary: Sendable {
        let fileCount: Int
        let byteCount: Int64
    }

    struct ClearResult: Sendable {
        let fileCount: Int
        let byteCount: Int64
    }

    typealias ProgressHandler = @Sendable (Double) async -> Void

    private let fileManager = FileManager.default

    func summary() -> Summary {
        let files = cacheFiles()
        return makeSummary(files)
    }

    func summary(for category: CacheCategory) -> Summary {
        makeSummary(files(for: category))
    }

    func clearAll(progress: @escaping ProgressHandler) async -> ClearResult {
        // NSCache keeps images alive even after their disk files are gone.
        await ImageCache.shared.removeAll()

        await MainActor.run {
            HomeRecommendationCache.shared.clear()
            LXPlaylistDetailCache.shared.clear()
        }

        let result = await clearFiles(await withoutPlayingCopy(cacheFiles()), progress: progress)
        await MainActor.run { PlayerService.shared.forgetClearedLocalFLACCopies() }
        await progress(1)
        return result
    }

    func clear(_ category: CacheCategory, progress: @escaping ProgressHandler) async -> ClearResult {
        if category == .artwork {
            await ImageCache.shared.removeAll()
        }
        if category == .catalogue {
            await MainActor.run {
                HomeRecommendationCache.shared.clear()
                LXPlaylistDetailCache.shared.clear()
            }
        }

        let result = await clearFiles(await withoutPlayingCopy(files(for: category)), progress: progress)
        if category == .playback { await MainActor.run { PlayerService.shared.forgetClearedLocalFLACCopies() } }
        await progress(1)
        return result
    }

    /// The song playing from its local copy keeps that file (deleting it under the player would stop the song).
    private func withoutPlayingCopy(_ files: [URL]) async -> [URL] {
        guard let playing = await MainActor.run(body: { PlayerService.shared.currentLocalFLACFile?.standardizedFileURL.path }) else { return files }
        return files.filter { $0.standardizedFileURL.path != playing }
    }

    private func clearFiles(_ files: [URL], progress: @escaping ProgressHandler) async -> ClearResult {
        let total = max(files.count, 1)
        var removedFiles = 0
        var removedBytes: Int64 = 0

        for (index, file) in files.enumerated() {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey]) {
                removedBytes += Int64(values.fileSize ?? 0)
            }
            if fileManager.fileExists(atPath: file.path) {
                try? fileManager.removeItem(at: file)
                removedFiles += 1
            }
            if index == files.count - 1 || index.isMultiple(of: 8) {
                await progress(min(1, Double(index + 1) / Double(total)))
            }
        }

        removeEmptyDirectories()
        return ClearResult(fileCount: removedFiles, byteCount: removedBytes)
    }

    private func makeSummary(_ files: [URL]) -> Summary {
        let bytes = files.reduce(Int64.zero) { result, file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]) else { return result }
            return result + Int64(values.fileSize ?? 0)
        }
        return Summary(fileCount: files.count, byteCount: bytes)
    }

    private func cacheRoots() -> [URL] {
        var roots: [URL] = []
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(caches)
        }
        roots.append(fileManager.temporaryDirectory)

        // Keep Application Support intact by only including directories that
        // are explicitly named as cache/temp. In particular, saved Bilibili
        // files under BilibiliDownloads are intentionally preserved.
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let support = applicationSupport.appendingPathComponent("Moumusic", isDirectory: true)
            if let children = try? fileManager.contentsOfDirectory(
                at: support,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                roots.append(contentsOf: children.filter { url in
                    let name = url.lastPathComponent.lowercased()
                    return name.contains("cache") || name.contains("temp") || name == "tmp"
                })
            }
        }
        return roots
    }

    private func cacheFiles() -> [URL] {
        var result: [URL] = []
        for root in cacheRoots() {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []
            ) else { continue }
            for case let file as URL in enumerator {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                result.append(file)
            }
        }
        return result
    }

    private func files(for category: CacheCategory) -> [URL] {
        cacheFiles().filter { classify($0) == category }
    }

    private func classify(_ file: URL) -> CacheCategory {
        let path = file.path.lowercased()
        if path.contains("/moumusicflac/") { return .playback }
        if path.contains("/tmp/") || path.contains("\\tmp\\") || path.contains("/temporary/") {
            return .temporary
        }
        if path.contains("/images/") || path.contains("\\images\\") ||
            ["jpg", "jpeg", "png", "heic", "webp", "gif"].contains(file.pathExtension.lowercased()) {
            return .artwork
        }
        if ["mp3", "m4a", "flac", "aac", "ogg", "wav", "mp4", "mkv", "mov"].contains(file.pathExtension.lowercased()) ||
            path.contains("audio") || path.contains("video") {
            return .media
        }
        return .catalogue
    }

    private func removeEmptyDirectories() {
        for root in cacheRoots() {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }
            let directories = (enumerator.allObjects as? [URL] ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.path.count > $1.path.count }
            for directory in directories {
                if let contents = try? fileManager.contentsOfDirectory(atPath: directory.path), contents.isEmpty {
                    try? fileManager.removeItem(at: directory)
                }
            }
        }
    }
}
