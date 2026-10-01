import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 自定义封面相关的 UserDefaults 键（非隔离，可在任意线程读取）。
enum CustomCoverKeys {
    static let sound = "beans.customCover.videoSound"
    static let lockScreenImmersive = "beans.lockScreenImmersiveArtwork.enabled"
    static let entries = "beans.customCover.entries.v1"
}

/// 每首歌的自定义封面（图片 / GIF / 视频）。文件保存在 Application Support，不会被缓存清理删除。
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

    func entry(for song: Song?) -> Entry? {
        guard let song = song else { return nil }
        return entries[song.identityKey]
    }

    /// 不依赖主线程的查询（锁屏封面等后台路径使用）。
    nonisolated static func lookup(identityKey: String) -> (url: URL, entry: Entry)? {
        guard let data = UserDefaults.standard.data(forKey: CustomCoverKeys.entries),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data),
              let entry = map[identityKey] else { return nil }
        return (directory.appendingPathComponent(entry.file), entry)
    }

    func fileURL(_ entry: Entry) -> URL {
        Self.directory.appendingPathComponent(entry.file)
    }

    func hasCover(for song: Song?) -> Bool { entry(for: song) != nil }

    /// 保存用户选择的图片 / GIF / 视频；格式无效时返回 false。
    @discardableResult
    func set(for song: Song, from url: URL) -> Bool {
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
        if let old = entries[song.identityKey] {
            try? FileManager.default.removeItem(at: fileURL(old))
        }
        entries[song.identityKey] = Entry(file: name, isVideo: isVideo, isGIF: isGIF)
        persist()
        ToastCenter.shared.show("自定义封面已保存")
        return true
    }

    func remove(for song: Song) {
        guard let old = entries[song.identityKey] else { return }
        try? FileManager.default.removeItem(at: fileURL(old))
        entries[song.identityKey] = nil
        persist()
        ToastCenter.shared.show("已恢复默认封面")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: CustomCoverKeys.entries)
        }
    }
}

/// 播放器封面：有自定义封面时显示自定义媒体，否则使用平台封面。
struct SongCoverView: View {
    let song: Song?
    var size: CGFloat
    var cornerRadius: CGFloat = 12
    var emptyHint: String? = nil

    @ObservedObject private var store = CustomSongCoverStore.shared
    @AppStorage(CustomCoverKeys.sound) private var videoSound = false

    var body: some View {
        if let entry = store.entry(for: song) {
            let url = store.fileURL(entry)
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.beansGlassFill)
                if entry.isVideo {
                    CustomCoverVideoView(url: url, muted: !videoSound)
                } else if entry.isGIF, let data = try? Data(contentsOf: url) {
                    AnimatedGIFView(data: data)
                } else if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            CoverImage(url: song?.coverURL, size: size, cornerRadius: cornerRadius, emptyHint: emptyHint)
        }
    }
}

/// 循环播放的视频封面。
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
        // 视频封面不应打断正在播放的音乐。
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

/// GIF 动图。
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
