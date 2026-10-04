import Foundation

/// Which audio tiers may be offered at all, given the playback mode, the selected LX source and the logged-in
/// accounts. A tier the source (or an account) cannot deliver is never shown; the per-track picker then only
/// adds what a real probe confirmed on top of this.
@MainActor
enum QualitySupport {
    private static let preferredKey = "moumusic.audioQuality.preferred"

    /// Canonical tier names (`AudioQuality.lxType`) that can be offered right now.
    static func allowedTiers(for mode: PlaybackSourceMode) -> Set<String> {
        var tiers: Set<String> = ["128k"]
        if mode != .official, LXSourceStore.shared.selectedSource != nil {
            let service = LXUserAPIService.shared
            if service.sourceSupportKnown {
                tiers.formUnion(service.sourceTierSupport)
            } else {
                // The selected source has not answered yet (first launch with it): hide nothing until it has.
                tiers.formUnion(AudioQuality.allCases.map(\.lxType))
            }
        }
        if mode != .thirdParty {
            if NeteaseClient.shared.isLoggedIn { tiers.formUnion(AudioQuality.allCases.map(\.lxType)) }
            if QQMusicSessionStore.shared.isLoggedIn { tiers.formUnion(["flac", "320k", "128k"]) }
            if KugouSessionStore.shared.isLoggedIn {
                tiers.formUnion(["jymaster", "atmos", "dolby", "flac24bit", "flac", "320k", "128k"])
            }
        }
        return tiers
    }

    /// Best to worst, one entry per tier (the two "320 kbps" cases collapse into one).
    static func audioQualities(for mode: PlaybackSourceMode) -> [AudioQuality] {
        let allowed = allowedTiers(for: mode)
        var seen = Set<String>()
        return AudioQuality.allCases.filter { allowed.contains($0.lxType) && seen.insert($0.lxType).inserted }
    }

    /// Remembers what the user picked in settings, so a tier that is unavailable for now (another source,
    /// signed out) is restored when it becomes available again.
    static func rememberChoice(_ quality: AudioQuality) {
        UserDefaults.standard.set(quality.rawValue, forKey: preferredKey)
    }

    /// The selected default quality must be one that can be offered: otherwise use the best supported tier
    /// at or below the user's own choice.
    static func normalizeSelection() {
        let settings = SettingsManager.shared
        let defaults = UserDefaults.standard
        let preferred = defaults.string(forKey: preferredKey).flatMap(AudioQuality.init(rawValue:))
            ?? settings.audioQuality
        if defaults.string(forKey: preferredKey) == nil { rememberChoice(preferred) }

        let allowed = audioQualities(for: settings.playbackSourceMode)
        guard !allowed.isEmpty else { return }
        let order = AudioQuality.allCases
        let wanted = order.firstIndex(of: preferred) ?? 0
        let target = allowed.first(where: { $0.lxType == preferred.lxType })
            ?? allowed.first(where: { (order.firstIndex(of: $0) ?? 0) > wanted })
            ?? allowed.last!
        if settings.audioQuality != target { settings.audioQuality = target }
    }
}
