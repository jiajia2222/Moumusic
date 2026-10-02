#if os(iOS)
import Combine
import Foundation

/// Stores Bilibili downloads independently from music downloads.  Bilibili
/// returns signed URLs, so the URL is used immediately and is never persisted
/// in the manifest; only the finished local file is recorded.
@MainActor
final class BilibiliDownloadManager: NSObject, ObservableObject {
    enum Kind: String, Codable, Hashable, Sendable {
        case video
        case audio

        var displayName: String {
            switch self {
            case .video: return "视频"
            case .audio: return "音频"
            }
        }
    }

    struct Record: Codable, Identifiable, Hashable {
        let id: String
        let bvid: String
        let title: String
        let author: String
        let kind: Kind
        let quality: String
        let fileName: String
        let createdAt: Date

        var fileURL: URL {
            BilibiliDownloadManager.downloadDirectory.appendingPathComponent(fileName)
        }
    }

    struct ActiveDownload: Identifiable, Hashable {
        let id: String
        let title: String
        let author: String
        let kind: Kind
        let quality: String
        var fraction: Double?
    }

    private struct Pending {
        let record: Record
        let destination: URL
    }

    static let shared = BilibiliDownloadManager()

    @Published private(set) var records: [Record] = []
    @Published private(set) var activeDownloads: [String: ActiveDownload] = [:]

    private var pending: [Int: Pending] = [:]
    private var taskIDs: [String: Int] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private nonisolated static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moumusic", isDirectory: true)
    }

    nonisolated static var downloadDirectory: URL {
        applicationDirectory.appendingPathComponent("BilibiliDownloads", isDirectory: true)
    }

    private nonisolated static var manifestURL: URL {
        applicationDirectory.appendingPathComponent("bilibili-downloads.json")
    }

    private override init() {
        super.init()
        try? FileManager.default.createDirectory(at: Self.downloadDirectory,
                                                 withIntermediateDirectories: true)
        load()
    }

    /// Starts a download using the exact source URL and quality resolved by
    /// BilibiliAPI.  The request headers are kept in memory for this task only.
    func enqueue(source: URL, bvid: String, title: String, author: String,
                 kind: Kind, quality: String, fileExtension: String,
                 cookie: String?) {
        let id = UUID().uuidString
        let safeTitle = Self.sanitize(title.isEmpty ? bvid : title)
        let safeAuthor = Self.sanitize(author)
        let extensionName = Self.normalizedExtension(fileExtension, kind: kind)
        let suffix = String(id.prefix(8)).lowercased()
        let baseName = safeAuthor.isEmpty ? safeTitle : "\(safeTitle) - \(safeAuthor)"
        let fileName = "\(baseName)-\(suffix).\(extensionName)"
        let record = Record(id: id, bvid: bvid, title: title, author: author,
                            kind: kind, quality: quality, fileName: fileName,
                            createdAt: Date())
        let destination = Self.downloadDirectory.appendingPathComponent(fileName)

        var request = URLRequest(url: source)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/video/\(bvid)", forHTTPHeaderField: "Referer")
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let task = session.downloadTask(with: request)
        task.taskDescription = id
        pending[task.taskIdentifier] = Pending(record: record, destination: destination)
        taskIDs[id] = task.taskIdentifier
        activeDownloads[id] = ActiveDownload(id: id, title: title, author: author,
                                             kind: kind, quality: quality, fraction: nil)
        task.resume()
    }

    func cancel(_ item: ActiveDownload) {
        guard let taskID = taskIDs[item.id] else { return }
        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskIdentifier == taskID })?.cancel()
        }
        pending[taskID] = nil
        taskIDs[item.id] = nil
        activeDownloads[item.id] = nil
    }

    func delete(_ record: Record) {
        try? FileManager.default.removeItem(at: record.fileURL)
        records.removeAll { $0.id == record.id }
        save()
    }

    private func finish(taskID: Int, stagingURL: URL, response: URLResponse?) {
        guard let item = pending.removeValue(forKey: taskID) else {
            try? FileManager.default.removeItem(at: stagingURL)
            return
        }
        taskIDs[item.record.id] = nil

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: stagingURL)
            activeDownloads[item.record.id] = nil
            ToastCenter.shared.show("B站下载失败：HTTP \(http.statusCode)")
            return
        }

        do {
            try FileManager.default.createDirectory(at: Self.downloadDirectory,
                                                     withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: item.destination)
            try FileManager.default.moveItem(at: stagingURL, to: item.destination)
            records.insert(item.record, at: 0)
            save()
            ToastCenter.shared.show("已保存 B站\(item.record.kind.displayName)：\(item.record.title)")
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            ToastCenter.shared.show("B站文件保存失败：\(error.localizedDescription)")
        }
        activeDownloads[item.record.id] = nil
    }

    private func fail(taskID: Int, error: Error) {
        guard let item = pending.removeValue(forKey: taskID) else { return }
        taskIDs[item.record.id] = nil
        activeDownloads[item.record.id] = nil
        guard !(error is CancellationError) else { return }
        ToastCenter.shared.show("B站下载失败：\(error.localizedDescription)")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.manifestURL),
              let stored = try? JSONDecoder().decode([Record].self, from: data) else { return }
        records = stored.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        if records.count != stored.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: Self.applicationDirectory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.manifestURL, options: .atomic)
    }

    private static func sanitize(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let clean = value.components(separatedBy: invalid).joined(separator: "_")
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Bilibili" : trimmed).prefix(80))
    }

    private static func normalizedExtension(_ value: String, kind: Kind) -> String {
        let ext = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let allowed = kind == .audio
            ? ["m4s", "m4a", "mp4", "aac", "mp3", "webm"]
            : ["mp4", "m4v", "mov", "flv", "m4s", "webm"]
        return allowed.contains(ext) ? ext : (kind == .audio ? "m4s" : "mp4")
    }
}

extension BilibiliDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let fraction = totalBytesExpectedToWrite > 0
            ? min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            : nil
        Task { @MainActor [weak self] in
            guard let self, var item = self.activeDownloads[id] else { return }
            item.fraction = fraction
            self.activeDownloads[id] = item
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Moumusic-Bilibili-\(UUID().uuidString).download")
        let moved = (try? {
            try FileManager.default.moveItem(at: location, to: stagingURL)
            return true
        }()) ?? false
        Task { @MainActor [weak self] in
            guard let self else { return }
            if moved {
                self.finish(taskID: downloadTask.taskIdentifier,
                            stagingURL: stagingURL,
                            response: downloadTask.response)
            } else {
                self.fail(taskID: downloadTask.taskIdentifier,
                          error: URLError(.cannotCreateFile))
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.fail(taskID: task.taskIdentifier, error: error)
        }
    }
}
#endif
