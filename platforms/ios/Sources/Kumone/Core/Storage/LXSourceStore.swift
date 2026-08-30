#if os(iOS)
import Foundation
import SwiftUI

/// User-managed LX User API scripts. Moumusic ships no provider script: the
/// user chooses the source file exported by LX Music or another compatible
/// client, just like the upstream LX application.
@MainActor
final class LXSourceStore: ObservableObject {
    struct Source: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        let description: String
        let version: String
        let author: String
        let homepage: String
        let script: String
        /// The download URL is kept separately from the optional homepage so
        /// users can see which online source they imported and update it later.
        let sourceURL: String?
    }

    static let shared = LXSourceStore()

    @Published private(set) var sources: [Source] = []
    @Published private(set) var selectedID: String?

    var selectedSource: Source? {
        guard let selectedID else { return nil }
        return sources.first { $0.id == selectedID }
    }

    private static let selectedKey = "lx.selectedSource"

    private init() {
        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey)
        let data = try? Data(contentsOf: Self.fileURL)
        sources = (data.flatMap { try? JSONDecoder().decode([Source].self, from: $0) }) ?? []
        if selectedID != nil, selectedSource == nil { selectedID = sources.first?.id }
    }

    func importScript(_ data: Data, suggestedName: String, sourceURL: String? = nil) throws {
        guard let raw = String(data: data, encoding: .utf8),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.invalidEncoding
        }
        let source = decodeExport(raw, sourceURL: sourceURL)
            ?? sourceFromHeader(raw, suggestedName: suggestedName, sourceURL: sourceURL)
        let script = source.script.lowercased()
        guard script.contains("musicurl") || script.contains("lyric") || script.contains("globalthis.lx") else {
            throw ImportError.invalidScript
        }
        sources.removeAll { $0.id == source.id || $0.name == source.name }
        sources.append(source)
        sources.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
        if selectedID == nil { select(source.id) }
    }

    /// Downloads and imports an LX User API script. The script remains local
    /// after import; the URL is metadata only and is never fetched at playback
    /// time. This mirrors LX Mobile's explicit online-import flow.
    func importOnlineScript(_ rawURL: String) async throws {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw ImportError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Moumusic/0.5 LX source importer", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ImportError.downloadFailed
        }
        guard data.count <= 9_000_000 else { throw ImportError.tooLarge }

        let suggestedName = url.deletingPathExtension().lastPathComponent.isEmpty
            ? (url.host ?? "LX 音源")
            : url.deletingPathExtension().lastPathComponent
        try importScript(data, suggestedName: suggestedName, sourceURL: url.absoluteString)
    }

    func select(_ id: String?) {
        guard id == nil || sources.contains(where: { $0.id == id }) else { return }
        selectedID = id
        if let id { UserDefaults.standard.set(id, forKey: Self.selectedKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.selectedKey) }
        LXUserAPIService.shared.loadSelectedSource()
    }

    func remove(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        if selectedID == source.id { selectedID = sources.first?.id }
        persist()
        if let selectedID { UserDefaults.standard.set(selectedID, forKey: Self.selectedKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.selectedKey) }
        LXUserAPIService.shared.loadSelectedSource()
    }

    enum ImportError: LocalizedError {
        case invalidEncoding
        case invalidScript
        case invalidURL
        case downloadFailed
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidEncoding: return "无法读取音源文件，请选择 UTF-8 文本或 JSON 文件"
            case .invalidScript: return "这不是可识别的 LX User API 音源"
            case .invalidURL: return "请输入有效的 HTTP 或 HTTPS 音源链接"
            case .downloadFailed: return "音源下载失败，请检查链接和网络"
            case .tooLarge: return "音源文件超过 9 MB，已拒绝导入"
            }
        }
    }

    private struct Export: Decodable {
        let id: String?
        let name: String?
        let description: String?
        let desc: String?
        let version: String?
        let author: String?
        let homepage: String?
        let script: String?
        let sourceURL: String?
        let url: String?
    }

    private func decodeExport(_ raw: String, sourceURL: String?) -> Source? {
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines).first == "{",
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(Export.self, from: data),
              let script = value.script, !script.isEmpty else { return nil }
        return Source(id: value.id ?? UUID().uuidString,
                      name: value.name?.isEmpty == false ? value.name! : "LX 音源",
                      description: value.description ?? value.desc ?? "",
                       version: value.version ?? "",
                       author: value.author ?? "",
                       homepage: value.homepage ?? "",
                       script: script,
                       sourceURL: sourceURL ?? value.sourceURL ?? value.url)
    }

    private func sourceFromHeader(_ raw: String, suggestedName: String, sourceURL: String?) -> Source {
        func value(_ key: String) -> String {
            for line in raw.components(separatedBy: .newlines) {
                guard let range = line.range(of: "@\(key)", options: .caseInsensitive) else { continue }
                let result = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.isEmpty { return result }
            }
            return ""
        }
        let name = value("name")
        return Source(id: UUID().uuidString,
                      name: name.isEmpty ? suggestedName.replacingOccurrences(of: ".js", with: "") : name,
                      description: value("description"), version: value("version"),
                      author: value("author"), homepage: value("homepage"), script: raw,
                      sourceURL: sourceURL)
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(sources) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    private static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moumusic", isDirectory: true)
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent("lx-sources.json")
    }
}
#endif
