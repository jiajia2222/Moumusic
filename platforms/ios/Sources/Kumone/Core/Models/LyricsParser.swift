import Foundation

/// One timed word (or short run) inside a verbatim (yrc) lyric line.
struct LyricWord: Hashable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
    var end: TimeInterval { start + duration }
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    let text: String
    var translation: String?
    var romaji: String?
    /// Per-word timings for karaoke highlighting; nil when only line-level
    /// (lrc) timing is available.
    var words: [LyricWord]?
}

struct ParsedLyrics: Hashable {
    var lines: [LyricLine] = []
    var isInstrumental = false
    var contributor: String?
    var translationContributor: String?

    var isEmpty: Bool { lines.isEmpty }

    /// Index of the active line for a playback position.
    func activeIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0, high = lines.count - 1, result: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

enum LyricsParser {
    /// Parses the common LX User API lyric payload without forcing it through
    /// NetEase's response model.  LX sources may return translated or romaji
    /// lines alongside the main LRC body.
    static func parseLX(lyric: String, tlyric: String? = nil,
                        rlyric: String? = nil, lxlyric: String? = nil,
                        yrc: String? = nil) -> ParsedLyrics {
        var result = ParsedLyrics()
        let timedMain = parseLRC(lyric).filter { !$0.text.isEmpty }
        let main = timedMain.isEmpty ? parsePlainText(lyric) : timedMain
        var lines = main.enumerated().map { index, line in
            LyricLine(id: index, time: line.time, text: line.text)
        }

        // Some LX sources expose NetEase-style verbatim lyrics in a separate
        // `yrc` field. Prefer those exact word/run timings over line-level LRC.
        let verbatimLines = parseYRC(yrc ?? lxlyric ?? lyric)
        if !verbatimLines.isEmpty { lines = verbatimLines }

        func merge(_ body: String?, into keyPath: WritableKeyPath<LyricLine, String?>) {
            guard let body, !body.isEmpty else { return }
            let secondary = parseLRC(body).filter { !$0.text.isEmpty }
            for index in lines.indices {
                guard let nearest = secondary.min(by: {
                    abs($0.time - lines[index].time) < abs($1.time - lines[index].time)
                }), abs(nearest.time - lines[index].time) < 0.3 else { continue }
                lines[index][keyPath: keyPath] = nearest.text
            }
        }

        merge(tlyric, into: \.translation)
        merge(rlyric ?? lxlyric, into: \.romaji)
        result.lines = lines
        return result
    }

    /// LX source scripts are not completely consistent: most return LRC,
    /// while some return escaped newlines or an un-timestamped lyric body.
    /// Normalize those forms before parsing so the UI never silently receives
    /// an empty `ParsedLyrics` just because the source omitted LRC timestamps.
    private static func parsePlainText(_ body: String) -> [(time: TimeInterval, text: String)] {
        let normalized = normalize(body)
        guard !normalized.isEmpty else { return [] }
        return normalized.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                // Drop LRC metadata such as [ar:…] when a source has mixed
                // metadata and plain text, but keep ordinary lyric text.
                !(line.hasPrefix("[") && line.contains("]"))
            }
            .enumerated()
            .map { index, text in (Double(index) * 0.01, text) }
    }

    private static func normalize(_ body: String) -> String {
        body
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
            .replacingOccurrences(of: "\\uFEFF", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
    }

    /// Parses an LRC body into (time, text) pairs. Handles multiple timestamps
    /// per line and both `.` / `:` millisecond separators.
    static func parseLRC(_ lrc: String) -> [(time: TimeInterval, text: String)] {
        var result: [(TimeInterval, String)] = []
        var offset = 0.0
        let timeTag = #/\[(\d+):(\d+)(?:[.:](\d+))?\]/#

        for rawLine in normalize(lrc).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.lowercased().hasPrefix("[offset:"),
               let end = line.firstIndex(of: "]"),
               let milliseconds = Double(line[line.index(line.startIndex, offsetBy: 8)..<end]) {
                offset = milliseconds / 1000
                continue
            }
            let matches = line.matches(of: timeTag)
            guard !matches.isEmpty else { continue }
            guard let lastMatch = matches.last else { continue }
            let content = String(line[lastMatch.range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            for match in matches {
                let min = Double(match.output.1) ?? 0
                let sec = Double(match.output.2) ?? 0
                var frac = 0.0
                if let msStr = match.output.3, let ms = Double(msStr) {
                    frac = ms / pow(10, Double(msStr.count))
                }
                result.append((min * 60 + sec + frac + offset, content))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Parses NetEase verbatim `yrc` lyrics: each content line is
    /// `[lineStartMs,lineDurMs](wStartMs,wDurMs,0)word(...)word…`. JSON metadata
    /// (credits) lines at the top don't match the `[num,num]` head and are
    /// skipped.
    static func parseYRC(_ yrc: String) -> [LyricLine] {
        let lineTag = #/^\[(\d+),(\d+)\]/#
        let wordTag = #/\((\d+),(\d+),\d+\)([^(]*)/#
        var lines: [LyricLine] = []
        var idx = 0
        for raw in yrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let head = line.firstMatch(of: lineTag) else { continue }
            let lineStart = (Double(head.output.1) ?? 0) / 1000
            var words: [LyricWord] = []
            var text = ""
            for w in line.matches(of: wordTag) {
                let start = (Double(w.output.1) ?? 0) / 1000
                let duration = (Double(w.output.2) ?? 0) / 1000
                let piece = String(w.output.3)
                words.append(LyricWord(text: piece, start: start, duration: duration))
                text += piece
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !words.isEmpty else { continue }
            lines.append(LyricLine(id: idx, time: lineStart, text: trimmed, words: words))
            idx += 1
        }
        return lines
    }

    static func parse(_ response: LyricResponse) -> ParsedLyrics {
        var out = ParsedLyrics()
        out.contributor = response.lyricUser?.nickname
        out.translationContributor = response.transUser?.nickname

        let lrcRaw = response.lrc?.lyric
        let yrcRaw = response.yrc?.lyric
        guard [lrcRaw, yrcRaw]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .contains(where: { !$0.isEmpty }) else { return out }
        var main = lrcRaw.map(parseLRC) ?? []

        // Instrumental marker handling (mirrors YesPlayMusic).
        let instrumentalMarker = "纯音乐，请欣赏"
        if main.count <= 10, main.contains(where: { $0.text.contains(instrumentalMarker) }) {
            out.isInstrumental = true
            main.removeAll { line in
                line.text.contains(instrumentalMarker)
                    || line.text.range(of: #"^作(词|曲)\s*[:：]"#, options: .regularExpression) != nil
            }
            if main.isEmpty {
                return out
            }
        }
        main.removeAll { $0.text.range(of: #"^作(词|曲)\s*[:：]\s*无$"#, options: .regularExpression) != nil }

        var lines = main.enumerated().map { idx, pair in
            LyricLine(id: idx, time: pair.time, text: pair.text)
        }
        // Prefer verbatim (word-by-word) lines when the song has them.
        if let yrcRaw, !yrcRaw.isEmpty {
            let yrcLines = parseYRC(yrcRaw)
            if !yrcLines.isEmpty { lines = yrcLines }
        }

        func merge(_ body: String?, into keyPath: WritableKeyPath<LyricLine, String?>) {
            guard let body, !body.isEmpty else { return }
            let secondary = parseLRC(body).filter { !$0.text.isEmpty }
            guard !secondary.isEmpty else { return }
            for i in lines.indices {
                // Nearest secondary line within 0.3s: verbatim (yrc) line times
                // can differ from the lrc-based translation/romaji by a few ms.
                var best: (delta: TimeInterval, text: String)?
                for (time, text) in secondary {
                    let delta = abs(time - lines[i].time)
                    if best == nil || delta < best!.delta { best = (delta, text) }
                }
                if let best, best.delta < 0.3 {
                    lines[i][keyPath: keyPath] = best.text
                }
            }
        }

        merge(response.ytlrc?.lyric ?? response.tlyric?.lyric, into: \.translation)
        merge(response.yromalrc?.lyric ?? response.romalrc?.lyric, into: \.romaji)

        // Romaji is only meaningful for Japanese lyrics: fill the gaps Netease
        // left, and drop stray annotations on everything else.
        if RomajiTranscriber.isJapanese(lines.map(\.text)) {
            for i in lines.indices where lines[i].romaji == nil {
                lines[i].romaji = RomajiTranscriber.transcribe(lines[i].text)
            }
        } else {
            for i in lines.indices {
                lines[i].romaji = nil
            }
        }

        out.lines = lines
        return out
    }
}
