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
        // Some PhotosPicker providers do not expose the selected item as
        // public.data. Requesting an image representation first also covers
        // iCloud and HEIC items that previously made the picker appear idle.
        do {
            if let image = try await selection.loadTransferable(type: ImageTransfer.self) {
                return image.data
            }
        } catch {
            // Fall through to the generic representation below.
        }
        // Keep the generic Data path as a compatibility fallback.
        return try await selection.loadTransferable(type: Data.self)
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

/// A low-frequency artwork glow inspired by the ambient background in
/// Beans-Music. It pauses when audio is stopped or Reduce Motion is enabled.
struct MoumusicAmbientGlow: View {
    let colors: ArtworkColors
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !isPlaying || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(colors.primary.opacity(0.26))
                    .frame(width: 460, height: 460)
                    .blur(radius: 90)
                    .offset(
                        x: CGFloat(sin(time / 9) * 150),
                        y: CGFloat(cos(time / 11) * 120)
                    )
                Circle()
                    .fill(colors.secondary.opacity(0.32))
                    .frame(width: 380, height: 380)
                    .blur(radius: 84)
                    .offset(
                        x: CGFloat(cos(time / 10) * 170),
                        y: CGFloat(sin(time / 8) * 140)
                    )
            }
            .drawingGroup()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
