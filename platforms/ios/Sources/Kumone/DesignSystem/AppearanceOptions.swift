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

    private let orbs: [Orb] = (0..<9).map { index in
        Orb(
            id: index,
            x: Double((index * 37) % 100) / 100,
            y: Double((index * 53) % 100) / 100,
            size: 70 + Double((index * 29) % 90),
            speed: 0.10 + Double(index % 4) * 0.04,
            phase: Double(index) * 0.9)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                ForEach(orbs) { orb in
                    Circle()
                        .fill(Theme.accent.opacity(0.10))
                        .frame(width: orb.size, height: orb.size)
                        .blur(radius: 18)
                        .position(
                            x: proxy.size.width * (orb.x + 0.06 * sin(time * orb.speed + orb.phase)),
                            y: proxy.size.height * (orb.y + 0.08 * cos(time * orb.speed * 0.8 + orb.phase)))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
