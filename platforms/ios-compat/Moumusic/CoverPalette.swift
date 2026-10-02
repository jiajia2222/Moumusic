import SwiftUI
import UIKit

// MARK: - 封面主色提取与动态调色板（Apple Music 风格）

/// 0~1 RGB 颜色
struct RGBColor: Equatable {
    var r: Double
    var g: Double
    var b: Double

    var color: Color { Color(red: r, green: g, blue: b) }
    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var isDark: Bool { luminance < 0.5 }

    // MARK: HSL 转换

    func toHSL() -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        var h: Double = 0
        if delta > 0 {
            if maxC == r {
                h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = 60 * ((b - r) / delta + 2)
            } else {
                h = 60 * ((r - g) / delta + 4)
            }
        }
        if h < 0 { h += 360 }
        let l = (maxC + minC) / 2
        let s = delta == 0 ? 0 : delta / (1 - abs(2 * l - 1))
        return (h, s, l)
    }

    static func fromHSL(h: Double, s: Double, l: Double) -> RGBColor {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(hp) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = l - c / 2
        return RGBColor(r: r1 + m, g: g1 + m, b: b1 + m)
    }

    func withSaturation(_ s: Double) -> RGBColor {
        let hsl = toHSL()
        return RGBColor.fromHSL(h: hsl.h, s: s, l: hsl.l)
    }

    func withLightness(_ l: Double) -> RGBColor {
        let hsl = toHSL()
        return RGBColor.fromHSL(h: hsl.h, s: hsl.s, l: l)
    }
}

// MARK: - 播放器动态调色板

struct CoverPalette {
    var backgroundTop: Color
    var backgroundBottom: Color
    var accent: Color
    var accentSoft: Color
    var text: Color
    var secondary: Color
    var glassTint: Color

    /// 无封面 / 提取失败时回退到全局主题色，保证任何场景都有可读配色
    static func fallback(colorScheme: ColorScheme) -> CoverPalette {
        let accent = Color.beansHighlight
        return CoverPalette(
            backgroundTop: Color(uiColor: .beansBackground),
            backgroundBottom: Color(uiColor: .beansBackground).opacity(0.86),
            accent: accent,
            accentSoft: accent.opacity(0.28),
            text: Color(uiColor: .beansLabel),
            secondary: Color(uiColor: .beansSecondary),
            glassTint: accent
        )
    }

    /// 由封面主色生成整套播放器配色：
    /// 背景降饱和（适合大面积）、强调色提饱和（按钮/进度条/高亮）、文字按背景亮度自动黑白
    static func make(dominant: RGBColor?, colorScheme: ColorScheme) -> CoverPalette {
        guard let c = dominant else { return fallback(colorScheme: colorScheme) }
        let dark = colorScheme == .dark

        let bgBase = c.withSaturation(dark ? 0.26 : 0.32)
        let bgTop = bgBase.withLightness(dark ? 0.20 : 0.74)
        let bgBottom = bgBase.withLightness(dark ? 0.08 : 0.56)

        let accentRGB = c.withSaturation(dark ? 0.68 : 0.62).withLightness(dark ? 0.72 : 0.50)
        let accent = accentRGB.color

        let text: Color = bgTop.luminance > 0.52
            ? Color(red: 0.11, green: 0.11, blue: 0.13)
            : Color(red: 0.98, green: 0.98, blue: 0.99)

        return CoverPalette(
            backgroundTop: bgTop.color,
            backgroundBottom: bgBottom.color,
            accent: accent,
            accentSoft: accent.opacity(0.26),
            text: text,
            secondary: text.opacity(0.66),
            glassTint: accent
        )
    }
}

// MARK: - 主色提取器（缩略图色相聚类，纯 CPU 极快）

enum PaletteExtractor {
    /// 把封面缩到 48x48 后按色相 16 桶聚类，取最大簇平均色
    static func dominantColor(in image: UIImage) -> RGBColor? {
        let size = 48
        guard let cg = image.cgImage else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        var buckets = Array(repeating: (count: 0, r: 0.0, g: 0.0, b: 0.0), count: 16)
        for i in 0..<(size * size) {
            let off = i * 4
            let a = Double(pixels[off + 3]) / 255
            guard a > 0.85 else { continue }
            let r = Double(pixels[off]) / 255
            let g = Double(pixels[off + 1]) / 255
            let b = Double(pixels[off + 2]) / 255
            let hsl = RGBColor(r: r, g: g, b: b).toHSL()
            // 过滤纯黑 / 纯白 / 极暗像素，避免污染主色
            guard hsl.l > 0.09, hsl.l < 0.93 else { continue }
            let bucket = min(15, Int(hsl.h / 360 * 16))
            let weight = 0.30 + hsl.s * 0.70
            buckets[bucket].count += 1
            buckets[bucket].r += r * weight
            buckets[bucket].g += g * weight
            buckets[bucket].b += b * weight
        }
        guard let best = buckets.max(by: { $0.count < $1.count }), best.count > 0 else { return nil }
        let n = Double(best.count)
        return RGBColor(r: best.r / n, g: best.g / n, b: best.b / n)
    }
}