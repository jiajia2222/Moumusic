#if os(macOS)
import AppKit
import SwiftUI

public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
public typealias PlatformView = NSView
public typealias PlatformFont = NSFont
public typealias PlatformViewRepresentable = NSViewRepresentable

public extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

public extension PlatformImage {
    /// Renders the image into a circle of the given point diameter.
    func circularCropped(diameter: CGFloat) -> PlatformImage {
        let target = NSImage(size: NSSize(width: diameter, height: diameter))
        target.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        NSBezierPath(ovalIn: rect).addClip()
        let sourceAspect = size.width / max(size.height, 1)
        var drawRect = rect
        if sourceAspect > 1 {
            drawRect.size.width = diameter * sourceAspect
            drawRect.origin.x = -(drawRect.width - diameter) / 2
        } else if sourceAspect < 1 {
            drawRect.size.height = diameter / sourceAspect
            drawRect.origin.y = -(drawRect.height - diameter) / 2
        }
        draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
        target.unlockFocus()
        return target
    }

    var cgImageRef: CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

public enum Platform {
    public static var isReduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static func copyToPasteboard(string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    public static var windowBackgroundColor: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}

#elseif os(iOS)
import UIKit
import SwiftUI

public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
public typealias PlatformView = UIView
public typealias PlatformFont = UIFont
public typealias PlatformViewRepresentable = UIViewRepresentable

public extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

public extension PlatformImage {
    /// Renders the image into a circle of the given point diameter.
    func circularCropped(diameter: CGFloat) -> PlatformImage {
        let size = CGSize(width: diameter, height: diameter)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(ovalIn: rect).addClip()
            let sourceAspect = self.size.width / max(self.size.height, 1)
            var drawRect = rect
            if sourceAspect > 1 {
                drawRect.size.width = diameter * sourceAspect
                drawRect.origin.x = -(drawRect.width - diameter) / 2
            } else if sourceAspect < 1 {
                drawRect.size.height = diameter / sourceAspect
                drawRect.origin.y = -(drawRect.height - diameter) / 2
            }
            self.draw(in: drawRect)
        }
    }

    var cgImageRef: CGImage? {
        cgImage
    }
}

public enum Platform {
    public static var isReduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    public static func copyToPasteboard(string: String) {
        UIPasteboard.general.string = string
    }

    public static var windowBackgroundColor: Color {
        Color(uiColor: .systemBackground)
    }
}
#endif
