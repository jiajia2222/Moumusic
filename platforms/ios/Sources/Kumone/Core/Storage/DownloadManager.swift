#if os(iOS)
import Combine
import Foundation

/// Downloads audio through the selected LX User API and keeps a small local
/// manifest so downloaded tracks can be played even when the source is down.
@MainActor
final class DownloadManager: ObservableObject {
    struct Record: Codable, Identifiable, Hashable {
        let id: String
        let track: Track
        let quality: String
        let fileName: String
        let createdAt: Date

        var fileURL: URL { DownloadManager.downloadDirectory.appendingPathComponent(fileName) }
    }

    static let shared = DownloadManager()

    @Published private(set) var records: [Record] = []
    @Published private(set) var downloadingKeys: Set<String> = []

    private var tasks: [String: Task<Void, Never>] = [:]

    private static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moumusic", isDirectory: true)
    }

    static var downloadDirectory: URL {
        applicationDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    private static var manifestURL: URL {
        applicationDirectory.appendingPathComponent("downloads.json")
    }

    private init() {
        try? FileManager.default.createDirectory(at: Self.downloadDirectory,
                                                 withIntermediateDirectories: true)
        load()
    }

    func record(for track: Track) -> Record? {
        let key = track.normalizedForLXPlayback().playbackKey
        return records.first { $0.id == key && FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    func isDownloading(_ track: Track) -> Bool {
        downloadingKeys.contains(track.normalizedForLXPlayback().playbackKey)
    }

    func download(_ track: Track) {
        let normalized = track.normalizedForLXPlayback()
        let key = normalized.playbackKey
        guard record(for: normalized) == nil else {
            ToastCenter.shared.show("歌曲已下载")
            return
        }
        guard tasks[key] == nil else { return }

        downloadingKeys.insert(key)
        ToastCenter.shared.show("正在解析并下载《\(normalized.name)》")
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.downloadingKeys.remove(key)
                self.tasks[key] = nil
            }
            do {
                let resolved = try await LXUserAPIService.shared.resolveMusicURL(
                    for: normalized,
                    quality: SettingsManager.shared.audioQuality.rawValue
                )
                let (temporaryURL, response) = try await URLSession.shared.download(from: resolved.url)
                if let response = response as? HTTPURLResponse,
                   !(200..<300).contains(response.statusCode) {
                    throw DownloadError.http(response.statusCode)
                }

                try FileManager.default.createDirectory(at: Self.downloadDirectory,
                                                         withIntermediateDirectories: true)
                let ext = Self.fileExtension(for: resolved.url)
                let fileName = "\(UUID().uuidString).\(ext)"
                let destination = Self.downloadDirectory.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                let item = Record(id: key, track: normalized, quality: resolved.quality,
                                  fileName: fileName, createdAt: Date())
                records.insert(item, at: 0)
                save()
                ToastCenter.shared.show("已下载《\(normalized.name)》")
            } catch is CancellationError {
                // A cancelled task is silent; the user can start it again.
            } catch {
                ToastCenter.shared.show("下载失败：\(error.localizedDescription)")
            }
        }
        tasks[key] = task
    }

    func delete(_ record: Record) {
        tasks[record.id]?.cancel()
        tasks[record.id] = nil
        try? FileManager.default.removeItem(at: record.fileURL)
        records.removeAll { $0.id == record.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.manifestURL),
              let stored = try? JSONDecoder().decode([Record].self, from: data) else { return }
        records = stored.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        if records.count != stored.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Self.manifestURL, options: .atomic)
    }

    private static func fileExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["mp3", "m4a", "flac", "wav", "aac", "ogg", "opus"].contains(ext) ? ext : "m4a"
    }

    private enum DownloadError: LocalizedError {
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .http(let status): return "服务器返回 HTTP \(status)"
            }
        }
    }
}
#endif
