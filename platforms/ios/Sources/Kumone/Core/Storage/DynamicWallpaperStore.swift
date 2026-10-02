#if os(iOS)
import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// Metal shader wallpapers (ShipSwift, MIT — see ShipSwift-LICENSE.txt).
enum DynamicWallpaperKind: String, CaseIterable, Identifiable, Sendable {
    case fractalClouds
    case inkSmoke
    case liquidChrome
    case neuroNoise
    case simplexNoise
    case metaballs
    case water
    case starNest
    case dotOrbit
    case dots
    case grainGradient

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fractalClouds: return "分形云层"
        case .inkSmoke: return "墨水扩散"
        case .liquidChrome: return "液态金属"
        case .neuroNoise: return "神经噪声"
        case .simplexNoise: return "单纯形噪声"
        case .metaballs: return "融合球"
        case .water: return "水面"
        case .starNest: return "星云"
        case .dotOrbit: return "圆点"
        case .dots: return "点阵"
        case .grainGradient: return "颗粒渐变"
        }
    }

    var englishName: String {
        switch self {
        case .fractalClouds: return "Fractal Clouds"
        case .inkSmoke: return "Ink Smoke"
        case .liquidChrome: return "Liquid Chrome"
        case .neuroNoise: return "Neuro Noise"
        case .simplexNoise: return "Simplex Noise"
        case .metaballs: return "Metaballs"
        case .water: return "Water"
        case .starNest: return "Star Nest"
        case .dotOrbit: return "Dot Orbit"
        case .dots: return "Dots"
        case .grainGradient: return "Grain Gradient"
        }
    }

    var summary: String {
        switch self {
        case .water: return "水面折射，使用你上传的图片作为内容"
        case .dots: return "点阵波浪、海洋与流动样式"
        case .grainGradient: return "静态颗粒渐变，不持续播放动画"
        default: return "着色器实时渲染的动态壁纸"
        }
    }
}

@MainActor
final class DynamicWallpaperStore: ObservableObject {
    static let shared = DynamicWallpaperStore()

    private enum Keys {
        static let enabled = "moumusic.dynamicWallpaper.enabled"
        static let kind = "moumusic.dynamicWallpaper.kind"
        static let speed = "moumusic.dynamicWallpaper.speed"
        static let intensity = "moumusic.dynamicWallpaper.intensity"
        static let syncToApp = "moumusic.dynamicWallpaper.syncToApp"
        static let syncToPlayer = "moumusic.dynamicWallpaper.syncToPlayer"
        static let dotsStyle = "moumusic.dynamicWallpaper.dotsStyle"
    }

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    @Published var kind: DynamicWallpaperKind {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: Keys.kind) }
    }
    /// Kept for stored-settings compatibility; the shaders run at their own pace.
    @Published var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: Keys.speed) }
    }
    @Published var intensity: Double {
        didSet { UserDefaults.standard.set(intensity, forKey: Keys.intensity) }
    }
    @Published var syncToApp: Bool {
        didSet { UserDefaults.standard.set(syncToApp, forKey: Keys.syncToApp) }
    }
    @Published var syncToPlayer: Bool {
        didSet { UserDefaults.standard.set(syncToPlayer, forKey: Keys.syncToPlayer) }
    }
    /// wavy / mountains / ocean / standing / flow / plasma / snake
    @Published var dotsStyleRaw: String {
        didSet { UserDefaults.standard.set(dotsStyleRaw, forKey: Keys.dotsStyle) }
    }
    @Published private(set) var waterImage: UIImage?

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        kind = defaults.string(forKey: Keys.kind)
            .flatMap(DynamicWallpaperKind.init(rawValue:)) ?? .fractalClouds
        speed = defaults.object(forKey: Keys.speed) as? Double ?? 0.35
        intensity = defaults.object(forKey: Keys.intensity) as? Double ?? 0.9
        syncToApp = defaults.object(forKey: Keys.syncToApp) as? Bool ?? true
        syncToPlayer = defaults.object(forKey: Keys.syncToPlayer) as? Bool ?? true
        dotsStyleRaw = defaults.string(forKey: Keys.dotsStyle) ?? "wavy"
        waterImage = UIImage(contentsOfFile: Self.waterURL.path)
    }

    private static var waterURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DynamicWallpaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("water.jpg")
    }

    func setWaterImage(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        try? resized.jpegData(compressionQuality: 0.88)?.write(to: Self.waterURL, options: .atomic)
        waterImage = resized
        kind = .water
    }

    func resetDefaults() {
        dotsStyleRaw = "wavy"
        try? FileManager.default.removeItem(at: Self.waterURL)
        waterImage = nil
    }
}

struct MoumusicDynamicWallpaperView: View {
    let kind: DynamicWallpaperKind
    let speed: Double
    let intensity: Double

    @ObservedObject private var store = DynamicWallpaperStore.shared

    var body: some View {
        shader
            .opacity(max(0.2, min(1, intensity)))
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var shader: some View {
        switch kind {
        case .fractalClouds: SWFractalClouds()
        case .inkSmoke: SWInkSmoke()
        case .liquidChrome: SWLiquidChrome()
        case .neuroNoise: SWNeuroNoise()
        case .simplexNoise: SWSimplexNoise()
        case .metaballs: SWMetaballs()
        case .water:
            SWWater {
                if let image = store.waterImage {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [.blue, .teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        case .starNest: SWStarNest()
        case .dotOrbit: SWDotOrbit()
        case .dots: SWDots(style: SWDotsStyle(rawValue: store.dotsStyleRaw) ?? .wavy)
        case .grainGradient: SWGrainGradient()
        }
    }
}
#endif