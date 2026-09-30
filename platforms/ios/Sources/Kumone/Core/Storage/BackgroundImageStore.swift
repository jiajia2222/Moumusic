#if os(iOS)
import PhotosUI
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Owns the user-selected wallpaper used by the iOS shell and now-playing
/// page. The image is normalized before it is stored so a camera original
/// cannot become a multi-hundred-megabyte UserDefaults value.
@MainActor
final class BackgroundImageStore: ObservableObject {
    static let shared = BackgroundImageStore()

    @Published var photoSelection: PhotosPickerItem?
    @Published private(set) var image: UIImage?
    @Published private(set) var isImporting = false
    @Published var blurRadius: Double {
        didSet { UserDefaults.standard.set(blurRadius, forKey: Keys.blurRadius) }
    }
    @Published var syncToPlayer: Bool {
        didSet { UserDefaults.standard.set(syncToPlayer, forKey: Keys.syncToPlayer) }
    }
    @Published var syncToApp: Bool {
        didSet { UserDefaults.standard.set(syncToApp, forKey: Keys.syncToApp) }
    }

    private enum Keys {
        static let path = "moumusic.background.path.v1"
        static let fallbackData = "moumusic.background.data.v1"
        static let blurRadius = "moumusic.background.blur.v1"
        static let syncToPlayer = "moumusic.background.syncPlayer.v1"
        static let syncToApp = "moumusic.background.syncApp.v1"
    }

    private let fileName = "wallpaper.jpg"

    private init() {
        photoSelection = nil
        blurRadius = UserDefaults.standard.object(forKey: Keys.blurRadius) as? Double ?? 8
        syncToPlayer = UserDefaults.standard.object(forKey: Keys.syncToPlayer) as? Bool ?? true
        syncToApp = UserDefaults.standard.object(forKey: Keys.syncToApp) as? Bool ?? true
        image = loadStoredImage()
    }

    func importSelection() async {
        guard let selection = photoSelection else { return }
        guard !isImporting else { return }
        isImporting = true
        defer { photoSelection = nil }
        defer { isImporting = false }

        do {
            guard let data = try await loadImageData(from: selection),
                  save(data: data) else {
                ToastCenter.shared.show("无法读取图片，请重新选择")
                return
            }

            // A selected wallpaper should be visible immediately. The user
            // can still turn either destination off from Settings afterwards.
            syncToApp = true
            syncToPlayer = true
            ToastCenter.shared.show("背景图片已更新")
        } catch {
            ToastCenter.shared.show("背景图片读取失败，请检查照片权限")
        }
    }

    private func loadImageData(from selection: PhotosPickerItem) async throws -> Data? {
        // Some PhotosPicker providers expose a transferable image while
        // others expose only public.data. Try both representations; this
        // covers iCloud, HEIC, Files and third-party photo providers.
        do {
            if let data = try await selection.loadTransferable(type: Data.self),
               UIImage(data: data) != nil {
                return data
            }
        } catch {
            // Fall through to the image representation below.
        }
        // The explicit image Transferable keeps this compatible with the
        // iOS 16 PhotosPicker API, which has no loadDataRepresentation API.
        return try await selection.loadTransferable(type: ImageTransfer.self)?.data
    }

    @discardableResult
    func save(data: Data) -> Bool {
        guard let normalized = normalizedJPEG(from: data) else { return false }
        do {
            let url = try storageURL()
            try normalized.write(to: url, options: .atomic)
            UserDefaults.standard.set(url.path, forKey: Keys.path)
            // The small fallback makes app backup/restore and an upgraded
            // sandbox resilient without putting the full source image in the
            // normal settings payload.
            UserDefaults.standard.set(normalized.base64EncodedString(), forKey: Keys.fallbackData)
            image = UIImage(data: normalized)
            return image != nil
        } catch {
            return false
        }
    }

    func clear() {
        if let path = UserDefaults.standard.string(forKey: Keys.path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        UserDefaults.standard.removeObject(forKey: Keys.path)
        UserDefaults.standard.removeObject(forKey: Keys.fallbackData)
        photoSelection = nil
        image = nil
    }

    private func storageURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("MoumusicBackground", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory.appendingPathComponent(fileName)
    }

    private func loadStoredImage() -> UIImage? {
        if let path = UserDefaults.standard.string(forKey: Keys.path),
           let stored = UIImage(contentsOfFile: path) {
            return stored
        }
        guard let encoded = UserDefaults.standard.string(forKey: Keys.fallbackData),
              let data = Data(base64Encoded: encoded),
              let restored = UIImage(data: data) else { return nil }
        if let url = try? storageURL() {
            try? data.write(to: url, options: .atomic)
            UserDefaults.standard.set(url.path, forKey: Keys.path)
        }
        return restored
    }

    private func normalizedJPEG(from data: Data) -> Data? {
        guard let source = UIImage(data: data), source.size.width > 0, source.size.height > 0 else {
            return nil
        }
        let longestSide = max(source.size.width, source.size.height)
        let scale = min(1, 1600 / longestSide)
        let targetSize = CGSize(width: max(1, source.size.width * scale),
                                height: max(1, source.size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let rendered = renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: 0.86)
    }
}

private struct ImageTransfer: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            ImageTransfer(data: data)
        }
    }
}

/// Shared wallpaper renderer. It deliberately keeps the artwork dimmed so
/// text, lyrics and the native iOS glass controls remain readable.
struct MoumusicWallpaperView: View {
    let image: UIImage
    var blurRadius: CGFloat = 0
    var dimAmount: CGFloat = 0.24

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .blur(radius: blurRadius)
                .overlay(Color.black.opacity(dimAmount))
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A low-frequency artwork glow migrated from Beans' AmbientGlowView.
/// It pauses when audio is stopped, floating dust is disabled, or Reduce
/// Motion is enabled. The glow is intentionally artwork-driven rather than a
/// second global wallpaper layer.
struct MoumusicAmbientGlow: View {
    let colors: ArtworkColors
    let isPlaying: Bool
    var isEnabled: Bool = true
    var breath: Double = 0.6
    var dustMode: MoumusicPlayerDustMode = .off
    var dustDensity: Double = 1.0
    var dustSize: Double = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isEnabled {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying || dustMode != .snow || reduceMotion)) { timelineContext in
                Canvas { context, size in
                    guard size.width > 0, size.height > 0 else { return }
                    let time = dustMode == .snow && !reduceMotion
                        ? timelineContext.date.timeIntervalSinceReferenceDate
                        : 1.7
                    let primaryCenter = CGPoint(
                        x: size.width * (0.5 + 0.18 * sin(time * 0.25)),
                        y: size.height * (0.30 + 0.12 * cos(time * 0.20))
                    )
                    let secondaryCenter = CGPoint(
                        x: size.width * (0.5 + 0.20 * cos(time * 0.22 + 1.7)),
                        y: size.height * (0.72 + 0.12 * sin(time * 0.18 + 2.3))
                    )
                    let primaryRadius = min(size.width, size.height) * 0.55
                    let secondaryRadius = min(size.width, size.height) * 0.42
                    let safeBreath = max(0, min(1, breath))
                    let breathing = 0.85 + 0.15 * sin(time * 1.1)

                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: primaryCenter.x - primaryRadius,
                            y: primaryCenter.y - primaryRadius,
                            width: primaryRadius * 2,
                            height: primaryRadius * 2
                        )),
                        with: .radialGradient(
                            Gradient(colors: [
                                colors.primary.opacity(0.20 * breathing * safeBreath),
                                colors.primary.opacity(0)
                            ]),
                            center: primaryCenter,
                            startRadius: 0,
                            endRadius: primaryRadius
                        )
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: secondaryCenter.x - secondaryRadius,
                            y: secondaryCenter.y - secondaryRadius,
                            width: secondaryRadius * 2,
                            height: secondaryRadius * 2
                        )),
                        with: .radialGradient(
                            Gradient(colors: [
                                colors.secondary.opacity(0.16 * safeBreath),
                                colors.secondary.opacity(0)
                            ]),
                            center: secondaryCenter,
                            startRadius: 0,
                            endRadius: secondaryRadius
                        )
                    )

                    if dustMode == .snow && !reduceMotion {
                        let count = max(8, min(80, Int((26 * max(0, min(3, dustDensity))).rounded())))
                        let sizeScale = max(0.6, min(3.2, dustSize))
                        for index in 0..<count {
                            let seed = Double(index)
                            let drift = sin(time * 0.35 + seed * 1.9) * 18
                            let rawX = size.width * (0.08 + (seed * 0.137).truncatingRemainder(dividingBy: 0.84)) + drift
                            let x = rawX.truncatingRemainder(dividingBy: max(size.width, 1))
                            let fall = (time * (18 + seed.truncatingRemainder(dividingBy: 9)) + seed * 47)
                                .truncatingRemainder(dividingBy: max(size.height + 60, 1)) - 30
                            let twinkle = 0.55 + 0.45 * sin(time * 1.2 + seed)
                            let radius = (1.15 + 1.55 * twinkle) * sizeScale
                            context.fill(
                                Path(ellipseIn: CGRect(x: x - radius, y: fall - radius, width: radius * 2, height: radius * 2)),
                                with: .color(.white.opacity(0.055 + 0.055 * twinkle))
                            )
                        }
                    }
                }
                .drawingGroup()
            }
        } else {
            Color.clear
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
