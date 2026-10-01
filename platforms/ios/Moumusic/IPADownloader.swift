import Foundation
import Combine

// MARK: - 新版 IPA 自动下载（下载到临时目录后直接交给系统分享）

/// 下载状态：用于展示进度与结果
enum IPADownloadState {
    case idle
    case downloading(progress: Double)   // 0...1；-1 表示未知大小，显示不定进度
    case finished(fileURL: URL)
    case failed(message: String)
}

final class IPADownloader: NSObject, ObservableObject {
    static let shared = IPADownloader()

    @Published var state: IPADownloadState = .idle
    @Published var progress: Double = 0
    @Published var isDownloading = false

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    /// 下载指定版本 IPA 到临时目录，返回本地文件 URL；分享结束后由调用方删除。
    func download(assetURL: URL, version: String) async throws -> URL {
        cancelQuietly()
        let dir = FileManager.default.temporaryDirectory
        destination = dir.appendingPathComponent("Beans-\(version)-unsigned.ipa")

        progress = 0
        isDownloading = true
        state = .downloading(progress: 0)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let t = session?.downloadTask(with: assetURL)
            task = t
            t?.resume()
        }
    }

    private func cancelQuietly() {
        task?.cancel()
        task = nil
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        isDownloading = false
        state = .idle
    }
}

extension IPADownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            progress = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        } else {
            progress = -1
        }
        state = .downloading(progress: progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest = destination else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            isDownloading = false
            continuation?.resume(returning: dest)
            continuation = nil
            state = .finished(fileURL: dest)
        } catch {
            isDownloading = false
            continuation?.resume(throwing: error)
            continuation = nil
            state = .failed(message: error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        guard let continuation else { return }
        isDownloading = false
        self.continuation = nil
        state = .failed(message: error.localizedDescription)
        continuation.resume(throwing: error)
    }
}
