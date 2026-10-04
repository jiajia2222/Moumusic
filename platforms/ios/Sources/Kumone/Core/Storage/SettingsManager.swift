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
        case .master: return "超清母带"
        case .atmos: return "高清环绕声"
        case .dolby: return "杜比全景声"
        case .surround: return "沉浸环绕声"
        case .hires: return "Hi-Res"
        case .lossless: return "无损"
        case .exhigh: return "极高"
        case .higher: return "较高"
        case .standard: return "标准"
        }
    }

    var badge: String {
        switch self {
        case .master: return "超清母带"
        case .atmos: return "高清环绕声"
        case .dolby: return "杜比全景声"
        case .surround: return "沉浸环绕声"
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
        case .master: return "超清母带 / Master"
        case .atmos: return "高清环绕声 / Spatial"
        case .dolby: return "杜比全景声 / Dolby Atmos"
        case .surround: return "沉浸环绕声 / Surround"
        case .hires: return "Hi-Res / FLAC 24-bit"
        case .lossless: return "无损 FLAC"
        case .exhigh, .higher: return "320 kbps"
        case .standard: return "128 kbps"
        }
    }

    /// The tier's name on the song's own platform (QQ 臻品 / 酷狗 蝰蛇 / 咪咕 PQ·HQ·SQ·ZQ ...); NetEase and
    /// anything else keep the app's generic names.
    func platformLabel(_ source: String?) -> String {
        switch (source ?? "").lowercased() {
        case "tx", "qq", "qqmusic", "qq-music":
            switch self {
            case .master: return "臻品母带"
            case .atmos: return "臻品全景声"
            case .dolby: return "杜比全景声"
            case .surround: return "臻品全景声 5.1"
            case .hires: return "Hi-Res 臻品音质"
            case .lossless: return "SQ 无损品质"
            case .exhigh, .higher: return "HQ 高品质"
            case .standard: return "标准音质"
            }
        case "kg", "kugou":
            switch self {
            case .master: return "蝰蛇超清母带"
            case .atmos: return "蝰蛇全景声"
            case .dolby, .surround: return "蝰蛇超清音质"
            case .hires: return "Hi-Res 超清音质"
            case .lossless: return "无损音质"
            case .exhigh, .higher: return "高品质"
            case .standard: return "标准音质"
            }
        case "mg", "migu":
            switch self {
            case .master: return "ZQ 臻品母带"
            case .atmos, .dolby, .surround: return "3D 臻品全景声"
            case .hires: return "ZQ Hi-Res"
            case .lossless: return "SQ 无损"
            case .exhigh, .higher: return "HQ 高品"
            case .standard: return "PQ 标准"
            }
        case "kw", "kuwo":
            switch self {
            case .master, .atmos, .dolby, .surround, .hires: return "Hi-Res 无损"
            case .lossless: return "无损音质"
            case .exhigh, .higher: return "超品音质"
            case .standard: return "标准音质"
            }
        default:
            return sourceDisplayName
        }
    }

    init?(lxType: String) {        switch lxType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
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

    /// These tiers are not treated as available NetEase account privileges
    /// for a non-VIP account. A third-party LX source may still advertise one
    /// of them, but the player must label that route explicitly.
    var requiresNeteaseVIP: Bool {
        switch self {
        case .master, .atmos, .dolby, .surround, .hires: return true
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

    /// Converts a provider response into a display label. This is deliberately
    /// separate from `displayName`: that property describes a requested tier,
    /// while this helper describes what the provider actually reported.
    static func resolvedDisplayName(_ rawValue: String?) -> String {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return "未知"
        }
        if rawValue.lowercased() == "unknown" {
            return "未知（音源未返回音质字段）"
        }
        if let quality = AudioQuality(lxType: rawValue) {
            return quality.sourceDisplayName
        }
        if let bitrate = Int(rawValue.lowercased()
            .replacingOccurrences(of: "kbps", with: "")
            .replacingOccurrences(of: "k", with: "")) {
            return "\(bitrate) kbps"
        }
        return rawValue.uppercased()
    }

    static func isUnknownResolvedQuality(_ rawValue: String?) -> Bool {
        rawValue?.lowercased() == "unknown" || rawValue == nil
    }

    /// Returns a comparable rank for a provider-reported result.  This is
    /// intentionally separate from the request enum because providers may
    /// return a concrete bitrate such as 192k that is not a selectable tier.
    static func resolvedRank(_ rawValue: String?) -> Int? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              rawValue.lowercased() != "unknown" else {
            return nil
        }
        if let quality = AudioQuality(lxType: rawValue) {
            switch quality {
            case .master: return 900
            case .atmos: return 850
            case .dolby: return 840
            case .surround: return 830
            case .hires: return 800
            case .lossless: return 700
            case .exhigh, .higher: return 320
            case .standard: return 128
            }
        }
        let numeric = rawValue.lowercased()
            .replacingOccurrences(of: "kbps", with: "")
            .replacingOccurrences(of: "k", with: "")
        return Int(numeric)
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

/// Selects which Bilibili client feed supplies the recommendation page.
///
/// The app option follows the public mobile feed used by PiliPlus. It does
/// not embed PiliPlus or send account credentials to another service.
enum BilibiliRecommendationSource: String, CaseIterable, Identifiable, Sendable {
    case web
    case app

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .web: return String(localized: "网页版推荐")
        case .app: return String(localized: "App 端推荐（PiliPlus）")
        }
    }

    var explanation: String {
        switch self {
        case .web:
            return String(localized: "使用 B 站网页版推荐流；登录后会结合账号 Cookie")
        case .app:
            return String(localized: "使用 PiliPlus 采用的 B 站移动端推荐流；登录后可获得更贴近客户端的内容")
        }
    }
}

/// Beans-style Bilibili mode. Watch and listen are deliberately mutually exclusive.
enum BilibiliMode: String, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case disabled
    case watch
    case listen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled: return "关闭"
        case .watch: return "看哔哩哔哩"
        case .listen: return "听哔哩哔哩"
        }
    }

    var explanation: String {
        switch self {
        case .disabled: return "不显示 B 站入口，也不会加载 B 站推荐。"
        case .watch: return "显示视频、直播、动态与 B 站视频播放器。"
        case .listen: return "保留 B 站音频播放；视频入口会切换为音频播放，不同时开启两个模式。"
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
        static let lockScreenImmersiveArtwork = "settings.lockScreenImmersiveArtwork"
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
        static let autoPauseOnRouteChange = "settings.autoPauseOnRouteChange"
        static let bilibiliMode = "settings.bilibiliMode"
        static let bilibiliRecommendationSource = "settings.bilibiliRecommendationSource"
        static let bilibiliDanmakuEnabled = "settings.bilibiliDanmakuEnabled"
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

    /// Supplies a high-resolution artwork representation to Apple's Now
    /// Playing system so the expanded Lock Screen player can use immersive
    /// album art. Turning it off keeps the standard, lightweight artwork.
    @Published var lockScreenImmersiveArtwork: Bool {
        didSet {
            UserDefaults.standard.set(lockScreenImmersiveArtwork, forKey: Keys.lockScreenImmersiveArtwork)
            NowPlayingManager.shared.applyImmersiveSettingNow()
        }
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

    /// Pause playback when iOS reports that headphones or another output
    /// route was disconnected.  This mirrors the behavior users expect from
    /// a native music player, while keeping an explicit opt-out for speakers,
    /// Bluetooth adapters, and accessibility setups.
    @Published var autoPauseOnRouteChange: Bool {
        didSet { UserDefaults.standard.set(autoPauseOnRouteChange, forKey: Keys.autoPauseOnRouteChange) }
    }

    /// The Bilibili capability is one mutually-exclusive mode. The current
    /// settings schema intentionally has no migration path for older builds:
    /// a fresh install defaults to the video experience, and the selected mode
    /// is the only source of truth for the Bilibili UI and player.
    @Published var bilibiliMode: BilibiliMode {
        didSet { UserDefaults.standard.set(bilibiliMode.rawValue, forKey: Keys.bilibiliMode) }
    }
    /// Which Bilibili client feed is used by the Bilibili recommendation page.
    /// Show scrolling danmaku when a Bilibili video exposes the public XML feed.
    @Published var bilibiliDanmakuEnabled: Bool {
        didSet { UserDefaults.standard.set(bilibiliDanmakuEnabled, forKey: Keys.bilibiliDanmakuEnabled) }
    }
    @Published var bilibiliRecommendationSource: BilibiliRecommendationSource {
        didSet {
            UserDefaults.standard.set(bilibiliRecommendationSource.rawValue,
                                      forKey: Keys.bilibiliRecommendationSource)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        audioQuality = defaults.string(forKey: Keys.quality).flatMap(AudioQuality.init(rawValue:)) ?? .exhigh
        playbackSourceMode = defaults.string(forKey: Keys.playbackSourceMode)
            .flatMap(PlaybackSourceMode.init(rawValue:)) ?? .automatic
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init) ?? .auto
        #if os(iOS)
        nowPlayingMode = defaults.string(forKey: Keys.nowPlayingMode).flatMap(NowPlayingMode.init) ?? .immersive
        lockScreenImmersiveArtwork = defaults.object(forKey: Keys.lockScreenImmersiveArtwork) as? Bool ?? true
        #endif
        showLyricsTranslation = defaults.object(forKey: Keys.showTranslation) as? Bool ?? true
        showLyricsRomaji = defaults.object(forKey: Keys.showRomaji) as? Bool ?? false
        let legacyRomaji = defaults.object(forKey: Keys.showRomaji) as? Bool ?? false
        lyricsAnnotation = defaults.string(forKey: Keys.lyricsAnnotation)
            .flatMap(LyricsAnnotation.init) ?? (legacyRomaji ? .romaji : .off)
        lyricsDisplayStyle = defaults.string(forKey: Keys.lyricsDisplayStyle)
            .flatMap(LyricsDisplayStyle.init) ?? .amll
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
        autoPauseOnRouteChange = defaults.object(forKey: Keys.autoPauseOnRouteChange) as? Bool ?? true
        bilibiliMode = defaults.string(forKey: Keys.bilibiliMode)
            .flatMap(BilibiliMode.init(rawValue:)) ?? .watch
        bilibiliDanmakuEnabled = defaults.object(forKey: Keys.bilibiliDanmakuEnabled) as? Bool ?? true
        bilibiliRecommendationSource = defaults.string(forKey: Keys.bilibiliRecommendationSource)
            .flatMap(BilibiliRecommendationSource.init(rawValue:)) ?? .app
    }

    /// Reloads the published values after an app-data backup has restored
    /// UserDefaults. Without this, the file is restored correctly but an
    /// already-running view would keep showing the old settings until restart.
    func reloadFromDefaults() {
        let defaults = UserDefaults.standard
        audioQuality = defaults.string(forKey: Keys.quality)
            .flatMap(AudioQuality.init(rawValue:)) ?? .exhigh
        playbackSourceMode = defaults.string(forKey: Keys.playbackSourceMode)
            .flatMap(PlaybackSourceMode.init(rawValue:)) ?? .automatic
        appearance = defaults.string(forKey: Keys.appearance)
            .flatMap(AppAppearance.init) ?? .auto
#if os(iOS)
        nowPlayingMode = defaults.string(forKey: Keys.nowPlayingMode)
            .flatMap(NowPlayingMode.init) ?? .immersive
        lockScreenImmersiveArtwork = defaults.object(forKey: Keys.lockScreenImmersiveArtwork) as? Bool ?? true
#endif
        showLyricsTranslation = defaults.object(forKey: Keys.showTranslation) as? Bool ?? true
        showLyricsRomaji = defaults.object(forKey: Keys.showRomaji) as? Bool ?? false
        let legacyRomaji = defaults.object(forKey: Keys.showRomaji) as? Bool ?? false
        lyricsAnnotation = defaults.string(forKey: Keys.lyricsAnnotation)
            .flatMap(LyricsAnnotation.init) ?? (legacyRomaji ? .romaji : .off)
        lyricsDisplayStyle = defaults.string(forKey: Keys.lyricsDisplayStyle)
            .flatMap(LyricsDisplayStyle.init) ?? .amll
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
        autoPauseOnRouteChange = defaults.object(forKey: Keys.autoPauseOnRouteChange) as? Bool ?? true
        bilibiliMode = defaults.string(forKey: Keys.bilibiliMode)
            .flatMap(BilibiliMode.init(rawValue:)) ?? .watch
        bilibiliDanmakuEnabled = defaults.object(forKey: Keys.bilibiliDanmakuEnabled) as? Bool ?? true
        bilibiliRecommendationSource = defaults.string(forKey: Keys.bilibiliRecommendationSource)
            .flatMap(BilibiliRecommendationSource.init(rawValue:)) ?? .app
    }
}
