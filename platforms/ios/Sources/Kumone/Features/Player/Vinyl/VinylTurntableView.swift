import SwiftUI

/// Interactive release-style vinyl stage: continuous rotation, tonearm state,
/// tap-to-open lyrics, and horizontal swipe-to-switch tracks.
public struct VinylTurntableView: View {
    public let artworkImage: PlatformImage?
    public let isPlaying: Bool
    public let trackId: Int?
    public let size: CGFloat
    public var onTap: (() -> Void)?
    public var onNextTrack: (() -> Void)?
    public var onPreviousTrack: (() -> Void)?

    @State private var rotationState = RecordRotationState()
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isTransitioningTrack = false

    public init(artworkImage: PlatformImage?, isPlaying: Bool, trackId: Int? = nil, size: CGFloat = 280, onTap: (() -> Void)? = nil, onNextTrack: (() -> Void)? = nil, onPreviousTrack: (() -> Void)? = nil) {
        self.artworkImage = artworkImage
        self.isPlaying = isPlaying
        self.trackId = trackId
        self.size = size
        self.onTap = onTap
        self.onNextTrack = onNextTrack
        self.onPreviousTrack = onPreviousTrack
    }

    public var body: some View {
        let armHeight = size * 0.68

        ZStack(alignment: .top) {
            TimelineView(.animation(paused: !isPlaying || isDragging || isTransitioningTrack)) { timeline in
                VinylRecordView(artworkImage: artworkImage, size: size)
                    .rotationEffect(.degrees(rotationState.currentAngle(at: timeline.date)))
            }
            .offset(x: dragOffset)
            .padding(.top, armHeight * 0.36)
            .contentShape(Circle())
            .gesture(swipeGesture)
            .onTapGesture { onTap?() }
            .zIndex(1)

            VinylTonearmView(isPlaying: isPlaying && !isDragging && !isTransitioningTrack, height: armHeight, reduceMotion: Platform.isReduceMotionEnabled)
                .offset(x: size * 0.12, y: -armHeight * 0.08)
                .allowsHitTesting(false)
                .zIndex(2)
        }
        .frame(width: size + 48, height: size + armHeight * 0.38, alignment: .top)
        .onAppear {
            if isPlaying { rotationState.start() }
        }
        .onChange(of: isPlaying) { playing in
            if playing { rotationState.start() } else { rotationState.stop() }
        }
        .onChange(of: trackId) { _ in
            isTransitioningTrack = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 320_000_000)
                isTransitioningTrack = false
            }
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 0.6 else { return }
                isDragging = true
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let translation = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let threshold: CGFloat = 45

                if translation < -threshold || predicted < -100 {
                    switchTrack(offset: -size * 1.25, callback: onNextTrack)
                } else if translation > threshold || predicted > 100 {
                    switchTrack(offset: size * 1.25, callback: onPreviousTrack)
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                        dragOffset = 0
                        isDragging = false
                    }
                }
            }
    }

    private func switchTrack(offset: CGFloat, callback: (() -> Void)?) {
        withAnimation(.easeOut(duration: 0.20)) { dragOffset = offset }
        callback?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            dragOffset = offset > 0 ? -size * 1.25 : size * 1.25
            withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) {
                dragOffset = 0
                isDragging = false
            }
        }
    }
}
