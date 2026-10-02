import SwiftUI

/// UserDefaults keys for the appearance options in 设置 → 外观与界面.
enum AppAppearanceKeys {
    static let accent = "moumusic.accentColor"
    static let disableLiquid = "moumusic.disableLiquidGlass"
    static let floatingEffects = "moumusic.floatingEffects"
}

/// Accent colour presets. The default keeps the original Moumusic red.
enum AppAccent: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink

    var id: String { rawValue }

    static var current: AppAccent {
        AppAccent(rawValue: UserDefaults.standard.string(forKey: AppAppearanceKeys.accent) ?? "") ?? .red
    }

    var displayName: String {
        switch self {
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .teal: return "青色"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .pink: return "粉色"
        }
    }

    private var rgb: (Double, Double, Double) {
        switch self {
        case .red: return (0.925, 0.286, 0.286)
        case .orange: return (0.97, 0.55, 0.16)
        case .yellow: return (0.93, 0.72, 0.12)
        case .green: return (0.22, 0.72, 0.42)
        case .teal: return (0.15, 0.68, 0.72)
        case .blue: return (0.20, 0.52, 0.95)
        case .purple: return (0.58, 0.38, 0.90)
        case .pink: return (0.93, 0.35, 0.62)
        }
    }

    var color: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }
    var lightColor: Color {
        Color(red: min(1, rgb.0 + 0.05), green: min(1, rgb.1 + 0.07), blue: min(1, rgb.2 + 0.07))
    }
    var deepColor: Color { Color(red: rgb.0 * 0.85, green: rgb.1 * 0.57, blue: rgb.2 * 0.57) }
}

/// Soft translucent orbs drifting across the whole app ("全局漂浮特效").
struct FloatingEffectOverlay: View {
    private struct Orb: Identifiable {
        let id: Int
        let x: Double
        let y: Double
        let size: Double
        let speed: Double
        let phase: Double
    }

    private static func makeOrbs() -> [Orb] {
        var result: [Orb] = []
        for index in 0..<9 {
            let x: Double = Double((index * 37) % 100) / 100.0
            let y: Double = Double((index * 53) % 100) / 100.0
            let size: Double = 70.0 + Double((index * 29) % 90)
            let speed: Double = 0.10 + Double(index % 4) * 0.04
            let phase: Double = Double(index) * 0.9
            result.append(Orb(id: index, x: x, y: y, size: size, speed: speed, phase: phase))
        }
        return result
    }

    private let orbs: [Orb] = FloatingEffectOverlay.makeOrbs()
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                ForEach(orbs) { orb in
                    Circle()
                        .fill(Theme.accent.opacity(0.10))
                        .frame(width: orb.size, height: orb.size)
                        .blur(radius: 18)
                        .position(position(for: orb, in: proxy.size, time: time))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func position(for orb: Orb, in size: CGSize, time: TimeInterval) -> CGPoint {
        let dx: Double = 0.06 * sin(time * orb.speed + orb.phase)
        let dy: Double = 0.08 * cos(time * orb.speed * 0.8 + orb.phase)
        return CGPoint(x: Double(size.width) * (orb.x + dx), y: Double(size.height) * (orb.y + dy))
    }
}

#if os(iOS)
import UIKit

/// Haptic feedback gated by the 触感反馈 setting (default on).
enum Haptics {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "moumusic.hapticsEnabled") as? Bool ?? true
    }

    static func tap() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
#endif

#if os(iOS)
/// Makes every UIKit container above this view transparent (hosting views,
/// navigation / tab controllers) so the wallpaper layer behind the tab
/// interface can show through. SwiftUI pages draw no background of their own.
struct ClearAncestorBackgrounds: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.scheduleClear()
    }

    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleClear()
        }

        func scheduleClear() {
            DispatchQueue.main.async { [weak self] in self?.clearAncestors() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.clearAncestors() }
        }

        private func clearAncestors() {
            var current: UIView? = superview
            while let view = current, !(view is UIWindow) {
                view.backgroundColor = .clear
                current = view.superview
            }
        }
    }
}
#endif
