import AVFoundation
import MediaPlayer
import UIKit

/// 锁屏封面：歌曲有自定义图片封面时替换系统「正在播放」封面；
/// 有自定义视频封面且开启「锁屏沉浸封面」时，在 iOS 26+ 使用动态封面。
enum BeansLockScreenArtwork {
    nonisolated static func apply(to info: inout [String: Any], song: Song) {
        guard let found = CustomSongCoverStore.lookup(identityKey: song.identityKey) else { return }
        let url = found.url
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        if !found.entry.isVideo {
            if let image = UIImage(contentsOfFile: url.path) {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
            return
        }

        #if !MOUMUSIC_COMPAT
        guard UserDefaults.standard.bool(forKey: CustomCoverKeys.lockScreenImmersive) else { return }
        if #available(iOS 26.0, *) {
            let preview = previewImage(for: url)
            if let preview = preview {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: preview.size) { _ in preview }
            }
            let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
            let id = song.identityKey + "|" + found.entry.file
            let animated = MPMediaItemAnimatedArtwork(
                artworkID: id,
                previewImageRequestHandler: { _ in preview },
                videoAssetFileURLRequestHandler: { _ in url }
            )
            if supported.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork) {
                info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = animated
            }
            if supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork) {
                info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = animated
            }
        }
        #endif
    }

    /// 视频第一帧作为静态预览。
    nonisolated private static func previewImage(for url: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}


/// 设置里的「锁屏沉浸封面」开关（需要 iOS 26 的动态封面能力，仅全功能版）。
struct LockScreenArtworkToggleCard: View {
    @AppStorage(CustomCoverKeys.lockScreenImmersive) private var enabled = false

    var body: some View {
        #if MOUMUSIC_COMPAT
        EmptyView()
        #else
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("锁屏沉浸封面")
                        .font(BeansFont.appFont(15))
                        .foregroundStyle(Color.beansLabel)
                    Text("给歌曲设置视频自定义封面后，锁屏和控制中心会以动态封面显示（iOS 26+）。")
                        .font(BeansFont.appFont(11))
                        .foregroundStyle(Color.beansComment)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.beansAmber)
        }
        .padding(14)
        .background { BeansGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
        #endif
    }
}
