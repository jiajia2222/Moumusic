import Foundation

/// One timed word (or short run) inside a verbatim (yrc) lyric line.
struct LyricWord: Hashable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
    var end: TimeInterval { start + duration }
}

extension LyricWord {
    /// Words as sources deliver them carry spaces at the line edges; the plain line text is trimmed, so the two
    /// layers of a karaoke line would sit a space apart. Drop the edge whitespace (and words that were only that).
    static func trimmingEnds(_ words: [LyricWord]) -> [LyricWord] {
        var output = words
        if let first = output.first {
            output[0] = LyricWord(text: String(first.text.drop { $0.isWhitespace }), start: first.start, duration: first.duration)
        }
        if let last = output.last {
            var text = last.text
            while let tail = text.last, tail.isWhitespace { text.removeLast() }
            output[output.count - 1] = LyricWord(text: text, start: last.start, duration: last.duration)
        }
        return output.filter { !$0.text.isEmpty }
    }

    /// How much of the word has been sung at `time` (0...1). A word without a duration switches at its start.
    func sungFraction(at time: TimeInterval) -> Double {
        duration > 0 ? min(max((time - start) / duration, 0), 1) : (time >= start ? 1 : 0)
    }
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    let text: String
    var translation: String?
    var romaji: String?
    /// Optional Japanese reading segments populated from the system tokenizer.
    /// It stays nil for Latin, kana-only, and non-Japanese lines.
    var furigana: [RubySegment]?
    /// Per-word timings for karaoke highlighting; nil when only line-level
    /// (lrc) timing is available.
    var words: [LyricWord]?

    /// A provider can include a `words` array without actually providing a
    /// usable time axis (for example, one zero-duration item for the whole
    /// line).  Treat that as ordinary LRC so AMLL never animates fabricated
    /// karaoke timings.
    var hasVerbatimTimings: Bool {
        guard let words, !words.isEmpty else { return false }
        return words.contains { word in
            word.duration > 0 || abs(word.start - time) > 0.001
        }
    }
}

struct ParsedLyrics: Hashable {
    var lines: [LyricLine] = []
    var isInstrumental = false
    var contributor: String?
    var translationContributor: String?

    var isEmpty: Bool { lines.isEmpty }

    /// When the lyrics end: the end of the last word, or the start of the last line when it is only line-timed.
    var endTime: TimeInterval {
        lines.map { $0.words?.last?.end ?? $0.time }.max() ?? 0
    }

    /// Whether the provider supplied a real word/run time axis (YRC/KRC/
    /// LX verbatim).  A line-timed LRC must not be presented as word-timed
    /// karaoke: inventing timings makes short songs drift noticeably.
    var hasVerbatimTimings: Bool {
        lines.contains { $0.hasVerbatimTimings }
    }

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
        let verbatimLines = [
            parseYRC(yrc),
            parseLXVerbatim(lxlyric),
            parseLXVerbatim(yrc),
            parseYRC(lxlyric),
            parseLXVerbatim(lyric),
            parseYRC(lyric),
        ].first(where: { !$0.isEmpty }) ?? []
        if !verbatimLines.isEmpty { lines = verbatimLines }

        func merge(_ body: String?, into keyPath: WritableKeyPath<LyricLine, String?>) {
            guard let body, !body.isEmpty else { return }
            let secondary = parseLRC(body).filter { !$0.text.isEmpty }
            // Every translated line goes to the one main line nearest to it (within 0.3 s). Looking from the main lines
            // instead gave the credits at the start of a song (0.0 - 0.4 s) the translation of the first sung line too.
            var assigned: [Int: (delta: TimeInterval, text: String)] = [:]
            for second in secondary {
                // Credit lines ("编曲: …") are never translated: a translation whose nearest line is a credit goes to the
                // nearest sung line instead.
                guard let index = lines.indices.filter({ !isCreditText(lines[$0].text) }).min(by: {
                    abs(lines[$0].time - second.time) < abs(lines[$1].time - second.time)
                }) else { continue }
                let delta = abs(lines[index].time - second.time)
                guard delta < 0.3 else { continue }
                if assigned[index] == nil || delta < assigned[index]!.delta { assigned[index] = (delta, second.text) }
            }
            for (index, value) in assigned { lines[index][keyPath: keyPath] = value.text }
        }

        merge(tlyric, into: \.translation)
        // `lxlyric` is usually the source's word-timed main lyric, not a
        // romanization payload. Treating it as romaji makes the translation
        // row show a second, Japanese-looking copy of the original lyric.
        merge(rlyric, into: \.romaji)
        for index in lines.indices {
            lines[index].translation = sanitizedSecondaryText(
                lines[index].translation,
                main: lines[index].text
            )
        }
        lines = spreadTranslations(lines)
        lines = addFurigana(to: lines)
        result.lines = lines
        return result
    }

    /// Some platforms translate two original lines as one ("I was a functioning alcoholic / Till nobody noticed my new
    /// aesthetic" → one Chinese line), while another platform's timing splits them in two: the second line is then left
    /// without a translation. When the Chinese line is written in parts (separated by spaces), the parts are shared out over
    /// the lines, cutting where the share of Chinese characters is closest to the share of the original text.
    static func isCreditText(_ text: String) -> Bool {
        text.range(of: #"^\s*(作词|作曲|编曲|词|曲|制作人|制作|监制|混音|母带|录音|配唱|和声|演唱|歌手|出品|发行|策划|统筹|吉他|贝斯|鼓|弦乐|原唱|词曲|编写|lyrics|lyricist|composer|arranger|producer|music|words|written by|arranged by|mixed by)\s*[:：]"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func spreadTranslations(_ input: [LyricLine]) -> [LyricLine] {
        var lines = input
        func isCredit(_ text: String) -> Bool {
            isCreditText(text)
        }
        func weight(_ text: String) -> Int { text.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }.count }
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            guard let translation = lines[index].translation, !translation.isEmpty,
                  weight(lines[index].text) >= 8, !isCredit(lines[index].text) else { continue }
            var group = [index]
            var next = index + 1
            while next < lines.count, group.count < 3, lines[next].translation == nil,
                  weight(lines[next].text) >= 8, !isCredit(lines[next].text),
                  // "oh oh oh oh" is not a line of its own that a translation was written for.
                  Set(lines[next].text.lowercased().filter { !$0.isWhitespace }).count >= 7,
                  lines[next].time - lines[group.last!].time < 15 {
                group.append(next)
                next += 1
            }
            guard group.count >= 2 else { continue }
            let parts = translation.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" }).map(String.init)
            guard parts.count >= group.count else { continue }
            let partWeights = parts.map { weight($0) }
            let totalParts = Double(partWeights.reduce(0, +))
            let lineWeights = group.map { weight(lines[$0].text) }
            let totalLines = Double(lineWeights.reduce(0, +))
            guard totalParts > 0, totalLines > 0 else { continue }
            // Cut points: the number of parts that go to the first line, to the first two lines, ...
            func cost(_ cuts: [Int]) -> Double {
                var total = 0.0
                var cumLines = 0.0
                for (k, cut) in cuts.enumerated() {
                    cumLines += Double(lineWeights[k])
                    let cumParts = Double(partWeights[0..<cut].reduce(0, +))
                    total += abs(cumParts / totalParts - cumLines / totalLines)
                }
                return total
            }
            var best: [Int]?
            var bestCost = Double.infinity
            if group.count == 2 {
                for a in 1..<parts.count { let c = cost([a]); if c < bestCost { bestCost = c; best = [a] } }
            } else {
                for a in 1..<(parts.count - 1) {
                    for b in (a + 1)..<parts.count {
                        let c = cost([a, b])
                        if c < bestCost { bestCost = c; best = [a, b] }
                    }
                }
            }
            guard let cuts = best else { continue }
            var start = 0
            for (k, lineIndex) in group.enumerated() {
                let end = k < cuts.count ? cuts[k] : parts.count
                lines[lineIndex].translation = parts[start..<end].joined(separator: " ")
                start = end
            }
            index = group.last!
        }
        return lines
    }

    /// LX source scripts are not completely consistent: most return LRC,
    /// while some return escaped newlines or an un-timestamped lyric body.
    /// Normalize those forms before parsing so the UI never silently receives
    /// an empty `ParsedLyrics` just because the source omitted LRC timestamps.
    /// NetEase prefixes verbatim lyrics with JSON credit lines such as
    /// `{"t":0,"c":[{"tx":"作词: "},{"tx":"某人","li":"http://…","or":"orpheus://…"}]}`; show the
    /// readable credit instead of the raw JSON (and its image / app links).
    static func creditLine(_ line: String) -> (time: TimeInterval, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pieces = object["c"] as? [[String: Any]] else { return nil }
        let text = pieces.compactMap { $0["tx"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let start = ((object["t"] as? NSNumber)?.doubleValue ?? 0) / 1000
        return text.isEmpty ? nil : (start, text)
    }

    private static func parsePlainText(_ body: String) -> [(time: TimeInterval, text: String)] {
        let normalized = normalize(body)
        guard !normalized.isEmpty else { return [] }
        return normalized.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { line -> String? in
                guard line.hasPrefix("{") else { return line }
                return creditLine(line)?.text
            }
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
    static func parseYRC(_ yrc: String?) -> [LyricLine] {
        guard let yrc, !yrc.isEmpty else { return [] }
        let lineTag = #/^\[(\d+),(\d+)\]/#
        let wordTag = #/\((\d+),(\d+),\d+\)/#
        var lines: [LyricLine] = []
        var idx = 0
        for raw in yrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("{"), let credit = creditLine(line) {
                lines.append(LyricLine(id: idx, time: credit.time, text: credit.text))
                idx += 1
                continue
            }
            guard let head = line.firstMatch(of: lineTag) else { continue }
            let lineStart = (Double(head.output.1) ?? 0) / 1000
            let contentStart = head.range.upperBound
            let content = line[contentStart...]
            let matches = content.matches(of: wordTag)
            var words: [LyricWord] = []
            var text = ""
            for (offset, w) in matches.enumerated() {
                let start = (Double(w.output.1) ?? 0) / 1000
                let duration = (Double(w.output.2) ?? 0) / 1000
                let pieceStart = w.range.upperBound
                let pieceEnd = offset + 1 < matches.count
                    ? matches[offset + 1].range.lowerBound
                    : content.endIndex
                let piece = String(content[pieceStart..<pieceEnd])
                words.append(LyricWord(text: piece, start: start, duration: duration))
                text += piece
            }
            words = LyricWord.trimmingEnds(words)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !words.isEmpty else { continue }
            lines.append(LyricLine(id: idx, time: lineStart, text: trimmed, words: words))
            idx += 1
        }
        return lines
    }

    /// Parses LX Music's native `lxlyric` format:
    /// `[00:00.000]<0,36>?<36,36>?<50,60>??`.
    /// Word offsets are relative to the line start, unlike NetEase YRC's
    /// absolute word timestamps.
    static func parseLXVerbatim(_ body: String?) -> [LyricLine] {
        guard let body, !body.isEmpty else { return [] }
        let lineTag = #/^\[(\d+):(\d+)(?:[.:](\d+))?\]/#
        let wordTag = #/<(\d+),(\d+)>/#
        var lines: [LyricLine] = []
        var idx = 0

        for raw in normalize(body).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let head = line.firstMatch(of: lineTag) else { continue }
            let minutes = Double(head.output.1) ?? 0
            let seconds = Double(head.output.2) ?? 0
            let fraction = head.output.3.map { value in
                (Double(value) ?? 0) / pow(10, Double(value.count))
            } ?? 0
            let lineStart = minutes * 60 + seconds + fraction
            let content = line[head.range.upperBound...]
            let matches = content.matches(of: wordTag)
            guard !matches.isEmpty else { continue }

            var words: [LyricWord] = []
            var text = ""
            for (offset, match) in matches.enumerated() {
                let start = lineStart + (Double(match.output.1) ?? 0) / 1000
                let duration = (Double(match.output.2) ?? 0) / 1000
                let pieceStart = match.range.upperBound
                let pieceEnd = offset + 1 < matches.count
                    ? matches[offset + 1].range.lowerBound
                    : content.endIndex
                let piece = String(content[pieceStart..<pieceEnd])
                words.append(LyricWord(text: piece, start: start, duration: duration))
                text += piece
            }

            words = LyricWord.trimmingEnds(words)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !words.isEmpty else { continue }
            lines.append(LyricLine(id: idx, time: lineStart, text: trimmed, words: words))
            idx += 1
        }
        return lines
    }

    static func parse(_ response: LyricResponse, includeVerbatim: Bool = true) -> ParsedLyrics {
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
        if includeVerbatim, let yrcRaw, !yrcRaw.isEmpty {
            let yrcLines = parseYRC(yrcRaw)
            if !yrcLines.isEmpty { lines = yrcLines }
        }

        func merge(_ body: String?, into keyPath: WritableKeyPath<LyricLine, String?>) {
            guard let body, !body.isEmpty else { return }
            let secondary = parseLRC(body).filter { !$0.text.isEmpty }
            guard !secondary.isEmpty else { return }
            // Every translated line goes to the one main line nearest to it (within 0.3 s; verbatim (yrc) line times
            // can differ from the lrc-based translation/romaji by a few ms). Looking from the main lines instead gave
            // the credits at the start of a song the translation of the first sung line too.
            var assigned: [Int: (delta: TimeInterval, text: String)] = [:]
            for (time, text) in secondary {
                var nearest: (index: Int, delta: TimeInterval)?
                for i in lines.indices where !isCreditText(lines[i].text) {
                    let delta = abs(time - lines[i].time)
                    if nearest == nil || delta < nearest!.delta { nearest = (i, delta) }
                }
                guard let nearest, nearest.delta < 0.3 else { continue }
                if assigned[nearest.index] == nil || nearest.delta < assigned[nearest.index]!.delta {
                    assigned[nearest.index] = (nearest.delta, text)
                }
            }
            for (i, value) in assigned { lines[i][keyPath: keyPath] = value.text }
        }

        // Some responses include a partial ytlrc body and a complete tlyric
        // body. Merge both instead of letting the first non-nil field hide
        // translations that exist in the second one.
        merge(response.ytlrc?.lyric, into: \.translation)
        merge(response.tlyric?.lyric, into: \.translation)
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

        for index in lines.indices {
            lines[index].translation = sanitizedSecondaryText(
                lines[index].translation,
                main: lines[index].text
            )
        }

        out.lines = spreadTranslations(lines)
        out.lines = addFurigana(to: out.lines)
        return out
    }

    private static func addFurigana(to input: [LyricLine]) -> [LyricLine] {
        guard !input.isEmpty else { return input }
        var lines = input
        for index in lines.indices where lines[index].furigana == nil {
            lines[index].furigana = Furigana.segments(for: lines[index].text)
        }
        return lines
    }

    /// A few providers put the original lyric (or an annotation body) in
    /// `tlyric`. Do not render it as a translation. Japanese kana is also not
    /// a translation for a non-Japanese main line; it is normally an accidental
    /// romaji/furigana payload from an inconsistent endpoint.
    private static func sanitizedSecondaryText(_ value: String?, main: String) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let normalizedText = text.replacingOccurrences(of: " ", with: "")
        let normalizedMain = main
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard normalizedText != normalizedMain else { return nil }

        if containsJapaneseKana(text) && !containsJapaneseKana(main) {
            return nil
        }
        return text
    }

    private static func containsJapaneseKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = Int(scalar.value)
            return (0x3040...0x30FF).contains(value)
                || (0x31F0...0x31FF).contains(value)
        }
    }

}
