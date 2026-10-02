import SwiftUI

/// A programmatic vinyl record so the player does not need another image asset.
public struct VinylRecordView: View {
    public let artworkImage: PlatformImage?
    public let size: CGFloat

    public init(artworkImage: PlatformImage?, size: CGFloat = 280) {
        self.artworkImage = artworkImage
        self.size = size
    }

    public var body: some View {
        let labelSize = size * 0.64
        let spindleSize = max(7, size * 0.032)

        ZStack {
            Circle()
                .fill(Color.black.opacity(0.42))
                .frame(width: size + 8, height: size + 8)
                .blur(radius: max(8, size * 0.045))
                .offset(y: size * 0.04)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.16), Color(white: 0.08), Color(white: 0.025)],
                        center: .center,
                        startRadius: size * 0.08,
                        endRadius: size * 0.52
                    )
                )
                .frame(width: size, height: size)
                .overlay {
                    Circle().stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .white.opacity(0.04), .black.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
                }

            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            .white.opacity(0.04), .white.opacity(0.16), .black.opacity(0.16),
                            .white.opacity(0.11), .black.opacity(0.12), .white.opacity(0.05)
                        ]),
                        center: .center
                    )
                )
                .frame(width: size - 4, height: size - 4)
                .opacity(0.9)

            ForEach(0..<18, id: \.self) { index in
                let factor = 0.68 + (Double(index) / 17) * 0.29
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(index % 4 == 0 ? 0.14 : 0.06), .black.opacity(0.42), .white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: index % 4 == 0 ? 0.8 : 0.45
                    )
                    .frame(width: size * factor, height: size * factor)
            }

            Circle()
                .fill(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.00),
                            .init(color: .white.opacity(0.22), location: 0.15),
                            .init(color: .clear, location: 0.28),
                            .init(color: .clear, location: 0.52),
                            .init(color: .white.opacity(0.14), location: 0.66),
                            .init(color: .clear, location: 0.82),
                            .init(color: .clear, location: 1.00)
                        ]),
                        center: .center,
                        angle: .degrees(35)
                    )
                )
                .frame(width: size - 2, height: size - 2)
                .blendMode(.screen)
                .allowsHitTesting(false)

            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: labelSize + 6, height: labelSize + 6)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)

                Group {
                    if let artworkImage {
                        Image(platformImage: artworkImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: "music.note")
                                .font(.system(size: labelSize * 0.35, weight: .light))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
                .frame(width: labelSize, height: labelSize)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(.black.opacity(0.45), lineWidth: 1.5) }

                Circle()
                    .stroke(.white.opacity(0.26), lineWidth: 0.8)
                    .frame(width: labelSize * 0.86, height: labelSize * 0.86)

                Circle()
                    .fill(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.45), .black.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: spindleSize * 2.4, height: spindleSize * 2.4)
                Circle()
                    .fill(Color(white: 0.04))
                    .frame(width: spindleSize, height: spindleSize)
            }
        }
        .frame(width: size + 8, height: size + 8)
    }
}
