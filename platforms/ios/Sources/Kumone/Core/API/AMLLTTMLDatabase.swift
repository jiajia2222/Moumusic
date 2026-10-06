import Foundation

/// Community, hand-timed word-by-word lyrics: github.com/amll-dev/amll-ttml-db (CC0). Every entry was timed by a person
/// against the real recording, so it is the one lyric source that does not drift with the platform or the cut.
/// The repository keeps one folder per source (`ncm-lyrics`, `qq-lyrics`, `am-lyrics`, `spotify-lyrics`) with files named by
/// that source's song id and generated in several formats; `.yrc` is the one the app already parses. Each folder has an
/// `index.jsonl` with the song's name and artists, so a song is also found by name and artist when its id is not there
/// (a song from Kugou, Kuwo or Migu, or one the database keeps under another platform's id).
actor AMLLTTMLDatabase {
    static let shared = AMLLTTMLDatabase()

    /// Off unless the user turns it on (歌词设置): the hand-timed lyrics follow the original recording, which is not always the
    /// cut the music source plays, and then they are off by more than a platform's own lyrics.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "moumusic.lyrics.communityDB") as? Bool ?? false
    }

    /// One song of the database: the file it is in and its normalised names and artists.
    struct Entry: Codable, Hashable {
        let folder: String
        let fileID: String
        let titles: [String]
        let artists: [String]
    }

    private struct CachedFolder: Codable {
        var fetchedAt: Date
        var ids: [String: String]
        var entries: [Entry]
    }

    private struct Candidate {
        let folder: String
        let fileID: String
        /// Found through the song's own platform id (the exact recording) rather than by name.
        let byID: Bool
    }

    private static let folders = ["ncm-lyrics", "qq-lyrics", "am-lyrics", "spotify-lyrics"]
    private let mirrors = [
        "https://cdn.jsdelivr.net/gh/amll-dev/amll-ttml-db@main",
        "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main",
    ]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    /// folder -> (a song id of that platform -> file id); only the NetEase and QQ folders carry platform ids.
    private var idIndexes: [String: [String: String]] = [:]
    /// normalised title -> every entry with that title
    private var byTitle: [String: [Entry]] = [:]
    private var loadedFolders: Set<String> = []
    private var loadingFolders: Set<String> = []

    // MARK: Lookup

    /// The community lyrics of a song, when the database has them. It never waits for the network: the indexes load in the
    /// background (`prefetch`) and a lookup before they are ready simply finds nothing.
    /// - `neteaseID` / `qqIDs`: the song's own ids on those platforms (a QQ song has a numeric id and a "mid").
    /// - `title` / `artists` / `duration`: used when the ids are not in the database; the duration rejects another cut.
    func lyrics(neteaseID: String?, qqIDs: [String], title: String = "", artists: [String] = [],
                duration: TimeInterval = 0) async -> ParsedLyrics? {
        prefetch()
        var candidates: [Candidate] = []
        func add(_ folder: String, _ fileID: String, byID: Bool) {
            guard !candidates.contains(where: { $0.folder == folder && $0.fileID == fileID }) else { return }
            candidates.append(Candidate(folder: folder, fileID: fileID, byID: byID))
        }
        if let neteaseID, let file = idIndexes["ncm-lyrics"]?[neteaseID] { add("ncm-lyrics", file, byID: true) }
        if let file = qqIDs.lazy.compactMap({ self.idIndexes["qq-lyrics"]?[$0] }).first { add("qq-lyrics", file, byID: true) }

        let key = Self.normalize(title)
        let wanted = artists.map(Self.normalize).filter { !$0.isEmpty }
        if key.count >= 2, !wanted.isEmpty, let entries = byTitle[key] {
            let rank = { (folder: String) in Self.folders.firstIndex(of: folder) ?? Self.folders.count }
            for entry in entries.sorted(by: { rank($0.folder) < rank($1.folder) }) where Self.artistsMatch(wanted, entry.artists) {
                add(entry.folder, entry.fileID, byID: false)
            }
        }

        for candidate in candidates.prefix(4) {
            guard let body = await fetch(path: "\(candidate.folder)/\(candidate.fileID).yrc"), !body.isEmpty else { continue }
            var parsed = LyricsParser.parseLX(lyric: "", yrc: body)
            parsed.lines = Self.repairingZeroTimedWords(parsed.lines)
            guard parsed.hasVerbatimTimings else { continue }
            if !candidate.byID, !Self.durationFits(parsed, duration: duration) {
                Task { @MainActor in
                    DiagnosticLogStore.shared.append(level: .info, category: "歌词", message: "社区歌词库的候选被排除（时长对不上）",
                                                     detail: "\(candidate.folder)/\(candidate.fileID) · 歌曲 \(Int(duration)) 秒")
                }
                continue
            }
            Task { @MainActor in
                DiagnosticLogStore.shared.append(
                    level: .info, category: "歌词", message: "使用社区逐字歌词库（AMLL TTML DB）",
                    detail: "\(candidate.folder)/\(candidate.fileID) · \(parsed.lines.count) 行 · \(candidate.byID ? "按歌曲 ID" : "按歌名和歌手")")
            }
            return parsed
        }
        return nil
    }

    // MARK: Matching

    nonisolated static func normalize(_ text: String) -> String {
        var value = text.precomposedStringWithCompatibilityMapping.lowercased()
        // Drop "(feat. …)", "(Live)", "【…】" and the like.
        value = value.replacingOccurrences(of: #"[\(\（\[【][^\)\）\]】]*[\)\）\]】]"#, with: "", options: .regularExpression)
        return String(String.UnicodeScalarView(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    nonisolated static func artistsMatch(_ wanted: [String], _ have: [String]) -> Bool {
        for a in wanted {
            for b in have where !b.isEmpty {
                if a == b { return true }
                if min(a.count, b.count) >= 2, a.contains(b) || b.contains(a) { return true }
            }
        }
        return false
    }

    /// A lyric whose last word ends long after the song, or far before it, belongs to another cut of the song.
    nonisolated static func durationFits(_ lyrics: ParsedLyrics, duration: TimeInterval) -> Bool {
        guard duration > 0, let last = lyrics.lines.compactMap({ $0.words?.last?.end }).max() else { return true }
        return last <= duration + 6 && last >= duration * 0.55
    }

    // MARK: Indexes

    /// Starts loading the indexes in the background (no-op for the ones loaded or loading).
    func prefetch() {
        for folder in Self.folders where !loadedFolders.contains(folder) && !loadingFolders.contains(folder) {
            loadingFolders.insert(folder)
            Task { await self.load(folder: folder) }
        }
    }

    private func load(folder: String) async {
        defer { loadingFolders.remove(folder) }
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("amll-ttml-index2-\(folder).json")
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CachedFolder.self, from: data),
           Date().timeIntervalSince(cached.fetchedAt) < 24 * 3600, !cached.entries.isEmpty {
            ingest(folder: folder, cached)
            return
        }
        guard let body = await fetch(path: "\(folder)/index.jsonl", timeout: 40) else { return }
        let parsed = Self.parseIndex(body, folder: folder)
        guard !parsed.entries.isEmpty else { return }
        if let cacheURL, let data = try? JSONEncoder().encode(parsed) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        ingest(folder: folder, parsed)
    }

    private func ingest(folder: String, _ data: CachedFolder) {
        idIndexes[folder] = data.ids
        for entry in data.entries {
            for title in entry.titles { byTitle[title, default: []].append(entry) }
        }
        loadedFolders.insert(folder)
    }

    /// Every line: {"id": file id, "metadata": [[key, [values]], ...]}. The song ids of a platform (ncmMusicId / qqMusicId)
    /// all point at the same file, so a song with several ids is found by any of them.
    private nonisolated static func parseIndex(_ body: String, folder: String) -> CachedFolder {
        let platformKey = folder == "ncm-lyrics" ? "ncmMusicId" : (folder == "qq-lyrics" ? "qqMusicId" : nil)
        var ids: [String: String] = [:]
        var entries: [Entry] = []
        for line in body.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fileID = object["id"] as? String else { continue }
            var titles: [String] = []
            var artists: [String] = []
            for pair in (object["metadata"] as? [[Any]]) ?? [] {
                guard pair.count == 2, let key = pair[0] as? String, let values = pair[1] as? [String] else { continue }
                switch key {
                case "musicName": titles = values.map(normalize).filter { $0.count >= 2 }
                case "artists": artists = values.map(normalize).filter { !$0.isEmpty }
                default:
                    if key == platformKey { for value in values where ids[value] == nil { ids[value] = fileID } }
                }
            }
            if platformKey != nil { ids[fileID] = fileID }
            if !titles.isEmpty { entries.append(Entry(folder: folder, fileID: fileID, titles: Array(Set(titles)), artists: artists)) }
        }
        return CachedFolder(fetchedAt: Date(), ids: ids, entries: entries)
    }

    /// Both mirrors are asked at the same time and the first answer wins (one of them is often unreachable from
    /// China), so a blocked host never adds its timeout.
    private func fetch(path: String, timeout: TimeInterval = 10) async -> String? {
        let session = self.session
        let urls = mirrors.compactMap { URL(string: "\($0)/\(path)") }
        return await withTaskGroup(of: String?.self) { group in
            for url in urls {
                group.addTask {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = timeout
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
