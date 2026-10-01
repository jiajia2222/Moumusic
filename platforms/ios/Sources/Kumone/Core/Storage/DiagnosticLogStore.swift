import Combine
import Foundation

/// Small, local-only diagnostic journal for the support flow.  It deliberately
/// stores messages supplied by the app rather than request headers, cookies,
/// tokens, or raw provider responses.
@MainActor
final class DiagnosticLogStore: ObservableObject {
    static let shared = DiagnosticLogStore()

    enum Level: String, CaseIterable, Codable, Identifiable, Sendable {
        case info
        case warning
        case error

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .info: return "信息"
            case .warning: return "警告"
            case .error: return "错误"
            }
        }
    }

    struct Entry: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        let date: Date
        let level: Level
        let category: String
        let message: String
        let detail: String?
    }

    @Published private(set) var entries: [Entry] = []

    private let fileManager = FileManager.default
    private let maxEntries = 500

    private init() {
        load()
    }

    func append(level: Level, category: String, message: String, detail: String? = nil) {
        let safeDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = Entry(
            id: UUID(),
            date: Date(),
            level: level,
            category: category,
            message: message,
            detail: safeDetail?.isEmpty == false ? safeDetail : nil
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    func clear() {
        entries.removeAll(keepingCapacity: false)
        try? fileManager.removeItem(at: fileURL)
    }

    func exportData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(entries)) ?? Data("[]".utf8)
    }

    private var fileURL: URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moumusic", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("diagnostic-logs.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = Array((try? decoder.decode([Entry].self, from: data))?.prefix(maxEntries) ?? [])
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
