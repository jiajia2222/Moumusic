#if os(iOS)
import Combine
import Foundation

/// Downloads audio through the selected LX User API.  A download is resolved
/// at the quality chosen by the user; the provider's returned quality is
/// stored so the library never claims a quality the source did not serve.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    struct Record: Codable, Identifiable, Hashable {
        let id: String
        let track: Track
        let quality: String
        let fileName: String
        let createdAt: Date

        var fileURL: URL { DownloadManager.downloadDirectory.appendingPathComponent(fileName) }
    }

    struct ActiveDownload: Identifiable {
        let id: String
        let track: Track
        let requestedQuality: AudioQuality
        var fraction: Double?
    }

    static let shared = DownloadManager()

    @Published private(set) var records: [Record] = []
    @Published private(set) var activeDownloads: [String: ActiveDownload] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]
    private var continuations: [Int: CheckedContinuation<(URL, URLResponse), Error>] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private nonisolated static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moumusic", isDirectory: true)
    }

    nonisolated static var downloadDirectory: URL {
        applicationDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    private nonisolated static var manifestURL: URL {
        applicationDirectory.appendingPathComponent("downloads.json")
    }

    private override init() {
        super.init()
        try? FileManager.default.createDirectory(at: Self.downloadDirectory,
                                                 withIntermediateDirectories: true)
        load()
    }

    func record(for track: Track) -> Record? {
        let key = track.normalizedForLXPlayback().playbackKey
        return records.first { $0.id == key && FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    func isDownloading(_ track: Track) -> Bool {
        activeDownloads[track.normalizedForLXPlayback().playbackKey] != nil
    }

    func download(_ track: Track, quality: AudioQuality? = nil) {
        let normalized = track.normalizedForLXPlayback()
        let key = normalized.playbackKey
        guard record(for: normalized) == nil else {
            ToastCenter.shared.show("歌曲已经下载")
            return
        }
        guard tasks[key] == nil else { return }

        let requestedQuality = quality ?? SettingsManager.shared.audioQuality
        activeDownloads[key] = ActiveDownload(id: key, track: normalized,
                                              requestedQuality: requestedQuality,
                                              fraction: nil)
        ToastCenter.shared.show("正在解析并下载 \(normalized.name)")

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.activeDownloads[key] = nil
                self.tasks[key] = nil
            }
            do {
                let resolved = try await LXUserAPIService.shared.resolveMusicURL(
                    for: normalized, quality: requestedQuality.rawValue)
                let (temporaryURL, response) = try await self.downloadFile(from: resolved.url,
                                                                            key: key)
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
                ToastCenter.shared.show("已下载 \(normalized.name)")
            } catch is CancellationError {
                // A cancelled task is silent; the user can start it again.
            } catch {
                ToastCenter.shared.show("下载失败：\(error.localizedDescription)")
            }
        }
        tasks[key] = task
    }

    func downloadBatch(_ tracks: [Track], quality: AudioQuality) {
        for track in tracks { download(track, quality: quality) }
    }

    func availableQualities(for track: Track) async -> [AudioQuality] {
        let names = await LXUserAPIService.shared.availableQualityNames(for: track)
        var seenTypes = Set<String>()
        let result = AudioQuality.allCases.filter {
            names.contains($0.lxType) && seenTypes.insert($0.lxType).inserted
        }
        return result.isEmpty ? [.standard] : result
    }

    func delete(_ record: Record) {
        tasks[record.id]?.cancel()
        tasks[record.id] = nil
        activeDownloads[record.id] = nil
        try? FileManager.default.removeItem(at: record.fileURL)
        records.removeAll { $0.id == record.id }
        save()
    }

    private func downloadFile(from url: URL, key: String) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                task.taskDescription = key
                continuations[task.taskIdentifier] = continuation
                task.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.session.getAllTasks { tasks in
                    tasks.first(where: { $0.taskDescription == key })?.cancel()
                }
            }
        }
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
        case temporaryFile

        var errorDescription: String? {
            switch self {
            case .http(let status): return "服务器返回 HTTP \(status)"
            case .temporaryFile: return "无法保存下载文件"
            }
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        let fraction = totalBytesExpectedToWrite > 0
            ? min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            : nil
        Task { @MainActor [weak self] in
            guard let self, var item = self.activeDownloads[key] else { return }
            item.fraction = fraction
            self.activeDownloads[key] = item
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // URLSession deletes its temporary file after this callback returns.
        // Move it to a stable staging path before resuming the continuation.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Moumusic-\(UUID().uuidString).download")
        let moved = (try? {
            try FileManager.default.moveItem(at: location, to: destination)
            return true
        }()) ?? false
        Task { @MainActor [weak self] in
            guard let self, let continuation = self.continuations.removeValue(forKey: downloadTask.taskIdentifier) else { return }
            if moved {
                let response = downloadTask.response ?? URLResponse(
                    url: downloadTask.currentRequest?.url ?? URL(string: "about:blank")!,
                    mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
                continuation.resume(returning: (destination, response))
            } else {
                continuation.resume(throwing: DownloadError.temporaryFile)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.continuations.removeValue(forKey: task.taskIdentifier)?.resume(throwing: error)
        }
    }
}
#endif
