import Foundation

/// Matches a track from an LX provider to the corresponding NetEase song.
///
/// LX song IDs are provider-specific, so using the ID directly against a
/// NetEase endpoint can return a different song or a 404.  Matching by title,
/// artist and duration keeps lyric/comment metadata attached to the right
/// recording.
enum NeteaseTrackMatcher {
    private struct ScoredCandidate {
        let candidate: Track
        let score: Int
    }

    static func bestCandidate(for track: Track, in candidates: [Track]) -> Track? {
        bestCandidate(for: track, in: candidates, requireDuration: true)
    }

    /// Metadata such as comments can still be useful when an LX provider's
    /// recording duration differs from NetEase's edit by more than 12 seconds.
    /// Keep the exact title/artist checks, but do not reject that version solely
    /// because of duration.
    static func bestMetadataCandidate(for track: Track, in candidates: [Track]) -> Track? {
        bestCandidate(for: track, in: candidates, requireDuration: false)
    }

    /// Last-resort metadata match used for public comments. Some providers
    /// include a translated artist string, featured-artist suffix, or an
    /// empty artist field even though the title is exact. Comments are read
    /// only, so retaining an exact-title match is more useful than failing
    /// the entire comments sheet on an artist formatting difference.
    static func bestTitleCandidate(for track: Track, in candidates: [Track]) -> Track? {
        let title = normalizedTitle(track.name)
        guard !title.isEmpty else { return nil }
        return candidates.first { normalizedTitle($0.name) == title }
    }

    private static func bestCandidate(for track: Track, in candidates: [Track],
                                      requireDuration: Bool) -> Track? {
        let targetTitle = normalizedTitle(track.name)
        guard !targetTitle.isEmpty else { return nil }

        return candidates.compactMap { candidate -> ScoredCandidate? in
            guard let score = score(track: track, candidate: candidate,
                                    targetTitle: targetTitle,
                                    requireDuration: requireDuration) else { return nil }
            return ScoredCandidate(candidate: candidate, score: score)
        }
        .max { lhs, rhs in lhs.score < rhs.score }
        .map(\.candidate)
    }

    private static func score(track: Track, candidate: Track,
                              targetTitle: String, requireDuration: Bool) -> Int? {
        guard normalizedTitle(candidate.name) == targetTitle else { return nil }

        let targetArtists = artistTokens(track.artistNames)
        let candidateArtists = artistTokens(candidate.artistNames)
        if !targetArtists.isEmpty && !candidateArtists.isEmpty,
           targetArtists.isDisjoint(with: candidateArtists) {
            return nil
        }

        var result = 100
        if !targetArtists.isEmpty && !candidateArtists.isEmpty {
            result += targetArtists.intersection(candidateArtists).count * 60
        }

        if track.duration > 0, candidate.duration > 0 {
            let difference = abs(track.duration - candidate.duration)
            if requireDuration { guard difference <= 12 else { return nil } }
            result += max(0, 30 - Int(difference.rounded()) * 3)
        }

        return result
    }

    private static func normalizedTitle(_ value: String) -> String {
        var title = value.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: .current)
        // Treat common release labels as version metadata, not a different
        // song.  This still requires the actual title to match exactly.
        for marker in ["(live)", "（live）", "live", "(remix)", "（remix）",
                       "remix", "(dj)", "（dj）", "dj", "(伴奏)", "（伴奏）",
                       "伴奏", "(纯音乐)", "（纯音乐）", "纯音乐"] {
            title = title.replacingOccurrences(of: marker, with: "")
        }
        return title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func artistTokens(_ value: String) -> Set<String> {
        Set(value
            .components(separatedBy: ["/", "&", "、", ",", "，", ";", "；", "\\"])
            .map { normalizedTitle($0) }
            .filter { !$0.isEmpty })
    }
}
