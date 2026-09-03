import Foundation

/// Common lyric readings that are ambiguous or frequently mis-segmented by
/// the system tokenizer. The table is intentionally small and conservative.
enum ReadingOverrides {
    static let table: [String: String] = [
        "私": "わたし",
        "私達": "わたしたち",
        "私たち": "わたしたち",
        "明日": "あした",
        "君": "きみ",
        "日本": "にほん",
        "隙": "すき",
        "一日": "いちにち",
        "一日中": "いちにちじゅう",
        "気付": "きづ",
        "一昨日": "おととい",
        "十分": "じゅうぶん",
    ]

    private static let sortedKeys = table.keys.sorted { $0.count > $1.count }

    static func match(_ characters: [Character], at index: Int) -> (surface: String, reading: String)? {
        for key in sortedKeys {
            let length = key.count
            guard index + length <= characters.count,
                  String(characters[index..<(index + length)]) == key,
                  let reading = table[key],
                  !isKanji(characters, at: index - 1),
                  !isKanji(characters, at: index + length)
            else { continue }
            return (key, reading)
        }
        return nil
    }

    private static func isKanji(_ characters: [Character], at index: Int) -> Bool {
        guard characters.indices.contains(index) else { return false }
        return characters[index].unicodeScalars.contains(where: Kana.isKanji)
    }
}
