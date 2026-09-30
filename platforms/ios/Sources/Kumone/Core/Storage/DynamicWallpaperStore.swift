#if os(iOS)
import Foundation
import SwiftUI

enum DynamicWallpaperKind: String, CaseIterable, Identifiable, Sendable {
    case aurora
    case metaballs
    case water
    case starNest
    case grainGradient

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aurora: return "极光"
        case .metaballs: return "流体"
        case .water: return "水波"
        case .starNest: return "星云"
        case .grainGradient: return "柔和彩色"
        }
    }
}

/// A lightweight native counterpart to Beans' DynamicWallpaperStore. It uses
/// SwiftUI shapes instead of shipping a binary renderer, so it stays safe for
/// iOS 16 through iOS 27 and automatically pauses when the app is inactive.
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
    }

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    @Published var kind: DynamicWallpaperKind {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: Keys.kind) }
    }
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

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        kind = defaults.string(forKey: Keys.kind)
            .flatMap(DynamicWallpaperKind.init(rawValue:)) ?? .aurora
        speed = defaults.object(forKey: Keys.speed) as? Double ?? 0.35
        intensity = defaults.object(forKey: Keys.intensity) as? Double ?? 0.78
        syncToApp = defaults.object(forKey: Keys.syncToApp) as? Bool ?? true
        syncToPlayer = defaults.object(forKey: Keys.syncToPlayer) as? Bool ?? true
    }
}

struct MoumusicDynamicWallpaperView: View {
    let kind: DynamicWallpaperKind
    let speed: Double
    let intensity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var paused: Bool { reduceMotion || scenePhase != .active }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: paused)) { context in
            wallpaper(at: context.date.timeIntervalSinceReferenceDate)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func wallpaper(at time: TimeInterval) -> some View {
        let phase = (time.truncatingRemainder(dividingBy: 180) * max(0.05, speed))
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.06, blue: 0.13),
                         Color(red: 0.08, green: 0.03, blue: 0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            switch kind {
            case .aurora:
                orb(.cyan, size: 420, phase: phase, x: -0.35, y: -0.18)
                orb(.blue, size: 520, phase: phase * 0.8, x: 0.34, y: -0.12)
                orb(.purple, size: 460, phase: phase * 0.65, x: 0.18, y: 0.35)
                orb(.green, size: 360, phase: phase * 0.5, x: -0.25, y: 0.38)
            case .metaballs:
                orb(.mint, size: 300, phase: phase * 1.3, x: -0.25, y: -0.18)
                orb(.teal, size: 360, phase: phase, x: 0.25, y: -0.08)
                orb(.indigo, size: 390, phase: phase * 0.75, x: 0.05, y: 0.3)
                orb(.pink, size: 240, phase: phase * 1.4, x: -0.35, y: 0.3)
            case .water:
                LinearGradient(
                    colors: [.teal.opacity(0.65), .blue.opacity(0.24), .indigo.opacity(0.66)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                WaveShape(phase: phase, height: 0.36)
                    .fill(.cyan.opacity(0.18))
                WaveShape(phase: phase * 0.7 + 1.6, height: 0.55)
                    .fill(.blue.opacity(0.18))
            case .starNest:
                ForEach(0..<42, id: \.self) { index in
                    let progress = CGFloat(index + 1) / 42
                    let angle = phase * 0.08 + Double(index) * 0.83
                    Circle()
                        .fill(index.isMultiple(of: 3) ? .cyan : .white)
                        .frame(width: 1.5 + progress * 3, height: 1.5 + progress * 3)
                        .offset(x: CGFloat(cos(angle)) * (80 + progress * 260),
                                y: CGFloat(sin(angle)) * (60 + progress * 360))
                        .opacity(0.25 + (1 - progress) * 0.6)
                }
                RadialGradient(colors: [.purple.opacity(0.32), .clear], center: .center,
                               startRadius: 10, endRadius: 420)
            case .grainGradient:
                AngularGradient(colors: [.orange, .pink, .purple, .blue, .teal, .orange],
                                center: .center)
                    .rotationEffect(.radians(phase * 0.02))
                Rectangle().fill(.white.opacity(0.05))
                    .blendMode(.overlay)
            }
        }
        .opacity(intensity.clamped(to: 0...1))
        .blur(radius: kind == .starNest ? 0 : 12)
        .drawingGroup()
    }

    private func orb(_ color: Color, size: CGFloat, phase: Double, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(0.75))
            .frame(width: size, height: size)
            .blur(radius: size * 0.24)
            .offset(
                x: x * 430 + CGFloat(sin(phase * 0.14)) * 90,
                y: y * 780 + CGFloat(cos(phase * 0.11)) * 110
            )
    }
}

private struct WaveShape: Shape {
    let phase: Double
    let height: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let baseline = rect.height * height
        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: baseline))
        for step in 0...48 {
            let x = rect.width * CGFloat(step) / 48
            let wave = sin(Double(step) * 0.38 + phase) * 26
            path.addLine(to: CGPoint(x: x, y: baseline + wave))
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
#endif
