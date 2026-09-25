import SwiftUI

enum AudioQuality: String, CaseIterable, Identifiable, Sendable {
    // allCases is used by the player and download pickers. Keep the order
    // highest-to-lowest so the best declared source tier appears first.
    case master
    case atmos
    case dolby
    case surround
    case hires
    case lossless
    case exhigh
    case higher
    case standard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .master: return "母带"
        case .atmos: return "全景声"
        case .dolby: return "杜比全景声"
        case .surround: return "环绕声"
        case .hires: return "Hi-Res"
        case .lossless: return "无损"
        case .exhigh: return "极高"
        case .higher: return "较高"
        case .standard: return "标准"
        }
    }

    var badge: String {
        switch self {
        case .master: return "母带"
        case .atmos: return "全景声"
        case .dolby: return "杜比全景声"
        case .surround: return "环绕声"
        case .hires: return "高解析"
        case .lossless: return "无损"
        case .exhigh: return "极高"
        case .higher: return "较高"
        case .standard: return "标准"
        }
    }

    var lxType: String {
        switch self {
        case .master: return "jymaster"
        case .atmos: return "atmos"
        case .dolby: return "dolby"
        case .surround: return "surround"
        case .hires: return "flac24bit"
        case .lossless: return "flac"
        case .exhigh, .higher: return "320k"
        case .standard: return "128k"
        }
    }

    /// Technical label shown in the picker. It never claims a tier that the
    /// active source did not advertise.
    var sourceDisplayName: String {
        switch self {
        case .master: return "母带 / Master"
        case .atmos: return "全景声 / Atmos"
        case .dolby: return "杜比全景声 / Dolby"
        case .surround: return "环绕声 / Surround"
        case .hires: return "Hi-Res / FLAC 24-bit"
        case .lossless: return "无损 FLAC"
        case .exhigh, .higher: return "320 kbps"
        case .standard: return "128 kbps"
        }
    }

    init?(lxType: String) {
        switch lxType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "master", "jymaster", "master_quality", "master-quality": self = .master
        case "atmos", "immersive": self = .atmos
        case "dolby", "dolby-atmos", "dolbyatmos": self = .dolby
        case "surround", "spatial", "spatial-audio": self = .surround
        case "128", "128k", "m4a", "mp3": self = .standard
        case "320", "320k": self = .exhigh
        case "flac", "lossless", "ape": self = .lossless
        case "flac24bit", "flac24", "hires", "highres": self = .hires
        default: return nil
        }
    }

    var isPlatformSpecific: Bool {
        switch self {
        case .master, .atmos, .dolby, .surround: return true
        default: return false
        }
    }

    /// NetEase's official account endpoint uses different level names from
    /// LX User API. Keep this mapping in one place so the player can request
    /// an account URL without changing the third-party source protocol.
    var neteaseLevel: String {
        switch self {
        case .master: return "jymaster"
        case .atmos: return "jyeffect"
        case .dolby: return "dolby"
        case .surround: return "sky"
        case .hires: return "hires"
        case .lossless: return "lossless"
        case .exhigh, .higher: return "exhigh"
        case .standard: return "standard"
        }
    }

    init?(neteaseLevel: String) {
        switch neteaseLevel.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "jymaster", "master": self = .master
        case "jyeffect", "atmos", "immersive": self = .atmos
        case "dolby", "dolby_atmos": self = .dolby
        case "sky", "surround", "spatial": self = .surround
        case "hires", "highres": self = .hires
        case "lossless", "flac": self = .lossless
        case "exhigh", "higher": self = .exhigh
        case "standard", "128k": self = .standard
        default: return nil
        }
    }
}

/// Selects which authorized playback route is attempted first on iOS.
/// `automatic` is the safe default: prefer a logged-in account source for the
/// matching catalogue, then fall back to enabled LX sources when it cannot
/// provide a full-length URL.
enum PlaybackSourceMode: String, CaseIterable, Identifiable {
    case automatic
    case official
    case thirdParty

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "自动（账号优先，三方备用）")
        case .official: return String(localized: "账号音源（官方）")
        case .thirdParty: return String(localized: "第三方音源")
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            return String(localized: "优先使用已登录账号的完整音频；账号不可用时按已启用的 LX 音源顺序回退")
        case .official:
            return String(localized: "网易云、QQ 音乐、酷狗按对应平台使用已登录账号的官方播放；未登录或不可用时不会偷偷换源")
        case .thirdParty:
            return String(localized: "只使用已导入并启用的 LX 音源")
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Japanese lyric annotation mode. The legacy boolean is migrated below so
/// existing installations keep their previous romaji preference.
enum LyricsAnnotation: String, CaseIterable, Identifiable {
    case off
    case romaji
    case furigana

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return String(localized: "关闭")
        case .romaji: return String(localized: "罗马音")
        case .furigana: return String(localized: "汉字读音")
        }
    }
}

/// Controls how synced lyric lines are rendered. The AMLL option follows the
/// Apple Music-style presentation: larger focused lines, softer surrounding
/// lines, and a live word-timed fill when the source provides word timings.
enum LyricsDisplayStyle: String, CaseIterable, Identifiable {
    case standard
    case amll

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return String(localized: "标准歌词")
        case .amll: return String(localized: "Apple Music / AMLL")
        }
    }

    var explanation: String {
        switch self {
        case .standard: return String(localized: "保持当前歌词布局与逐字高亮")
        case .amll: return String(localized: "Apple Music 风格聚焦歌词；长按歌词区域可快速切换")
        }
    }

    mutating func toggle() {
        self = self == .standard ? .amll : .standard
    }
}

#if os(iOS)
enum NowPlayingMode: String, CaseIterable, Identifiable {
    case classic
    case immersive
    case minimal
    case lyrics
    case amll
    case vinyl

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return String(localized: "经典模式")
        case .immersive: return String(localized: "沉浸模式")
        case .minimal: return String(localized: "简洁模式")
        case .lyrics: return String(localized: "歌词模式")
        case .amll: return String(localized: "Apple Music / AMLL")
        case .vinyl: return String(localized: "唱片模式")
        }
    }
}
#endif

/// The home page has one recommendation family at a time. The platform used
/// by LX recommendations is configured separately so aggregate search never
/// accidentally becomes the home page provider.
enum HomeRecommendationMode: String, CaseIterable, Identifiable {
    case lx
    case netease

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lx: return "LX 推荐"
        case .netease: return "网易云推荐"
        }
    }
}

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private enum Keys {
        static let quality = "settings.audioQuality"
        static let playbackSourceMode = "settings.playbackSourceMode"
        static let appearance = "settings.appearance"
        #if os(iOS)
        static let nowPlayingMode = "settings.nowPlayingMode"
        #endif
        static let showTranslation = "settings.showLyricsTranslation"
        static let showRomaji = "settings.showLyricsRomaji"
        static let lyricsAnnotation = "settings.lyricsAnnotation"
        static let lyricsDisplayStyle = "settings.lyricsDisplayStyle"
        static let verbatimLyrics = "settings.verbatimLyrics"
        static let lyricsOffset = "settings.lyricsOffset"
        static let volume = "settings.volume"
        static let fmMode = "settings.fmMode"
        static let unblock = "settings.enableUnblock"
        static let autoCheckUpdates = "settings.autoCheckUpdates"
        static let desktopLyrics = "settings.showDesktopLyrics"
        static let desktopLyricsCentered = "settings.desktopLyricsCentered"
        static let homeRecommendationMode = "settings.homeRecommendationMode"
        static let homeRecommendationPlatform = "settings.homeRecommendationPlatform"
        static let sourcePlatformFallback = "settings.sourcePlatformFallback"
        /// Legacy all-in-one Bilibili switch.  Kept only to migrate existing
        /// installations to the two independent controls below.
        static let bilibiliContentEnabled = "settings.bilibiliContentEnabled"
        static let bilibiliVideoEnabled = "settings.bilibiliVideoEnabled"
        static let bilibiliAudioEnabled = "settings.bilibiliAudioEnabled"
    }

    @Published var audioQuality: AudioQuality {
        didSet { UserDefaults.standard.set(audioQuality.rawValue, forKey: Keys.quality) }
    }

    @Published var playbackSourceMode: PlaybackSourceMode {
        didSet { UserDefaults.standard.set(playbackSourceMode.rawValue, forKey: Keys.playbackSourceMode) }
    }

    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    #if os(iOS)
    @Published var nowPlayingMode: NowPlayingMode {
        didSet { UserDefaults.standard.set(nowPlayingMode.rawValue, forKey: Keys.nowPlayingMode) }
    }
    #endif

    @Published var showLyricsTranslation: Bool {
        didSet { UserDefaults.standard.set(showLyricsTranslation, forKey: Keys.showTranslation) }
    }

    /// Check for updates on launch. When off, no update sheet appears
    /// automatically; the user can still check manually (#42).
    @Published var autoCheckUpdates: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates)
            #if os(macOS)
            UpdaterManager.shared.setAutomaticChecks(autoCheckUpdates)
            #endif
        }
    }

    /// Romaji line above Japanese lyrics.
    @Published var showLyricsRomaji: Bool {
        didSet { UserDefaults.standard.set(showLyricsRomaji, forKey: Keys.showRomaji) }
    }

    @Published var lyricsAnnotation: LyricsAnnotation {
        didSet { UserDefaults.standard.set(lyricsAnnotation.rawValue, forKey: Keys.lyricsAnnotation) }
    }

    @Published var lyricsDisplayStyle: LyricsDisplayStyle {
        didSet { UserDefaults.standard.set(lyricsDisplayStyle.rawValue, forKey: Keys.lyricsDisplayStyle) }
    }

    /// Karaoke-style word-by-word highlighting when the song has verbatim
    /// (yrc) lyrics; falls back to line highlighting when it doesn't.
    @Published var verbatimLyrics: Bool {
        didSet { UserDefaults.standard.set(verbatimLyrics, forKey: Keys.verbatimLyrics) }
    }

    /// Positive values move the displayed lyric forward to compensate for a
    /// source whose timestamps arrive slightly behind its audio.
    @Published var lyricsOffset: Double {
        didSet { UserDefaults.standard.set(lyricsOffset, forKey: Keys.lyricsOffset) }
    }

    /// Resolve gray tracks from third-party sources (UnblockNeteaseMusic-style).
    @Published var enableUnblock: Bool {
        didSet { UserDefaults.standard.set(enableUnblock, forKey: Keys.unblock) }
    }

    /// Floating desktop lyrics window (LyricsX-style).
    @Published var showDesktopLyrics: Bool {
        didSet { UserDefaults.standard.set(showDesktopLyrics, forKey: Keys.desktopLyrics) }
    }

    /// Keep desktop lyrics horizontally centered while retaining the saved
    /// vertical position. When disabled, the user can freely place the box.
    @Published var desktopLyricsCentered: Bool {
        didSet { UserDefaults.standard.set(desktopLyricsCentered, forKey: Keys.desktopLyricsCentered) }
    }

    @Published var homeRecommendationMode: HomeRecommendationMode {
        didSet { UserDefaults.standard.set(homeRecommendationMode.rawValue, forKey: Keys.homeRecommendationMode) }
    }

    /// A single LX catalogue provider for the home page. `.aggregate` is
    /// deliberately not a valid value here; it belongs to Search only.
    @Published var homeRecommendationPlatform: LXCatalogPlatform {
        didSet { UserDefaults.standard.set(homeRecommendationPlatform.rawValue, forKey: Keys.homeRecommendationPlatform) }
    }

    /// Try other LX platform adapters when the selected playback source cannot
    /// resolve a track. This is enabled by default for uninterrupted playback.
    @Published var enableSourcePlatformFallback: Bool {
        didSet { UserDefaults.standard.set(enableSourcePlatformFallback, forKey: Keys.sourcePlatformFallback) }
    }

    /// Lets the user browse and watch Bilibili content.  This is deliberately
    /// independent from the audio-only capability so the Bilibili centre can
    /// be hidden without disabling an already-open audio session.
    @Published var bilibiliVideoEnabled: Bool {
        didSet { UserDefaults.standard.set(bilibiliVideoEnabled, forKey: Keys.bilibiliVideoEnabled) }
    }

    /// Makes the "听视频" mode available in the native Bilibili player.
    @Published var bilibiliAudioEnabled: Bool {
        didSet { UserDefaults.standard.set(bilibiliAudioEnabled, forKey: Keys.bilibiliAudioEnabled) }
    }

    private init() {
        let defaults = UserDefaults.standard
        audioQuality = defaults.string(forKey: Keys.quality).flatMap(AudioQuality.init(rawValue:)) ?? .exhigh
        playbackSourceMode = defaults.string(forKey: Keys.playbackSourceMode)
            .flatMap(PlaybackSourceMode.init(rawValue:)) ?? .automatic
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init) ?? .auto
        #if os(iOS)
        nowPlayingMode = defaults.string(forKey: Keys.nowPlayingMode).flatMap(NowPlayingMode.init) ?? .immersive
        #endif
        showLyricsTranslation = defaults.object(forKey: Keys.showTranslation) as? Bool ?? true
        showLyricsRomaji = defaults.object(forKey: Keys.showRomaji) as? Bool ?? false
        let legacyRomaji = defaults.object(forKey: Keys.showRomaji) as? Bool ?? false
        lyricsAnnotation = defaults.string(forKey: Keys.lyricsAnnotation)
            .flatMap(LyricsAnnotation.init) ?? (legacyRomaji ? .romaji : .off)
        lyricsDisplayStyle = defaults.string(forKey: Keys.lyricsDisplayStyle)
            .flatMap(LyricsDisplayStyle.init) ?? .standard
        verbatimLyrics = defaults.object(forKey: Keys.verbatimLyrics) as? Bool ?? true
        lyricsOffset = defaults.object(forKey: Keys.lyricsOffset) as? Double ?? 0
        enableUnblock = defaults.object(forKey: Keys.unblock) as? Bool ?? false
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        showDesktopLyrics = defaults.object(forKey: Keys.desktopLyrics) as? Bool ?? false
        desktopLyricsCentered = defaults.object(forKey: Keys.desktopLyricsCentered) as? Bool ?? false
        homeRecommendationMode = defaults.string(forKey: Keys.homeRecommendationMode)
            .flatMap(HomeRecommendationMode.init) ?? .lx
        let storedPlatform = defaults.string(forKey: Keys.homeRecommendationPlatform)
            .flatMap(LXCatalogPlatform.init)
        homeRecommendationPlatform = storedPlatform.flatMap {
            ($0 == .aggregate || $0 == .sd) ? nil : $0
        } ?? .wy
        enableSourcePlatformFallback = defaults.object(forKey: Keys.sourcePlatformFallback) as? Bool ?? true
        let legacyBilibiliEnabled = defaults.object(forKey: Keys.bilibiliContentEnabled) as? Bool ?? true
        bilibiliVideoEnabled = defaults.object(forKey: Keys.bilibiliVideoEnabled) as? Bool ?? legacyBilibiliEnabled
        bilibiliAudioEnabled = defaults.object(forKey: Keys.bilibiliAudioEnabled) as? Bool ?? legacyBilibiliEnabled
    }
}
