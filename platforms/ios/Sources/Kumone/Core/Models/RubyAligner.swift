import Foundation

/// Aligns one morphological reading to the kanji runs it belongs to.
/// This prevents readings for compounds from drifting over neighbouring kana.
enum RubyAligner {
    static func align(surface: String, reading: String) -> [RubySegment] {
        guard Kana.containsKanji(surface) else { return [RubySegment(surface)] }
        let readingChars = Array(Kana.toHiragana(reading))
        guard !readingChars.isEmpty else { return [RubySegment(surface)] }

        var result: [RubySegment] = []
        var cursor = 0
        var pendingKanji: String?

        for run in runs(of: surface) {
            if run.isKanji {
                pendingKanji = run.text
                continue
            }
            guard Kana.isKanaOnly(run.text) else { return fallback(surface, reading) }
            let needle = Array(Kana.toHiragana(run.text))
            let minStart = cursor + (pendingKanji == nil ? 0 : 1)
            guard let hit = firstIndex(of: needle, in: readingChars, from: minStart) else {
                return fallback(surface, reading)
            }
            if let kanji = pendingKanji {
                result.append(RubySegment(kanji, ruby: String(readingChars[cursor..<hit])))
                pendingKanji = nil
            } else if hit != cursor {
                return fallback(surface, reading)
            }
            result.append(RubySegment(run.text))
            cursor = hit + needle.count
        }

        if let kanji = pendingKanji {
            guard cursor < readingChars.count else { return fallback(surface, reading) }
            result.append(RubySegment(kanji, ruby: String(readingChars[cursor...])))
            cursor = readingChars.count
        }
        guard cursor == readingChars.count else { return fallback(surface, reading) }
        return result
    }

    private static func fallback(_ surface: String, _ reading: String) -> [RubySegment] {
        let surfaceChars = Array(surface)
        let readingChars = Array(Kana.toHiragana(reading))
        guard let first = surfaceChars.firstIndex(where: { $0.unicodeScalars.contains(where: Kana.isKanji) }),
              let last = surfaceChars.lastIndex(where: { $0.unicodeScalars.contains(where: Kana.isKanji) })
        else { return [RubySegment(surface)] }

        var start = 0
        var end = readingChars.count
        let prefix = Array(surfaceChars[..<first])
        let suffix = Array(surfaceChars[(last + 1)...])
        var head = ""
        var tail = ""

        if !prefix.isEmpty, prefix.count < end,
           Kana.equalIgnoringScript(String(prefix), String(readingChars[0..<prefix.count])) {
            start = prefix.count
            head = String(prefix)
        }
        if !suffix.isEmpty, suffix.count < end - start,
           Kana.equalIgnoringScript(String(suffix), String(readingChars[(end - suffix.count)...])) {
            end -= suffix.count
            tail = String(suffix)
        }

        let bodyStart = head.isEmpty ? 0 : first
        let bodyEnd = tail.isEmpty ? surfaceChars.count : last + 1
        let body = String(surfaceChars[bodyStart..<bodyEnd])
        guard start < end else { return [RubySegment(surface)] }

        var result: [RubySegment] = []
        if !head.isEmpty { result.append(RubySegment(head)) }
        result.append(RubySegment(body, ruby: String(readingChars[start..<end])))
        if !tail.isEmpty { result.append(RubySegment(tail)) }
        return result
    }

    private struct Run {
        let text: String
        let isKanji: Bool
    }

    private static func runs(of surface: String) -> [Run] {
        var result: [Run] = []
        var current = ""
        var currentIsKanji: Bool?
        for char in surface {
            let isKanji = char.unicodeScalars.contains(where: Kana.isKanji)
            if isKanji != currentIsKanji, currentIsKanji != nil {
                result.append(Run(text: current, isKanji: currentIsKanji!))
                current = ""
            }
            currentIsKanji = isKanji
            current.append(char)
        }
        if let isKanji = currentIsKanji, !current.isEmpty {
            result.append(Run(text: current, isKanji: isKanji))
        }
        return result
    }

    private static func firstIndex(of needle: [Character], in haystack: [Character], from start: Int) -> Int? {
        guard !needle.isEmpty, start >= 0, start + needle.count <= haystack.count else { return nil }
        for index in start...(haystack.count - needle.count) {
            if Array(haystack[index..<(index + needle.count)]) == needle { return index }
        }
        return nil
    }
}
