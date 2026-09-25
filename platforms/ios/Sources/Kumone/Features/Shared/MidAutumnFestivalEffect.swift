#if os(iOS)
import SwiftUI

/// A lightweight Mid-Autumn decoration for the iOS shell.
///
/// It is deliberately rendered as a non-interactive overlay so it cannot
/// interfere with navigation, the system Liquid Glass tab bar, or the mini
/// player.  The animation also stops when Reduce Motion is enabled.
struct MidAutumnFestivalEffect: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowPulse = false

    private let stars: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
        (0.14, 0.15, 2.5, 0.52),
        (0.28, 0.23, 1.8, 0.42),
        (0.56, 0.13, 2.2, 0.46),
        (0.72, 0.27, 1.6, 0.38),
        (0.87, 0.16, 2.0, 0.48),
        (0.63, 0.39, 1.4, 0.32),
        (0.18, 0.43, 1.5, 0.34),
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(Array(stars.enumerated()), id: \.offset) { _, star in
                    Circle()
                        .fill(Color.white.opacity(star.opacity))
                        .frame(width: star.size, height: star.size)
                        .position(
                            x: proxy.size.width * star.x,
                            y: max(48, proxy.size.height * star.y)
                        )
                }

                moon
                    .position(
                        x: proxy.size.width - 62,
                        y: max(72, proxy.safeAreaInsets.top + 78)
                    )

                Image(systemName: "hare.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.30))
                    .shadow(color: .orange.opacity(0.28), radius: 8)
                    .position(
                        x: proxy.size.width - 115,
                        y: max(124, proxy.safeAreaInsets.top + 132)
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            glowPulse = true
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 4.2).repeatForever(autoreverses: true),
            value: glowPulse
        )
    }

    private var moon: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.96),
                            Color(red: 1.0, green: 0.84, blue: 0.45).opacity(0.92),
                            Color.orange.opacity(0.72),
                        ],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: 42
                    )
                )
                .frame(width: 62, height: 62)
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.42), lineWidth: 1)
                }
                .shadow(
                    color: Color.orange.opacity(glowPulse ? 0.34 : 0.18),
                    radius: glowPulse ? 22 : 14
                )

            // Soft craters keep the moon from looking like a plain icon while
            // remaining subtle against both light and dark wallpapers.
            Circle()
                .fill(Color.orange.opacity(0.16))
                .frame(width: 10, height: 10)
                .offset(x: -14, y: 9)
            Circle()
                .fill(Color.orange.opacity(0.12))
                .frame(width: 7, height: 7)
                .offset(x: 12, y: -13)
            Circle()
                .fill(Color.orange.opacity(0.10))
                .frame(width: 5, height: 5)
                .offset(x: 14, y: 15)
        }
    }
}
#endif
