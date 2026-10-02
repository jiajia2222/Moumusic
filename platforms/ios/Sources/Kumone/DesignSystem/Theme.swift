import SwiftUI

/// Design tokens: color, radius, spacing, layout metrics.
enum Theme {
    /// NetEase red, tuned slightly warmer for macOS.
    static var accent: Color { AppAccent.current.color }
    static var accentDeep: Color { AppAccent.current.deepColor }

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [AppAccent.current.lightColor, accentDeep],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    enum Radius {
        static let badge: CGFloat = 4
        static let small: CGFloat = 6
        static let standard: CGFloat = 8
        static let large: CGFloat = 12
        static let panel: CGFloat = 20
    }

    enum Layout {
        static let contentInset: CGFloat = 24
        static let cardSize: CGFloat = 160
        /// Row height for a shelf of cover cards: artwork, then up to two lines
        /// of title and one of subtitle.
        static let coverShelfHeight: CGFloat = 226
        /// Row height for a shelf of artist cards: circular artwork, one name.
        static let artistShelfHeight: CGFloat = 196
        static let sidebarWidth: CGFloat = 220
        static let playerBarHeight: CGFloat = 56
        /// Gap between the floating player bar and the window's bottom edge.
        /// Must match the bar's own `.padding(.bottom,)` in PlayerBar.
        static let playerBarBottomMargin: CGFloat = 10
        /// Bottom inset pages need so scrolled content clears the floating bar.
        static var playerChromeClearance: CGFloat { playerBarHeight + playerBarBottomMargin }
        static let minWindowWidth: CGFloat = 1020
        /// Width the split view's divider occupies between the two columns.
        static let splitDividerWidth: CGFloat = 8
        /// Window minimum while the sidebar is collapsed. The window-wide
        /// minimum is a *content* constraint, so with the sidebar hidden it
        /// lands entirely on the detail column; restoring the sidebar would
        /// then add its width on top and `.contentMinSize` would widen the
        /// window every time the now-playing page is dismissed (#19).
        /// Subtracting the sidebar here keeps the restored total at
        /// `minWindowWidth`.
        static var minWindowWidthSidebarCollapsed: CGFloat {
            minWindowWidth - sidebarWidth - splitDividerWidth
        }
        static let minWindowHeight: CGFloat = 640
        static let defaultWindowWidth: CGFloat = 1200
        static let defaultWindowHeight: CGFloat = 780
    }
}

/// Motion tokens (mirrors kaset's `AppAnimation`).
enum AppAnimation {
    static let quick = Animation.easeOut(duration: 0.15)
    static let standard = Animation.easeInOut(duration: 0.25)
    static let smooth = Animation.easeInOut(duration: 0.35)
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.7)
    static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.6)
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.8)

    static let staggerDelay = 0.04
    static let maxStaggerDelay = 0.4

    static func stagger(for index: Int) -> Double {
        min(Double(index) * staggerDelay, maxStaggerDelay)
    }
}

extension View {
    /// `scrollClipDisabled` is iOS 17 / macOS 14; older systems clip normally.
    @ViewBuilder
    func compatScrollClipDisabled() -> some View {
        if #available(iOS 17.0, macOS 14.0, *) { scrollClipDisabled() } else { self }
    }

    /// Hides the toolbar background; `toolbarBackgroundVisibility` is
    /// macOS 15+/iOS 18+, so iOS 17 falls back to `toolbarBackground`.
    @ViewBuilder
    func compatHiddenToolbarBackground() -> some View {
        #if os(macOS)
        toolbarBackgroundVisibility(.hidden, for: .automatic)
        #else
        if #available(iOS 18.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .automatic)
        } else {
            toolbarBackground(.hidden, for: .navigationBar)
        }
        #endif
    }

    /// `presentationBackground` was added in iOS 16.4. Keep sheets usable on
    /// the iOS 16.0–16.3 deployment floor by leaving the system sheet surface
    /// unchanged on those releases.
    @ViewBuilder
    func compatPresentationBackground<S: ShapeStyle>(_ style: S) -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) {
            presentationBackground(style)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Glass background with a graceful material fallback on macOS 15.
    func compatGlass(interactive: Bool = false, in shape: some Shape) -> some View {
        modifier(CompatGlassModifier(interactive: interactive, shape: AnyShape(shape)))
    }
}

/// Glass background; "关闭液态模式" swaps it for a plain material.
private struct CompatGlassModifier: ViewModifier {
    let interactive: Bool
    let shape: AnyShape
    @AppStorage(AppAppearanceKeys.disableLiquid) private var disableLiquid = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if disableLiquid {
            content.background(.ultraThinMaterial, in: shape)
        } else {
            glass(content)
        }
    }

    @ViewBuilder
    private func glass(_ self_: Content) -> some View {
        let self__ = self_
        #if os(macOS)
        if #available(macOS 26.0, *) {
            self__.glassEffect(.regular, in: shape)
        } else {
            self__.background(.ultraThinMaterial, in: shape)
        }
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            self__.glassEffect(.regular, in: shape)
        } else {
            self__.background(.ultraThinMaterial, in: shape)
        }
        #else
        self__.background(.ultraThinMaterial, in: shape)
        #endif
    }
}
