import SwiftUI

/// Vector platform marks. They are drawn as SwiftUI shapes (no bitmap
/// assets); the NetEase and Bilibili outlines come from Simple Icons (CC0).
struct SVGPathShape: Shape {
    let data: String
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / viewBox
        let dx = rect.minX + (rect.width - viewBox * scale) / 2
        let dy = rect.minY + (rect.height - viewBox * scale) / 2
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
        return SVGPathParser.parse(data).applying(transform)
    }
}

enum SVGPathParser {
    private struct Reader {
        let chars: [Character]
        var index = 0

        init(_ text: String) { chars = Array(text) }

        var atEnd: Bool { index >= chars.count }

        mutating func skipSeparators() {
            while index < chars.count,
                  chars[index] == " " || chars[index] == "," || chars[index] == "\n" || chars[index] == "\t" {
                index += 1
            }
        }

        mutating func peekIsCommand() -> Bool {
            skipSeparators()
            return index < chars.count && chars[index].isLetter
        }

        mutating func command() -> Character? {
            skipSeparators()
            guard index < chars.count, chars[index].isLetter else { return nil }
            defer { index += 1 }
            return chars[index]
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var j = index
            var text = ""
            if j < chars.count, chars[j] == "-" || chars[j] == "+" {
                text.append(chars[j])
                j += 1
            }
            var seenDot = false
            var digits = false
            while j < chars.count {
                let ch = chars[j]
                if ch.isNumber {
                    text.append(ch)
                    digits = true
                    j += 1
                } else if ch == "." && !seenDot {
                    seenDot = true
                    text.append(ch)
                    j += 1
                } else {
                    break
                }
            }
            guard digits else { return nil }
            index = j
            return CGFloat(Double(text) ?? 0)
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < chars.count, chars[index] == "0" || chars[index] == "1" else { return nil }
            defer { index += 1 }
            return chars[index] == "1"
        }
    }

    static func parse(_ data: String) -> Path {
        var reader = Reader(data)
        var path = Path()
        var command: Character = "M"
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?

        while !reader.atEnd {
            if reader.peekIsCommand() {
                guard let next = reader.command() else { break }
                command = next
            } else if reader.atEnd {
                break
            }
            let relative = command.isLowercase
            let base = relative ? current : .zero
            var cubicControl: CGPoint?

            switch command {
            case "M", "m":
                guard let x = reader.number(), let y = reader.number() else { return path }
                current = CGPoint(x: base.x + x, y: base.y + y)
                subpathStart = current
                path.move(to: current)
                command = relative ? "l" : "L"
            case "L", "l":
                guard let x = reader.number(), let y = reader.number() else { return path }
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addLine(to: current)
            case "H", "h":
                guard let x = reader.number() else { return path }
                current = CGPoint(x: base.x + x, y: current.y)
                path.addLine(to: current)
            case "V", "v":
                guard let y = reader.number() else { return path }
                current = CGPoint(x: current.x, y: base.y + y)
                path.addLine(to: current)
            case "C", "c":
                guard let x1 = reader.number(), let y1 = reader.number(),
                      let x2 = reader.number(), let y2 = reader.number(),
                      let x = reader.number(), let y = reader.number() else { return path }
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                path.addCurve(to: CGPoint(x: base.x + x, y: base.y + y),
                              control1: CGPoint(x: base.x + x1, y: base.y + y1),
                              control2: c2)
                current = CGPoint(x: base.x + x, y: base.y + y)
                cubicControl = c2
            case "S", "s":
                guard let x2 = reader.number(), let y2 = reader.number(),
                      let x = reader.number(), let y = reader.number() else { return path }
                let c1 = lastCubicControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                path.addCurve(to: CGPoint(x: base.x + x, y: base.y + y), control1: c1, control2: c2)
                current = CGPoint(x: base.x + x, y: base.y + y)
                cubicControl = c2
            case "Q", "q":
                guard let x1 = reader.number(), let y1 = reader.number(),
                      let x = reader.number(), let y = reader.number() else { return path }
                path.addQuadCurve(to: CGPoint(x: base.x + x, y: base.y + y),
                                  control: CGPoint(x: base.x + x1, y: base.y + y1))
                current = CGPoint(x: base.x + x, y: base.y + y)
            case "A", "a":
                guard let rx = reader.number(), let ry = reader.number(),
                      let rotation = reader.number(),
                      let large = reader.flag(), let sweep = reader.flag(),
                      let x = reader.number(), let y = reader.number() else { return path }
                let end = CGPoint(x: base.x + x, y: base.y + y)
                addArc(to: &path, from: current, rx: rx, ry: ry, rotation: rotation,
                       large: large, sweep: sweep, end: end)
                current = end
            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
            default:
                return path
            }
            lastCubicControl = cubicControl
        }
        return path
    }

    private static func addArc(
        to path: inout Path, from p0: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
        rotation: CGFloat, large: Bool, sweep: Bool, end p1: CGPoint
    ) {
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2
        let dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = sqrt(max(0, numerator / denominator))
        if large == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = atan2((y1p - cyp) / ry, (x1p - cxp) / rx)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        func map(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cosPhi * u - ry * sinPhi * v,
                    y: cy + rx * sinPhi * u + ry * cosPhi * v)
        }
        var theta = theta1
        for _ in 0..<segments {
            let c1 = cos(theta), s1 = sin(theta)
            let c2 = cos(theta + step), s2 = sin(theta + step)
            path.addCurve(
                to: map(c2, s2),
                control1: map(c1 - t * s1, s1 + t * c1),
                control2: map(c2 + t * s2, s2 - t * c2))
            theta += step
        }
    }
}

/// Brand-coloured vector mark for a music platform.
struct PlatformGlyph: View {
    let platform: LXCatalogPlatform

    private static let neteasePath = "M13.046 9.388a3.919 3.919 0 0 0-.66.19c-.809.312-1.447.991-1.666 1.775a2.269 2.269 0 0 0-.074.81c.048.546.333 1.05.764 1.35a1.483 1.483 0 0 0 2.01-.286c.406-.531.355-1.183.24-1.636-.098-.387-.22-.816-.345-1.249a64.76 64.76 0 0 1-.269-.954zm-.82 10.07c-3.984 0-7.224-3.24-7.224-7.223 0-.98.226-3.02 1.884-4.822A7.188 7.188 0 0 1 9.502 5.6a.792.792 0 1 1 .587 1.472 5.619 5.619 0 0 0-2.795 2.462 5.538 5.538 0 0 0-.707 2.7 5.645 5.645 0 0 0 5.638 5.638c1.844 0 3.627-.953 4.542-2.428 1.042-1.68.772-3.931-.627-5.238a3.299 3.299 0 0 0-1.437-.777c.172.589.334 1.18.494 1.772.284 1.12.1 2.181-.519 2.989-.39.51-.956.888-1.592 1.064a3.038 3.038 0 0 1-2.58-.44 3.45 3.45 0 0 1-1.44-2.514c-.04-.467.002-.93.128-1.376.35-1.256 1.356-2.339 2.622-2.826a5.5 5.5 0 0 1 .823-.246l-.134-.505c-.37-1.371.25-2.579 1.547-3.007.329-.109.68-.145 1.025-.105.792.09 1.476.592 1.709 1.023.258.507-.096 1.153-.706 1.153a.788.788 0 0 1-.54-.213c-.088-.08-.163-.174-.259-.247a.825.825 0 0 0-.632-.166.807.807 0 0 0-.634.551c-.056.191-.031.406.02.595.07.256.159.597.217.82 1.11.098 2.162.54 2.97 1.296 1.974 1.844 2.35 4.886.892 7.233-1.197 1.93-3.509 3.177-5.889 3.177zM0 12c0 6.627 5.373 12 12 12s12-5.373 12-12S18.627 0 12 0 0 5.373 0 12Z"

    var body: some View {
        switch platform {
        case .wy:
            brandImage("BrandNetease")
        case .tx:
            brandImage("BrandQQ")
        case .kg:
            brandImage("BrandKugou")
        case .kw:
            letterMark("K", Color(red: 1.0, green: 0.55, blue: 0.0))
        case .mg:
            letterMark("M", Color(red: 0.93, green: 0.2, blue: 0.55))
        case .sd:
            letterMark("S", .pink)
        case .aggregate:
            Image(systemName: "square.stack.3d.up.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Theme.accent)
        }
    }

    /// Brand artwork taken from the Beans 2.0.3 asset catalog.
    private func brandImage(_ name: String) -> some View {
        Image(name, bundle: .module)
            .resizable()
            .scaledToFit()
    }

    private func letterMark(_ letter: String, _ color: Color) -> some View {
        GeometryReader { proxy in
            ZStack {
                Circle().fill(color)
                Text(letter)
                    .font(.system(size: proxy.size.height * 0.58, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}
