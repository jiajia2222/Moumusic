import CoreText
import SwiftUI

/// Renders Japanese ruby text with Core Text so readings stay attached to the
/// correct kanji and long lines wrap within the lyric panel.
enum RubyAttributedString {
    struct Style {
        var size: CGFloat
        var weight: PlatformFont.Weight
        var color: PlatformColor
        var rubyColor: PlatformColor
        var rubyScale: CGFloat
        var alignment: NSTextAlignment
        var rounded: Bool
    }

    static func make(_ segments: [RubySegment], style: Style, alphas: [Double]? = nil) -> NSAttributedString {
        let baseFont = font(style.size, style.weight, style.rounded)
        let rubyFont = font(style.size * style.rubyScale, .medium, style.rounded)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: style.color,
            .paragraphStyle: paragraph,
        ]

        let output = NSMutableAttributedString()
        var cursor = 0
        for segment in segments {
            let start = cursor
            cursor += segment.text.count
            let span = alphas.map { alpha in
                (start..<cursor).map { $0 < alpha.count ? alpha[$0] : 1 }
            }
            guard let ruby = segment.ruby, !ruby.isEmpty else {
                output.append(tinted(segment.text, baseAttributes, span, style.color))
                continue
            }
            let level: Double
            if let span, !span.isEmpty {
                level = span.reduce(0, +) / Double(span.count)
            } else {
                level = 1
            }
            let annotation = CTRubyAnnotationCreateWithAttributes(
                .center,
                .auto,
                .before,
                ruby as CFString,
                [
                    kCTFontAttributeName: rubyFont,
                    kCTForegroundColorAttributeName: style.rubyColor.faded(to: level),
                ] as CFDictionary
            )
            var attributes = baseAttributes
            attributes[.foregroundColor] = style.color.faded(to: level)
            attributes[NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)] = annotation
            output.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return output
    }

    private static func tinted(
        _ text: String,
        _ attributes: [NSAttributedString.Key: Any],
        _ alphas: [Double]?,
        _ color: PlatformColor
    ) -> NSAttributedString {
        let piece = NSMutableAttributedString(string: text, attributes: attributes)
        guard let alphas else { return piece }
        var location = 0
        for (index, character) in text.enumerated() {
            let length = (String(character) as NSString).length
            if index < alphas.count {
                piece.addAttribute(
                    .foregroundColor,
                    value: color.faded(to: alphas[index]),
                    range: NSRange(location: location, length: length)
                )
            }
            location += length
        }
        return piece
    }

    static func fittedSize(_ string: NSAttributedString, width: CGFloat) -> CGSize {
        guard width > 0, string.length > 0 else { return .zero }
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        return CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
    }

    static func draw(_ string: NSAttributedString, in rect: CGRect, context: CGContext) {
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, 0),
            nil,
            CGSize(width: rect.width, height: .greatestFiniteMagnitude),
            nil
        )
        let height = max(rect.height, ceil(fitted.height))
        let path = CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRangeMake(0, 0),
            CGPath(rect: path, transform: nil),
            nil
        )
        CTFrameDraw(frame, context)
    }

    private static func font(_ size: CGFloat, _ weight: PlatformFont.Weight, _ rounded: Bool) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
#if os(macOS)
        return PlatformFont(descriptor: descriptor, size: size) ?? base
#else
        return PlatformFont(descriptor: descriptor, size: size)
#endif
    }
}

struct RubyText: View {
    private let segments: [RubySegment]
    private let size: CGFloat
    private let weight: Font.Weight
    private let color: Color
    private let rubyColor: Color
    private let rubyScale: CGFloat
    private let alignment: NSTextAlignment
    private let rounded: Bool
    private let alphas: [Double]?

    init(
        segments: [RubySegment],
        size: CGFloat,
        weight: Font.Weight = .regular,
        color: Color = .primary,
        rubyColor: Color? = nil,
        rubyScale: CGFloat = 0.5,
        alignment: NSTextAlignment = .left,
        rounded: Bool = false,
        alphas: [Double]? = nil
    ) {
        self.segments = segments
        self.size = size
        self.weight = weight
        self.color = color
        self.rubyColor = rubyColor ?? color.opacity(0.75)
        self.rubyScale = rubyScale
        self.alignment = alignment
        self.rounded = rounded
        self.alphas = alphas
    }

    var body: some View {
        let style = RubyAttributedString.Style(
            size: size,
            weight: weight.platform,
            color: PlatformColor(color),
            rubyColor: PlatformColor(rubyColor),
            rubyScale: rubyScale,
            alignment: alignment,
            rounded: rounded
        )
        let attributed = RubyAttributedString.make(segments, style: style, alphas: alphas)

        return RubyTextLayout(attributed: attributed) {
            Canvas(rendersAsynchronously: false) { context, canvasSize in
                context.withCGContext { cgContext in
                    cgContext.saveGState()
                    cgContext.textMatrix = .identity
                    cgContext.translateBy(x: 0, y: canvasSize.height)
                    cgContext.scaleBy(x: 1, y: -1)
                    RubyAttributedString.draw(
                        attributed,
                        in: CGRect(origin: .zero, size: canvasSize),
                        context: cgContext
                    )
                    cgContext.restoreGState()
                }
            }
        }
    }
}

private final class AttributedBox: @unchecked Sendable {
    let string: NSAttributedString
    init(_ string: NSAttributedString) { self.string = string }
}

private struct RubyTextLayout: Layout {
    private let box: AttributedBox

    init(attributed: NSAttributedString) {
        box = AttributedBox(attributed)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard let proposed = proposal.width, proposed.isFinite, proposed > 0 else {
            let fitted = RubyAttributedString.fittedSize(box.string, width: .greatestFiniteMagnitude)
            return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
        }
        let fitted = RubyAttributedString.fittedSize(box.string, width: proposed)
        return CGSize(width: proposed, height: ceil(fitted.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

private extension Font.Weight {
    var platform: PlatformFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

private extension PlatformColor {
    func faded(to level: Double) -> PlatformColor {
        withAlphaComponent(cgColor.alpha * CGFloat(level))
    }
}
