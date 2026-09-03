import SwiftUI

/// A small vector tonearm that lifts while paused and settles onto the record
/// while playing. It uses no platform-specific drawing APIs.
public struct VinylTonearmView: View {
    public let isPlaying: Bool
    public let height: CGFloat
    public let reduceMotion: Bool

    public init(isPlaying: Bool, height: CGFloat = 175, reduceMotion: Bool = false) {
        self.isPlaying = isPlaying
        self.height = height
        self.reduceMotion = reduceMotion
    }

    public var body: some View {
        let width = height * 0.58
        let pivotSize = width * 0.46

        ZStack(alignment: .top) {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.28), Color(white: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: pivotSize, height: pivotSize)
                .overlay {
                    Circle()
                        .fill(Color(white: 0.12))
                        .padding(pivotSize * 0.19)
                }
                .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                .zIndex(2)

            TonearmPath()
                .stroke(Color.black.opacity(0.36), lineWidth: max(5, width * 0.09))
                .blur(radius: 2)
                .offset(x: 2, y: 3)

            TonearmPath()
                .stroke(
                    LinearGradient(colors: [.white.opacity(0.96), .white.opacity(0.52), .white.opacity(0.90), .white.opacity(0.38)], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: max(3.5, width * 0.058), lineCap: .round, lineJoin: .round)
                )
                .rotationEffect(.degrees(isPlaying ? 0 : -32), anchor: UnitPoint(x: 0.5, y: pivotSize * 0.5 / height))
                .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.74), value: isPlaying)
                .zIndex(1)
        }
        .frame(width: width, height: height, alignment: .top)
    }
}

private struct TonearmPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.width * 0.5, y: 0)
        let first = CGPoint(x: rect.width * 0.58, y: rect.height * 0.28)
        let second = CGPoint(x: rect.width * 0.42, y: rect.height * 0.55)
        let end = CGPoint(x: rect.width * 0.31, y: rect.height * 0.74)
        path.move(to: start)
        path.addCurve(to: first, control1: CGPoint(x: rect.width * 0.52, y: rect.height * 0.1), control2: CGPoint(x: rect.width * 0.58, y: rect.height * 0.2))
        path.addCurve(to: second, control1: CGPoint(x: rect.width * 0.58, y: rect.height * 0.38), control2: CGPoint(x: rect.width * 0.45, y: rect.height * 0.48))
        path.addCurve(to: end, control1: CGPoint(x: rect.width * 0.38, y: rect.height * 0.62), control2: CGPoint(x: rect.width * 0.33, y: rect.height * 0.70))
        return path
    }
}
