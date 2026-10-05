import Foundation

/// QQ Music word-by-word (QRC) lyrics: fetch the encrypted payload, decode it and
/// turn `[lineStart,dur]字(start,dur)字(start,dur)` into timed lyric lines.
enum QQQRCLyrics {
    static func lyricLines(musicID: String) async -> [LyricLine] {
        guard let url = URL(string: "https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("version=15&miniversion=82&lrctype=4&musicid=\(musicID)".utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let body = String(data: data, encoding: .utf8),
              let hex = firstCapture(#"<content[^>]*>\s*<!\[CDATA\[([0-9A-Fa-f]+)\]\]>"#, in: body),
              let xml = QRCDecoder.decode(hex: hex) else { return [] }
        return parse(xml)
    }

    static func parse(_ xml: String) -> [LyricLine] {
        guard var content = firstCapture(#"LyricContent="([\s\S]*?)"\s*/>"#, in: xml) else { return [] }
        content = content
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        let lineTag = #/^\[(\d+),(\d+)\]/#
        let wordTag = #/\((\d+),(\d+)\)/#
        var lines: [LyricLine] = []
        var index = 0
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let head = line.firstMatch(of: lineTag) else { continue }
            let lineStart = (Double(head.output.1) ?? 0) / 1000
            let body = line[head.range.upperBound...]
            var words: [LyricWord] = []
            var text = ""
            var cursor = body.startIndex
            for match in body.matches(of: wordTag) {
                let piece = String(body[cursor..<match.range.lowerBound])
                cursor = match.range.upperBound
                guard !piece.isEmpty else { continue }
                let start = (Double(match.output.1) ?? 0) / 1000
                let duration = (Double(match.output.2) ?? 0) / 1000
                words.append(LyricWord(text: piece, start: start, duration: duration))
                text += piece
            }
            words = LyricWord.trimmingEnds(words)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !words.isEmpty else { continue }
            lines.append(LyricLine(id: index, time: lineStart, text: trimmed, words: words))
            index += 1
        }
        return lines
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}