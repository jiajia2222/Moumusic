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
        /// The download URL is metadata only. Playback always uses the local
        /// script, so an online source changing cannot silently change it.
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
        if selectedID != nil, selectedSource == nil {
            selectedID = sources.first?.id
        }
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
        if selectedID == nil || selectedID == source.id || selectedSource == nil {
            select(source.id)
        }
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
        request.setValue("Moumusic LX source importer", forHTTPHeaderField: "User-Agent")
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
        if let id {
            UserDefaults.standard.set(id, forKey: Self.selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedKey)
        }
        LXUserAPIService.shared.loadSelectedSource()
    }

    func remove(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        if selectedID == source.id { selectedID = sources.first?.id }
        persist()
        if let selectedID {
            UserDefaults.standard.set(selectedID, forKey: Self.selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedKey)
        }
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

    /// LX exports have existed in several shapes: some use a nested `info`
    /// object, some are arrays, and older exports encode `version` as a
    /// number. Decode all of those without losing the metadata shown in the
    /// source manager.
    private struct ExportMetadata: Decodable {
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

        private enum CodingKeys: String, CodingKey {
            case id, name, description, desc, version, ver, sourceVersion
            case author, homepage, script, sourceURL, sourceUrl, url
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = Self.firstString(in: container, keys: [.id])
            name = Self.firstString(in: container, keys: [.name])
            description = Self.firstString(in: container, keys: [.description])
            desc = Self.firstString(in: container, keys: [.desc])
            version = Self.firstString(in: container, keys: [.version, .ver, .sourceVersion])
            author = Self.firstString(in: container, keys: [.author])
            homepage = Self.firstString(in: container, keys: [.homepage])
            script = Self.firstString(in: container, keys: [.script])
            sourceURL = Self.firstString(in: container, keys: [.sourceURL, .sourceUrl])
            url = Self.firstString(in: container, keys: [.url])
        }

        private static func firstString(
            in container: KeyedDecodingContainer<CodingKeys>,
            keys: [CodingKeys]
        ) -> String? {
            for key in keys {
                if let value = try? container.decode(String.self, forKey: key),
                   !value.isEmpty {
                    return value
                }
                if let value = try? container.decode(Int.self, forKey: key) {
                    return String(value)
                }
                if let value = try? container.decode(Double.self, forKey: key) {
                    return value.rounded() == value ? String(Int(value)) : String(value)
                }
            }
            return nil
        }
    }

    private struct Export: Decodable {
        private let metadata: ExportMetadata
        let info: ExportMetadata?

        init(from decoder: Decoder) throws {
            metadata = try ExportMetadata(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            info = try? container.decode(ExportMetadata.self, forKey: .info)
        }

        private enum CodingKeys: String, CodingKey {
            case info
        }

        var id: String? { metadata.id }
        var name: String? { metadata.name }
        var description: String? { metadata.description }
        var desc: String? { metadata.desc }
        var version: String? { metadata.version }
        var author: String? { metadata.author }
        var homepage: String? { metadata.homepage }
        var script: String? { metadata.script }
        var sourceURL: String? { metadata.sourceURL }
        var url: String? { metadata.url }
    }

    private func decodeExport(_ raw: String, sourceURL: String?) -> Source? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "\u{FEFF}" { text.removeFirst() }

        var candidates = [text]
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"), start < end {
            let object = String(text[start...end])
            if object != text { candidates.append(object) }
        }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            let decoder = JSONDecoder()
            if let value = try? decoder.decode(Export.self, from: data),
               let source = makeSource(from: value, sourceURL: sourceURL) {
                return source
            }
            if let values = try? decoder.decode([Export].self, from: data),
               let value = values.first(where: { $0.script != nil || $0.info?.script != nil }),
               let source = makeSource(from: value, sourceURL: sourceURL) {
                return source
            }
        }
        return nil
    }

    private func makeSource(from value: Export, sourceURL: String?) -> Source? {
        let metadata = value.info
        guard let script = value.script ?? metadata?.script,
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        func firstNonEmpty(_ values: [String?]) -> String? {
            values.first { value in
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? nil
        }

        return Source(
            id: firstNonEmpty([value.id, metadata?.id]) ?? UUID().uuidString,
            name: firstNonEmpty([value.name, metadata?.name]) ?? "LX 音源",
            description: firstNonEmpty([value.description, value.desc, metadata?.description, metadata?.desc]) ?? "",
            version: normalizeVersion(firstNonEmpty([value.version, metadata?.version])),
            author: firstNonEmpty([value.author, metadata?.author]) ?? "",
            homepage: firstNonEmpty([value.homepage, metadata?.homepage]) ?? "",
            script: script,
            sourceURL: sourceURL ?? firstNonEmpty([value.sourceURL, value.url, metadata?.sourceURL, metadata?.url])
        )
    }

    private func normalizeVersion(_ value: String?) -> String {
        guard var result = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else { return "" }
        while result.first == ":" || result.first == "=" {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private func sourceFromHeader(_ raw: String, suggestedName: String, sourceURL: String?) -> Source {
        func value(_ key: String) -> String {
            for line in raw.components(separatedBy: .newlines) {
                guard let range = line.range(of: "@\(key)", options: .caseInsensitive) else { continue }
                let suffix = line[range.upperBound...]
                if let first = suffix.first,
                   !first.isWhitespace, first != ":", first != "=" {
                    continue
                }
                var result = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.first == ":" || result.first == "=" {
                    result.removeFirst()
                    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !result.isEmpty { return normalizeVersion(result) }
            }
            return ""
        }

        let name = value("name")
        let fallbackName = suggestedName.replacingOccurrences(
            of: ".js", with: "", options: .caseInsensitive
        )
        return Source(
            id: UUID().uuidString,
            name: name.isEmpty ? fallbackName : name,
            description: value("description"),
            version: value("version"),
            author: value("author"),
            homepage: value("homepage"),
            script: raw,
            sourceURL: sourceURL
        )
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
