import Foundation

/// Lyric timing differs from song to song (another cut of the recording, another source's time axis), so one global
/// offset can never fit them all. This remembers the offset the user dialled in for each song.
@MainActor
final class SongLyricOffsetStore {
    static let shared = SongLyricOffsetStore()

    private let storageKey = "moumusic.songLyricOffsets.v1"
    private let orderKey = "moumusic.songLyricOffsets.order.v1"
    private let capacity = 600
    private var offsets: [String: Double]
    private var order: [String]

    private init() {
        let defaults = UserDefaults.standard
        offsets = defaults.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
        order = defaults.stringArray(forKey: orderKey) ?? []
    }

    func offset(for key: String) -> Double {
        offsets[key] ?? 0
    }

    /// Zero removes the entry; the oldest entries go first once the list is full.
    func set(_ value: Double, for key: String) {
        order.removeAll { $0 == key }
        if abs(value) < 0.001 {
            offsets[key] = nil
        } else {
            offsets[key] = value
            order.append(key)
            while order.count > capacity, let oldest = order.first {
                order.removeFirst()
                offsets[oldest] = nil
            }
        }
        let defaults = UserDefaults.standard
        defaults.set(offsets, forKey: storageKey)
        defaults.set(order, forKey: orderKey)
    }
}
