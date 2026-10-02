import Foundation

/// Romaji support for Japanese lyrics.
///
/// Netease ships a hand-checked `romalrc` for popular tracks only, so anything
/// off the beaten path falls back to the system tokenizer's Latin
/// transcription — offline, dependency-free, and good enough for singing along
/// (personal names and unusual readings can still be wrong).
enum RomajiTranscriber {
    private static let kanaRanges: [ClosedRange<UInt32>] = [
        0x3040...0x309F,  // hiragana
        0x30A0...0x30FF,  // katakana
        0xFF66...0xFF9D,  // halfwidth katakana
    ]

    static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            kanaRanges.contains { $0.contains(scalar.value) }
        }
    }

    /// Whether a lyric body reads as Japanese. Requires more than an isolated
    /// katakana loanword so Chinese lyrics don't get spuriously annotated.
    static func isJapanese(_ texts: [String]) -> Bool {
        let candidates = texts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !candidates.isEmpty else { return false }
        let kanaLines = candidates.count(where: containsKana)
        return kanaLines >= 3 || Double(kanaLines) / Double(candidates.count) >= 0.2
    }

    /// Latin transcription via the system tokenizer. Returns nil when the input
    /// yields nothing beyond what it already was (pure Latin, punctuation).
    static func transcribe(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let source = trimmed as CFString
        let range = CFRangeMake(0, CFStringGetLength(source))
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, source, range,
            kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: "ja_JP") as CFLocale)

        var pieces: [String] = []
        var transcribedAny = false
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let original = CFStringCreateWithSubstring(kCFAllocatorDefault, source, tokenRange)
                as String? ?? ""
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
                !latin.isEmpty
            {
                pieces.append(latin)
                transcribedAny = true
            } else if !original.trimmingCharacters(in: .whitespaces).isEmpty {
                pieces.append(original)
            }
        }

        guard transcribedAny else { return nil }
        let romaji = pieces.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Latin-only lines transcribe to themselves — don't echo the lyric.
        guard !romaji.isEmpty, !isEquivalent(romaji, trimmed) else { return nil }
        return romaji
    }

    private static func isEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        func squash(_ s: String) -> String {
            s.lowercased().filter { !$0.isWhitespace }
        }
        return squash(lhs) == squash(rhs)
    }
}
