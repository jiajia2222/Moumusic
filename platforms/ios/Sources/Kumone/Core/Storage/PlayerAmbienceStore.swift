#if os(iOS)
import Foundation
import SwiftUI

/// Beans-style ambience controls for the immersive player.
///
/// This is intentionally separate from DynamicWallpaperStore: the global
/// wallpaper is an app-surface choice, while this ambience follows the
/// current track's extracted artwork colors.
enum MoumusicPlayerDustMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case snow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .snow: return "动态浮尘"
        }
    }
}

@MainActor
final class PlayerAmbienceStore: ObservableObject {
    static let shared = PlayerAmbienceStore()

    private enum Keys {
        static let enabled = "moumusic.playerAmbience.enabled"
        static let breath = "moumusic.playerAmbience.breath"
        static let dustMode = "moumusic.playerAmbience.dustMode"
        static let dustDensity = "moumusic.playerAmbience.dustDensity"
        static let dustSize = "moumusic.playerAmbience.dustSize"
    }

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    @Published var breath: Double {
        didSet { UserDefaults.standard.set(breath, forKey: Keys.breath) }
    }
    @Published var dustMode: MoumusicPlayerDustMode {
        didSet { UserDefaults.standard.set(dustMode.rawValue, forKey: Keys.dustMode) }
    }
    @Published var dustDensity: Double {
        didSet { UserDefaults.standard.set(dustDensity, forKey: Keys.dustDensity) }
    }
    @Published var dustSize: Double {
        didSet { UserDefaults.standard.set(dustSize, forKey: Keys.dustSize) }
    }

    private init() {
        let defaults = UserDefaults.standard

        // Read the Beans keys once when available, so a migration keeps the
        // user's existing player ambience choices instead of resetting them.
        isEnabled = Self.bool(defaults, moumusicKey: Keys.enabled, legacyKey: "beans.playerAmbience.enabled", defaultValue: true)
        breath = Self.double(defaults, moumusicKey: Keys.breath, legacyKey: "beans.playerBreath", defaultValue: 0.6)
        let dustRaw = Self.string(defaults, moumusicKey: Keys.dustMode, legacyKey: "beans.playerDustMode")
        dustMode = MoumusicPlayerDustMode(rawValue: dustRaw ?? "") ?? .off
        dustDensity = Self.double(defaults, moumusicKey: Keys.dustDensity, legacyKey: "beans.playerDustDensity", defaultValue: 1.0)
        dustSize = Self.double(defaults, moumusicKey: Keys.dustSize, legacyKey: "beans.playerDustSize", defaultValue: 1.0)
    }

    private static func string(_ defaults: UserDefaults, moumusicKey: String, legacyKey: String) -> String? {
        if let value = defaults.string(forKey: moumusicKey), !value.isEmpty { return value }
        return defaults.string(forKey: legacyKey)
    }

    private static func bool(_ defaults: UserDefaults, moumusicKey: String, legacyKey: String, defaultValue: Bool) -> Bool {
        if defaults.object(forKey: moumusicKey) != nil {
            return defaults.bool(forKey: moumusicKey)
        }
        if defaults.object(forKey: legacyKey) != nil {
            return defaults.bool(forKey: legacyKey)
        }
        return defaultValue
    }

    private static func double(_ defaults: UserDefaults, moumusicKey: String, legacyKey: String, defaultValue: Double) -> Double {
        if defaults.object(forKey: moumusicKey) != nil {
            return defaults.double(forKey: moumusicKey)
        }
        if defaults.object(forKey: legacyKey) != nil {
            return defaults.double(forKey: legacyKey)
        }
        return defaultValue
    }
}
#endif
