import SwiftUI

// MARK: - DJ 视觉模式（节奏脉冲：封面背后随节拍扩散的光环 + 环绕彩带）
// 只在播放时运行动画（TimelineView paused 门控），暂停后静态显示，控制发热。

struct DJVisualView: View {
    let accent: Color
    let secondary: Color
    let isPlaying: Bool
    /// 强度 0~1
    var intensity: Double = 0.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isPlaying)) { context in
            Canvas { ctx, size in
                guard size.width > 0, size.height > 0 else { return }
                let t = context.date.timeIntervalSinceReferenceDate
                let w = size.width, h = size.height
                let cx = w * 0.5, cy = h * 0.42
                let rMax = min(w, h) * 0.9

                // 主光环：随节拍扩散（约 110 BPM）
                let beat = (t.truncatingRemainder(dividingBy: 0.55)) / 0.55
                let eased = beat * beat * (3 - 2 * beat)
                let r1 = rMax * (0.15 + 0.55 * eased)
                let a1 = 0.5 * (1 - eased) * intensity
                let g1 = Gradient(colors: [accent.opacity(a1), accent.opacity(0)])
                ctx.fill(
                    Path(ellipseIn: CGRect(x: cx - r1, y: cy - r1, width: r1 * 2, height: r1 * 2)),
                    with: .radialGradient(g1, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r1)
                )

                // 次色环：错半拍
                let beat2 = ((t + 0.275).truncatingRemainder(dividingBy: 0.55)) / 0.55
                let eased2 = beat2 * beat2 * (3 - 2 * beat2)
                let r2 = rMax * (0.2 + 0.5 * eased2)
                let a2 = 0.4 * (1 - eased2) * intensity
                let g2 = Gradient(colors: [secondary.opacity(a2), secondary.opacity(0)])
                ctx.fill(
                    Path(ellipseIn: CGRect(x: cx - r2, y: cy - r2, width: r2 * 2, height: r2 * 2)),
                    with: .radialGradient(g2, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r2)
                )

                // 环绕彩带：缓慢公转的光点链
                let angle = t * 0.25
                let segs = 7
                for i in 0..<segs {
                    let a = angle + Double(i) / Double(segs) * 2 * .pi
                    let px = cx + cos(a) * rMax * 0.34
                    let py = cy + sin(a) * rMax * 0.34
                    let r = rMax * 0.10
                    let g = Gradient(colors: [accent.opacity(0.16 * intensity), accent.opacity(0)])
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(g, center: CGPoint(x: px, y: py), startRadius: 0, endRadius: r)
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .drawingGroup()
    }
}
