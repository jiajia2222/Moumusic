import Foundation

/// Owns disposable application caches without touching user-owned downloads,
/// playlists, settings, or account credentials.
///
/// The Bilibili player writes signed-url staging files to `tmp`, while image
/// and other transient data live under `Library/Caches`. Both locations are
/// included here, so the Settings screen can report and clear them together.
actor AppCacheManager {
    static let shared = AppCacheManager()

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
        let bytes = files.reduce(Int64.zero) { result, file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]) else { return result }
            return result + Int64(values.fileSize ?? 0)
        }
        return Summary(fileCount: files.count, byteCount: bytes)
    }

    func clearAll(progress: @escaping ProgressHandler) async -> ClearResult {
        // NSCache keeps images alive even after their disk files are gone.
        await ImageCache.shared.removeAll()

        let files = cacheFiles()
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
        await progress(1)
        return ClearResult(fileCount: removedFiles, byteCount: removedBytes)
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
