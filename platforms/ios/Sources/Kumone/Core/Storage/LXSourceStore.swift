#if os(iOS)
import Foundation
import SwiftUI
import UIKit

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
    @Published private(set) var enabledIDs: [String] = []

    var selectedSource: Source? {
        guard let selectedID else { return nil }
        return sources.first { $0.id == selectedID }
    }

    /// Enabled sources in playback priority order. The selected source is
    /// always tried first; the remaining enabled sources are tried in the
    /// order in which the user enabled them.
    var playbackSources: [Source] {
        let preferred = selectedSource.map { [$0] } ?? []
        let rest = enabledIDs.compactMap { id in
            sources.first { $0.id == id && $0.id != selectedID }
        }
        return preferred + rest
    }

    private static let selectedKey = "lx.selectedSource"
    private static let enabledKey = "lx.enabledSources"

    private init() {
        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey)
        let data = try? Data(contentsOf: Self.fileURL)
        sources = (data.flatMap { try? JSONDecoder().decode([Source].self, from: $0) }) ?? []
        if selectedID != nil, selectedSource == nil {
            selectedID = sources.first?.id
        }

        let storedEnabled = UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? []
        enabledIDs = storedEnabled.filter { id in sources.contains { $0.id == id } }
        if enabledIDs.isEmpty {
            enabledIDs = selectedID.map { [$0] } ?? sources.first.map { [$0.id] } ?? []
        }
        if let selectedID, !enabledIDs.contains(selectedID) {
            enabledIDs.insert(selectedID, at: 0)
        }
        if selectedID == nil {
            selectedID = enabledIDs.first
        }
        persistEnabled()
    }

    func importScript(_ data: Data, suggestedName: String, sourceURL: String? = nil) throws {
        guard let raw = decodeText(data),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.invalidEncoding
        }

        let source = decodeExport(raw, suggestedName: suggestedName, sourceURL: sourceURL)
            ?? sourceFromHeader(raw, suggestedName: suggestedName, sourceURL: sourceURL)
        guard isLXScript(source.script) else {
            throw ImportError.invalidScript
        }

        let replacedIDs = Set(sources.filter { $0.id == source.id || $0.name == source.name }.map(\.id))
        sources.removeAll { replacedIDs.contains($0.id) }
        enabledIDs.removeAll { replacedIDs.contains($0) }
        sources.append(source)
        sources.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !enabledIDs.contains(source.id) {
            enabledIDs.append(source.id)
        }
        // Importing is an explicit user action. Make the imported source the
        // preferred source immediately, instead of leaving the user on an old
        // source and making a successful import look like it did nothing.
        selectedID = source.id
        UserDefaults.standard.set(source.id, forKey: Self.selectedKey)
        persist()
        LXUserAPIService.shared.loadSelectedSource()
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
        request.setValue("text/plain, application/json, application/javascript, */*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ImportError.downloadFailed
        }
        guard data.count <= 16_000_000 else { throw ImportError.tooLarge }

        let suggestedName = url.deletingPathExtension().lastPathComponent.isEmpty
            ? (url.host ?? "LX 音源")
            : url.deletingPathExtension().lastPathComponent
        try importScript(data, suggestedName: suggestedName, sourceURL: url.absoluteString)
    }

    func select(_ id: String?) {
        guard id == nil || sources.contains(where: { $0.id == id }) else { return }
        // The iOS 26 search tab owns a native search field. Resigning it here
        // prevents a source tap in Settings from moving focus back to Search.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        if let id, !enabledIDs.contains(id) {
            enabledIDs.insert(id, at: 0)
        }
        selectedID = id
        if let id {
            UserDefaults.standard.set(id, forKey: Self.selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedKey)
        }
        persistEnabled()
        LXUserAPIService.shared.loadSelectedSource()
    }

    func isEnabled(_ id: String) -> Bool {
        enabledIDs.contains(id)
    }

    /// Enables or disables a source without changing the preferred source.
    /// Keep at least one source enabled so playback cannot silently fall back
    /// to a source the user turned off.
    func setEnabled(_ id: String, enabled: Bool) {
        guard sources.contains(where: { $0.id == id }) else { return }
        if enabled {
            guard !enabledIDs.contains(id) else { return }
            enabledIDs.append(id)
        } else {
            guard enabledIDs.count > 1 else { return }
            enabledIDs.removeAll { $0 == id }
            if selectedID == id {
                selectedID = enabledIDs.first
                if let selectedID {
                    UserDefaults.standard.set(selectedID, forKey: Self.selectedKey)
                }
            }
        }
        persistEnabled()
        if selectedID == id || !enabled {
            LXUserAPIService.shared.loadSelectedSource()
        }
    }

    func remove(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        enabledIDs.removeAll { $0 == source.id }
        if selectedID == source.id {
            selectedID = enabledIDs.first ?? sources.first?.id
        }
        if let selectedID, !enabledIDs.contains(selectedID) {
            enabledIDs.insert(selectedID, at: 0)
        }
        if enabledIDs.isEmpty, let selectedID {
            enabledIDs = [selectedID]
        }
        persist()
        if let selectedID {
            UserDefaults.standard.set(selectedID, forKey: Self.selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedKey)
        }
        persistEnabled()
        LXUserAPIService.shared.loadSelectedSource()
    }

    enum ImportError: LocalizedError {
        case readFailed
        case invalidEncoding
        case invalidScript
        case invalidURL
        case downloadFailed
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .readFailed: return "无法读取所选文件，请先将文件下载到“文件”App后重试"
            case .invalidEncoding: return "无法读取音源文件，请选择 LX 导出的 .js、.json 或纯文本文件"
            case .invalidScript: return "这不是可识别的 LX User API 音源"
            case .invalidURL: return "请输入有效的 HTTP 或 HTTPS 音源链接"
            case .downloadFailed: return "音源下载失败，请检查链接和网络"
            case .tooLarge: return "音源文件超过 16 MB，已拒绝导入"
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

    /// Files shared by LX Mobile are normally UTF-8 JavaScript, but Files.app
    /// and some desktop editors can export the same script as UTF-16. Do not
    /// turn an unknown byte stream into replacement characters: that would
    /// make a damaged file look like a valid script and fail much later in the
    /// JavaScript bridge.
    private func decodeText(_ data: Data) -> String? {
        // LX source files are UTF-8 by contract, but Files.app and desktop
        // editors can add a UTF-16/UTF-32 BOM. The BOM-aware encodings must be
        // tried before the endian-specific fallbacks, otherwise a valid JSON
        // export can be decoded as a string containing NUL characters.
        var encodings: [String.Encoding] = [.utf8, .utf16, .utf32]
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            encodings.insert(.utf32LittleEndian, at: 0)
        } else if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            encodings.insert(.utf32BigEndian, at: 0)
        } else if data.starts(with: [0xFF, 0xFE]) {
            encodings.insert(.utf16LittleEndian, at: 0)
        } else if data.starts(with: [0xFE, 0xFF]) {
            encodings.insert(.utf16BigEndian, at: 0)
        }
        encodings.append(contentsOf: [
            .utf16LittleEndian,
            .utf16BigEndian,
            .utf32LittleEndian,
            .utf32BigEndian,
            .isoLatin1
        ])
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private func decodeExport(
        _ raw: String,
        suggestedName: String,
        sourceURL: String?
    ) -> Source? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "\u{FEFF}" { text.removeFirst() }

        // JSON exports have changed shape across LX versions. Prefer a
        // permissive object walk before the older Decodable model so that
        // wrappers such as {"data": {"script": "..."}} and arrays from
        // desktop exports are accepted as well.
        if let source = decodeJSONExport(
            text,
            suggestedName: suggestedName,
            sourceURL: sourceURL
        ) {
            return source
        }

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
               let source = makeSource(
                from: value,
                suggestedName: suggestedName,
                sourceURL: sourceURL
               ) {
                return source
            }
            if let values = try? decoder.decode([Export].self, from: data),
               let value = values.first(where: { $0.script != nil || $0.info?.script != nil }),
               let source = makeSource(
                from: value,
                suggestedName: suggestedName,
                sourceURL: sourceURL
               ) {
                return source
            }
        }
        return nil
    }

    private func makeSource(
        from value: Export,
        suggestedName: String,
        sourceURL: String?
    ) -> Source? {
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
            name: firstNonEmpty([value.name, metadata?.name]) ?? suggestedName,
            description: firstNonEmpty([value.description, value.desc, metadata?.description, metadata?.desc]) ?? "",
            version: normalizeVersion(firstNonEmpty([value.version, metadata?.version])),
            author: firstNonEmpty([value.author, metadata?.author]) ?? "",
            homepage: firstNonEmpty([value.homepage, metadata?.homepage]) ?? "",
            script: script,
            sourceURL: sourceURL ?? firstNonEmpty([value.sourceURL, value.url, metadata?.sourceURL, metadata?.url])
        )
    }

    private func decodeJSONExport(
        _ text: String,
        suggestedName: String,
        sourceURL: String?
    ) -> Source? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return sourceFromJSONValue(
            object,
            suggestedName: suggestedName,
            sourceURL: sourceURL
        )
    }

    private func sourceFromJSONValue(
        _ value: Any,
        suggestedName: String,
        sourceURL: String?
    ) -> Source? {
        // Some LX backup/export tools wrap the source JSON one more time as a
        // JSON string, for example {"data":"{\"script\":\"...\"}"}.
        // Unwrap that string before walking the object so local exports from
        // both desktop and mobile LX can be imported.
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isLXScript(trimmed) {
                return Source(
                    id: UUID().uuidString,
                    name: suggestedName,
                    description: "",
                    version: "",
                    author: "",
                    homepage: "",
                    script: trimmed,
                    sourceURL: sourceURL
                )
            }
            if let data = trimmed.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: data) {
                return sourceFromJSONValue(
                    nested,
                    suggestedName: suggestedName,
                    sourceURL: sourceURL
                )
            }
            return nil
        }

        if let values = value as? [Any] {
            for item in values {
                if let source = sourceFromJSONValue(
                    item,
                    suggestedName: suggestedName,
                    sourceURL: sourceURL
                ) {
                    return source
                }
            }
            return nil
        }

        guard let dictionary = value as? [String: Any] else { return nil }

        let scriptKeys = [
            "script", "source", "sourceCode", "code", "content",
            "javascript", "js", "userApi", "userAPI", "lxUserAPI", "api"
        ]
        for key in scriptKeys {
            guard let scriptValue = valueForKey(key, in: dictionary),
                  let script = jsonString(scriptValue),
                  isLXScript(script) else { continue }

            return Source(
                id: jsonString(valueForKeys(["id", "sourceId", "key"], in: dictionary))
                    ?? UUID().uuidString,
                name: jsonString(valueForKeys(["name", "title"], in: dictionary))
                    ?? suggestedName,
                description: jsonString(valueForKeys(["description", "desc"], in: dictionary))
                    ?? "",
                version: normalizeVersion(
                    jsonString(valueForKeys(["version", "ver", "sourceVersion"], in: dictionary))
                ),
                author: jsonString(valueForKeys(["author", "creator"], in: dictionary))
                    ?? "",
                homepage: jsonString(valueForKeys(["homepage", "homePage"], in: dictionary))
                    ?? "",
                script: script,
                sourceURL: sourceURL ?? jsonString(
                    valueForKeys(["sourceURL", "sourceUrl", "url"], in: dictionary)
                )
            )
        }

        // Search known wrapper fields first, then any remaining nested value.
        // The latter keeps imports compatible with future LX export wrappers.
        let preferredKeys = ["data", "result", "value", "source", "info", "metadata"]
        let orderedValues = preferredKeys.compactMap { valueForKey($0, in: dictionary) }
            + dictionary
                .filter { pair in !preferredKeys.contains(where: { $0.caseInsensitiveCompare(pair.key) == .orderedSame }) }
                .map { $0.value }
        for nested in orderedValues {
            if let source = sourceFromJSONValue(
                nested,
                suggestedName: suggestedName,
                sourceURL: sourceURL
            ) {
                return source
            }
        }
        return nil
    }

    private func valueForKey(_ key: String, in dictionary: [String: Any]) -> Any? {
        dictionary.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    private func valueForKeys(_ keys: [String], in dictionary: [String: Any]) -> Any? {
        keys.compactMap { valueForKey($0, in: dictionary) }.first
    }

    private func jsonString(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            let doubleValue = number.doubleValue
            return doubleValue.rounded() == doubleValue
                ? String(Int(doubleValue))
                : String(doubleValue)
        }
        return nil
    }

    private func isLXScript(_ script: String) -> Bool {
        let value = script.lowercased()
        return value.contains("musicurl")
            || value.contains("music_url")
            || value.contains("globalthis.lx")
            || value.contains("lyric")
            || value.contains("getlyric")
            || value.contains("event_names")
            || value.contains("send(event_names")
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
        persistEnabled()
    }

    private func persistEnabled() {
        UserDefaults.standard.set(enabledIDs, forKey: Self.enabledKey)
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
