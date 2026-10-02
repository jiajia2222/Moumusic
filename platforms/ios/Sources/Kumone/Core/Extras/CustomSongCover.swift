#if os(iOS)
import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// UserDefaults keys for per-song custom covers.
enum CustomCoverKeys {
    static let sound = "moumusic.customCover.videoSound"
    static let entries = "moumusic.customCover.entries.v1"
}

/// Per-song custom cover (image / GIF / video). Files live in Application
/// Support so cache clean-up never removes them.
@MainActor
final class CustomSongCoverStore: ObservableObject {
    static let shared = CustomSongCoverStore()

    struct Entry: Codable, Equatable {
        var file: String
        var isVideo: Bool
        var isGIF: Bool
    }

    @Published private(set) var entries: [String: Entry]

    private init() {
        if let data = UserDefaults.standard.data(forKey: CustomCoverKeys.entries),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CustomCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func entry(for track: Track?) -> Entry? {
        guard let track else { return nil }
        return entries[track.playbackKey]
    }

    func fileURL(_ entry: Entry) -> URL {
        Self.directory.appendingPathComponent(entry.file)
    }

    func hasCover(for track: Track?) -> Bool { entry(for: track) != nil }

    @discardableResult
    func set(for track: Track, from url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let isVideo = type?.conforms(to: .movie) == true || type?.conforms(to: .audiovisualContent) == true
        let isGIF = ext == "gif"
        let isImage = type?.conforms(to: .image) == true
        guard isVideo || isImage else {
            ToastCenter.shared.show("请选择有效的图片、GIF 或视频")
            return false
        }
        let name = "\(UUID().uuidString).\(ext.isEmpty ? (isVideo ? "mp4" : "jpg") : ext)"
        let dest = Self.directory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            ToastCenter.shared.show("自定义封面保存失败")
            return false
        }
        if let old = entries[track.playbackKey] {
            try? FileManager.default.removeItem(at: fileURL(old))
        }
        entries[track.playbackKey] = Entry(file: name, isVideo: isVideo, isGIF: isGIF)
        persist()
        ToastCenter.shared.show("自定义封面已保存")
        return true
    }

    func remove(for track: Track) {
        guard let old = entries[track.playbackKey] else { return }
        try? FileManager.default.removeItem(at: fileURL(old))
        entries[track.playbackKey] = nil
        persist()
        ToastCenter.shared.show("已恢复默认封面")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: CustomCoverKeys.entries)
        }
    }
}

/// Renders the custom cover media of an entry, filling its frame.
struct CustomCoverMedia: View {
    let entry: CustomSongCoverStore.Entry
    @AppStorage(CustomCoverKeys.sound) private var videoSound = false

    var body: some View {
        let url = CustomSongCoverStore.shared.fileURL(entry)
        if entry.isVideo {
            CustomCoverVideoView(url: url, muted: !videoSound)
        } else if entry.isGIF, let data = try? Data(contentsOf: url) {
            AnimatedGIFView(data: data)
        } else if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.clear
        }
    }
}

struct CustomCoverVideoView: UIViewRepresentable {
    let url: URL
    let muted: Bool

    func makeUIView(context: Context) -> CustomCoverMediaUIView {
        let view = CustomCoverMediaUIView()
        view.load(url: url, muted: muted)
        return view
    }

    func updateUIView(_ uiView: CustomCoverMediaUIView, context: Context) {
        if uiView.currentURL != url {
            uiView.load(url: url, muted: muted)
        } else {
            uiView.setMuted(muted)
        }
    }

    static func dismantleUIView(_ uiView: CustomCoverMediaUIView, coordinator: ()) {
        uiView.stop()
    }
}

final class CustomCoverMediaUIView: UIView {
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private(set) var currentURL: URL?

    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    func load(url: URL, muted: Bool) {
        stop()
        currentURL = url
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = muted
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        queuePlayer = player
        player.play()
    }

    func setMuted(_ muted: Bool) { queuePlayer?.isMuted = muted }

    func stop() {
        queuePlayer?.pause()
        looper?.disableLooping()
        looper = nil
        queuePlayer = nil
        playerLayer.player = nil
        currentURL = nil
    }
}

struct AnimatedGIFView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.image = Self.animatedImage(from: data)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}

    static func animatedImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }
        var frames: [UIImage] = []
        var total: Double = 0
        for index in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            total += max(delay, 0.02)
            frames.append(UIImage(cgImage: cg))
        }
        return UIImage.animatedImage(with: frames, duration: total)
    }
}

/// Sheet for choosing, replacing or removing the current song's cover.
struct CustomCoverPickerSheet: View {
    let track: Track
    @ObservedObject private var store = CustomSongCoverStore.shared
    @AppStorage(CustomCoverKeys.sound) private var videoSound = false
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
                        Label("从相册选择图片或视频", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("从文件选择（图片 / GIF / 视频）", systemImage: "doc")
                    }
                }
                Section {
                    Toggle("视频封面播放声音", isOn: $videoSound)
                }
                if store.hasCover(for: track) {
                    Section {
                        Button(role: .destructive) {
                            store.remove(for: track)
                            dismiss()
                        } label: {
                            Label("恢复默认封面", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
            .navigationTitle("自定义封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image, .movie, .gif],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                if store.set(for: track, from: url) { dismiss() }
            }
        }
    }

    @MainActor
    private func importPhoto(_ item: PhotosPickerItem) async {
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "jpg"
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            ToastCenter.shared.show("自定义封面保存失败")
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: temp)
        } catch {
            ToastCenter.shared.show("自定义封面保存失败")
            return
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        if store.set(for: track, from: temp) { dismiss() }
    }
}
#endif
