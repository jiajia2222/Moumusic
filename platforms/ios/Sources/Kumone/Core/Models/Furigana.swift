import CoreFoundation
import Foundation

/// A base-text run and the optional Japanese reading displayed above it.
struct RubySegment: Hashable {
    let text: String
    let ruby: String?

    init(_ text: String, ruby: String? = nil) {
        self.text = text
        self.ruby = ruby
    }
}

enum Kana {
    static func isKanji(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3005,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3041...0x309F,
             0x30A0...0x30FF,
             0xFF66...0xFF9F:
            return true
        default:
            return false
        }
    }

    static func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isKanji)
    }

    static func isKanaOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy(isKana)
    }

    static func toHiragana(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0x30A1...0x30F6).contains(scalar.value)
                ? Unicode.Scalar(scalar.value - 0x60)!
                : scalar
        }))
    }

    static func equalIgnoringScript(_ left: some StringProtocol, _ right: some StringProtocol) -> Bool {
        toHiragana(String(left)) == toHiragana(String(right))
    }
}

/// Produces reading segments with the Japanese tokenizer built into Apple
/// platforms. No dictionary or network request is bundled in Moumusic.
enum Furigana {
    private static let locale = Locale(identifier: "ja")

    static func segments(for line: String) -> [RubySegment]? {
        guard Kana.containsKanji(line) else { return nil }
        let result = merged(annotate(line))
        return result.contains { $0.ruby != nil } ? result : nil
    }

    private static func annotate(_ line: String) -> [RubySegment] {
        var result: [RubySegment] = []
        var pending = ""
        let characters = Array(line)
        var index = 0

        func flushPending() {
            guard !pending.isEmpty else { return }
            result.append(contentsOf: tokenize(pending))
            pending = ""
        }

        while index < characters.count {
            if let hit = ReadingOverrides.match(characters, at: index) {
                flushPending()
                result.append(contentsOf: RubyAligner.align(surface: hit.surface, reading: hit.reading))
                index += hit.surface.count
            } else {
                pending.append(characters[index])
                index += 1
            }
        }
        flushPending()
        return result
    }

    private static func tokenize(_ text: String) -> [RubySegment] {
        guard Kana.containsKanji(text) else { return [RubySegment(text)] }
        let cfText = text as CFString
        let length = CFStringGetLength(cfText)
        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText, CFRangeMake(0, length),
            CFStringTokenizerUnitWordBoundary, locale as CFLocale
        ) else { return [RubySegment(text)] }
        let nsText = text as NSString

        var result: [RubySegment] = []
        var consumed = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if range.location > consumed {
                result.append(RubySegment(nsText.substring(with: NSRange(location: consumed, length: range.location - consumed))))
            }
            consumed = range.location + range.length
            let surface = nsText.substring(with: NSRange(location: range.location, length: range.length))
            guard Kana.containsKanji(surface),
                  let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                      tokenizer, kCFStringTokenizerAttributeLatinTranscription
                  ) as? String,
                  !latin.isEmpty,
                  let reading = latin.applyingTransform(StringTransform("Latin-Hiragana"), reverse: false),
                  Kana.isKanaOnly(reading)
            else {
                result.append(RubySegment(surface))
                continue
            }
            result.append(contentsOf: RubyAligner.align(surface: surface, reading: reading))
        }
        if consumed < length {
            result.append(RubySegment(nsText.substring(from: consumed)))
        }
        return result
    }

    private static func merged(_ segments: [RubySegment]) -> [RubySegment] {
        var result: [RubySegment] = []
        for segment in segments {
            if segment.ruby == nil, let last = result.last, last.ruby == nil {
                result[result.count - 1] = RubySegment(last.text + segment.text)
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
