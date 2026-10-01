import SwiftUI
import UIKit

/// 动态壁纸（Metal 着色器，iOS 17+）。着色器来自 ShipSwift（MIT），见 Shaders/ShipSwift-LICENSE.txt。
enum BeansDynamicWallpaper: String, CaseIterable, Identifiable {
    case none
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

    var englishName: String {
        switch self {
        case .none: return "Off"
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

    var chineseName: String {
        switch self {
        case .none: return "关闭"
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

    var summary: String {
        switch self {
        case .none: return "使用现有的颜色或图片壁纸"
        case .fractalClouds: return "分形云层，保留 ShipSwift 原始参数"
        case .inkSmoke: return "墨水扩散，保留 ShipSwift 原始参数"
        case .liquidChrome: return "液态金属，保留 ShipSwift 原始参数"
        case .neuroNoise: return "神经噪声，流动的发光线条"
        case .simplexNoise: return "单纯形噪声，多色渐变流场"
        case .metaballs: return "融合球，柔和的彩色流体形状"
        case .water: return "水面折射，使用你上传的图片作为源内容"
        case .starNest: return "星云隧道，保留 ShipSwift 原始参数"
        case .dotOrbit: return "彩色圆点围绕网格中心缓慢运动"
        case .dots: return "点阵波浪、海洋与流动样式"
        case .grainGradient: return "静态颗粒渐变，不持续播放动画"
        }
    }

    /// 颗粒渐变是静态渲染，不持续消耗动画刷新。
    var isAnimated: Bool { self != .none && self != .grainGradient }
}

@MainActor
final class DynamicWallpaperStore: ObservableObject {
    static let shared = DynamicWallpaperStore()

    private let kindKey = "beans.dynamicWallpaper.kind"
    private let dotsStyleKey = "beans.dynamicWallpaper.dotsStyle"

    @Published var kind: BeansDynamicWallpaper {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: kindKey) }
    }
    /// 点阵样式（wavy / mountains / ocean / standing / flow / plasma / snake）。
    @Published var dotsStyleRaw: String {
        didSet { UserDefaults.standard.set(dotsStyleRaw, forKey: dotsStyleKey) }
    }
    @Published private(set) var waterImage: UIImage?

    private init() {
        let d = UserDefaults.standard
        kind = BeansDynamicWallpaper(rawValue: d.string(forKey: "beans.dynamicWallpaper.kind") ?? "") ?? .none
        dotsStyleRaw = d.string(forKey: "beans.dynamicWallpaper.dotsStyle") ?? "wavy"
        waterImage = UIImage(contentsOfFile: Self.waterURL.path)
    }

    /// iOS 17 以下不支持 Metal 着色器壁纸。
    static var isSupported: Bool {
        #if MOUMUSIC_COMPAT
        return false
        #else
        if #available(iOS 17.0, *) { return true }
        return false
        #endif
    }

    var isActive: Bool { Self.isSupported && kind != .none }

    private static var waterURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DynamicWallpaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("water.jpg")
    }

    func setWaterImage(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        // 缩到较小尺寸，避免全屏着色器采样过大的纹理。
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
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

/// 渲染当前动态壁纸；iOS 17 以下渲染为空。
struct DynamicWallpaperLayer: View {
    let kind: BeansDynamicWallpaper
    var waterImage: UIImage?
    var dotsStyleRaw: String = "wavy"

    var body: some View {
        #if MOUMUSIC_COMPAT
        Color.clear
        #else
        if #available(iOS 17.0, *) {
            shader
        } else {
            Color.clear
        }
        #endif
    }

    #if !MOUMUSIC_COMPAT
    @available(iOS 17.0, *)
    @ViewBuilder
    private var shader: some View {
        switch kind {
        case .none: Color.clear
        case .fractalClouds: SWFractalClouds()
        case .inkSmoke: SWInkSmoke()
        case .liquidChrome: SWLiquidChrome()
        case .neuroNoise: SWNeuroNoise()
        case .simplexNoise: SWSimplexNoise()
        case .metaballs: SWMetaballs()
        case .water:
            SWWater {
                if let waterImage {
                    Image(uiImage: waterImage).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color.blue, Color.teal, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        case .starNest: SWStarNest()
        case .dotOrbit: SWDotOrbit()
        case .dots: SWDots(style: SWDotsStyle(rawValue: dotsStyleRaw) ?? .wavy)
        case .grainGradient: SWGrainGradient()
        }
    }
    #endif
}

// MARK: - 设置区块

struct DynamicWallpaperSettingsSection: View {
    @ObservedObject private var store = DynamicWallpaperStore.shared
    @State private var showWaterPicker = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "动态壁纸")
            VStack(alignment: .leading, spacing: 12) {
                if !DynamicWallpaperStore.isSupported {
                    Text("动态壁纸需要 iOS 17 或更高版本。")
                        .font(BeansFont.appFont(12)).foregroundStyle(Color.beansComment)
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(BeansDynamicWallpaper.allCases) { item in
                        let selected = store.kind == item
                        Button {
                            store.kind = item
                            BeansHaptics.select()
                        } label: {
                            VStack(spacing: 4) {
                                Text(item.chineseName)
                                    .font(BeansFont.appFont(13, selected ? .semibold : .medium))
                                Text(item.englishName)
                                    .font(BeansFont.appFont(9)).foregroundStyle(Color.beansComment)
                            }
                            .foregroundStyle(selected ? Color.beansAmber : Color.beansLabel)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(selected ? Color.beansAmber.opacity(0.14) : Color.beansLabel.opacity(0.055),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selected ? Color.beansAmber.opacity(0.42) : Color.beansLabel.opacity(0.08), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .disabled(item != .none && !DynamicWallpaperStore.isSupported)
                    }
                }
                Text(store.kind.summary)
                    .font(BeansFont.appFont(12)).foregroundStyle(Color.beansComment)

                if store.kind == .water {
                    GlassButton(title: "上传一张图片作为水面内容", systemName: "photo") { showWaterPicker = true }
                }
                if store.kind == .dots {
                    Picker("点阵样式", selection: $store.dotsStyleRaw) {
                        ForEach(dotsStyles, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.menu)
                }
                if store.kind == .grainGradient {
                    Text("Grain Gradient 已按静态壁纸处理，不会持续消耗动画刷新。")
                        .font(BeansFont.appFont(11)).foregroundStyle(Color.beansComment)
                }
                if store.kind != .none {
                    GlassButton(title: "恢复当前默认参数", systemName: "arrow.counterclockwise") { store.resetDefaults() }
                }
            }
            .padding(14)
            .background { BeansGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
        }
        .sheet(isPresented: $showWaterPicker) {
            WallpaperPhotoPicker { data in
                store.setWaterImage(data)
                ToastCenter.shared.show("Water 壁纸已更新")
            }
            .ignoresSafeArea()
        }
    }

    private var dotsStyles: [(String, String)] {
        [("wavy", "波浪"), ("mountains", "山脉"), ("ocean", "海洋"), ("standing", "站立波"),
         ("flow", "流动"), ("plasma", "等离子"), ("snake", "蛇形")]
    }
}
