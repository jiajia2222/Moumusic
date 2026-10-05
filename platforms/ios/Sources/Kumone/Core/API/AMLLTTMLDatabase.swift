import Foundation

/// Community, hand-timed word-by-word lyrics: github.com/amll-dev/amll-ttml-db (CC0). Every entry was timed by a person
/// against the real recording, so it is the one lyric source that does not drift with the platform or the cut.
/// The repository keeps one folder per platform (`ncm-lyrics`, `qq-lyrics`) with files named by song id and generated in
/// several formats; `.yrc` is the one the app already parses.
actor AMLLTTMLDatabase {
    static let shared = AMLLTTMLDatabase()

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "moumusic.lyrics.communityDB") as? Bool ?? true
    }

    private let mirrors = [
        "https://cdn.jsdelivr.net/gh/amll-dev/amll-ttml-db@main",
        "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main",
    ]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    /// folder -> (any known song id -> file id)
    private var indexes: [String: [String: String]] = [:]
    private var loading: [String: Task<[String: String], Never>] = [:]

    /// The community lyrics of a song, when the database has them. `neteaseID` / `qqIDs` are the song's own ids on those
    /// platforms (a QQ song has a numeric id and a "mid"; the index knows both).
    func lyrics(neteaseID: String?, qqIDs: [String]) async -> ParsedLyrics? {
        var candidates: [(folder: String, ids: [String])] = []
        if let neteaseID, !neteaseID.isEmpty { candidates.append(("ncm-lyrics", [neteaseID])) }
        let qq = qqIDs.filter { !$0.isEmpty }
        if !qq.isEmpty { candidates.append(("qq-lyrics", qq)) }
        for candidate in candidates {
            guard let index = await readyIndex(folder: candidate.folder, wait: 0) else { continue }
            guard let fileID = candidate.ids.lazy.compactMap({ index[$0] }).first else { continue }
            guard let body = await fetch(path: "\(candidate.folder)/\(fileID).yrc"), !body.isEmpty else { continue }
            var parsed = LyricsParser.parseLX(lyric: "", yrc: body)
            parsed.lines = Self.repairingZeroTimedWords(parsed.lines)
            if parsed.hasVerbatimTimings {
                Task { @MainActor in
                    DiagnosticLogStore.shared.append(level: .info, category: "歌词", message: "使用社区逐字歌词库（AMLL TTML DB）",
                                                     detail: "\(candidate.folder)/\(fileID) · \(parsed.lines.count) 行")
                }
                return parsed
            }
        }
        return nil
    }

    // MARK: Index

    /// Starts loading both indexes in the background (no-op when they are loaded or loading).
    func prefetch() {
        for folder in ["ncm-lyrics", "qq-lyrics"] where indexes[folder] == nil && loading[folder] == nil {
            let task = Task { await self.loadIndex(folder: folder) }
            loading[folder] = task
            Task {
                let map = await task.value
                self.finishLoading(folder: folder, map: map)
            }
        }
    }

    private func finishLoading(folder: String, map: [String: String]) {
        loading[folder] = nil
        if !map.isEmpty { indexes[folder] = map }
    }

    /// The id index of a folder; nil when it could not be loaded within `wait` seconds (loading continues in the
    /// background, so the next song finds it ready).
    private func readyIndex(folder: String, wait: Double) async -> [String: String]? {
        if let index = indexes[folder] { return index }
        prefetch()
        guard wait > 0, let task = loading[folder] else { return nil }
        let result: [String: String]? = await withTaskGroup(of: [String: String]?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let result, !result.isEmpty { return result }
        return nil
    }

    private func loadIndex(folder: String) async -> [String: String] {
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("amll-ttml-index-\(folder).json")
        if let cacheURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 6 * 3600,
           let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([String: String].self, from: data), !cached.isEmpty {
            return cached
        }
        guard let body = await fetch(path: "\(folder)/index.jsonl") else { return [:] }
        // Every line: {"id": file id, "metadata": [[key, [values]], ...]}. The song ids of the platform (ncmMusicId /
        // qqMusicId) all point at the same file, so a song with several ids is found by any of them.
        let platformKey = folder == "ncm-lyrics" ? "ncmMusicId" : "qqMusicId"
        var map: [String: String] = [:]
        for line in body.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fileID = entry["id"] as? String else { continue }
            map[fileID] = fileID
            for pair in (entry["metadata"] as? [[Any]]) ?? [] {
                guard pair.count == 2, (pair[0] as? String) == platformKey, let values = pair[1] as? [String] else { continue }
                for value in values where map[value] == nil { map[value] = fileID }
            }
        }
        if !map.isEmpty, let cacheURL, let data = try? JSONEncoder().encode(map) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return map
    }

    /// Both mirrors are asked at the same time and the first answer wins (one of them is often unreachable from
    /// China), so a blocked host never adds its timeout.
    private func fetch(path: String) async -> String? {
        let session = self.session
        let urls = mirrors.compactMap { URL(string: "\($0)/\(path)") }
        return await withTaskGroup(of: String?.self) { group in
            for url in urls {
                group.addTask {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 8
                    request.setValue("Moumusic", forHTTPHeaderField: "User-Agent")
                    guard let (data, response) = try? await session.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return String(data: data, encoding: .utf8)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    // MARK: Data repair

    /// A few generated files carry words timed `(0,0,0)` in the middle of a line, which would light up at the start of the
    /// song. Place such a word right after the previous one instead.
    nonisolated static func repairingZeroTimedWords(_ lines: [LyricLine]) -> [LyricLine] {
        lines.map { line in
            guard var words = line.words, !words.isEmpty else { return line }
            var cursor = line.time
            for index in words.indices {
                let word = words[index]
                if word.start < line.time - 0.5, word.duration == 0 {
                    words[index] = LyricWord(text: word.text, start: cursor, duration: 0)
                }
                cursor = Swift.max(cursor, words[index].end)
            }
            var repaired = line
            repaired.words = words
            return repaired
        }
    }
}
