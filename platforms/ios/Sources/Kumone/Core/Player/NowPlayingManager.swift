import Foundation
import MediaPlayer

/// System Now Playing integration: media keys, Control Center, lock-screen metadata.
@MainActor
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    private weak var player: PlayerService?
    private var artworkTask: Task<Void, Never>?
    private var info: [String: Any] = [:]
    private var baseAlbumTitle = ""
    private var baseArtist = ""
    private var currentLyric = ""
    private var currentTrack: Track?

    private init() {}

    // MARK: External sessions (Bilibili videos)

    struct ExternalHandler {
        let play: () -> Void
        let pause: () -> Void
        let toggle: () -> Void
        let seek: (Double) -> Void
        let skip: (Double) -> Void
    }

    /// While a video owns the system player, remote commands go to it and music metadata
    /// updates are held back; the music info is restored when the video ends.
    private(set) var external: ExternalHandler?
    private var savedMusicInfo: [String: Any]?
    private var externalCover: String?

    func updateExternal(title: String, artist: String, coverURL: String?, elapsed: Double,
                        duration: Double, rate: Double, handler: ExternalHandler) {
        if external == nil { savedMusicInfo = info }
        external = handler
        var videoInfo: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: "哔哩哔哩",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if let artwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork],
           externalCover == coverURL {
            videoInfo[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = videoInfo
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        if externalCover != coverURL {
            externalCover = coverURL
            if let coverURL, let url = coverURL.resizedImageURL(768) {
                Task { @MainActor in
                    guard let image = await ImageCache.shared.image(for: url), self.external != nil,
                          self.externalCover == coverURL else { return }
                    var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    current[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = current
                }
            }
        }
    }

    func endExternal() {
        guard external != nil else { return }
        external = nil
        externalCover = nil
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = savedMusicInfo ?? info
        MPNowPlayingInfoCenter.default().playbackState = player?.isPlaying == true ? .playing : .paused
        savedMusicInfo = nil
    }

    func attach(to player: PlayerService) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()

        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let external = self?.external else { return .noActionableNowPlayingItem }
            external.skip((event as? MPSkipIntervalCommandEvent)?.interval ?? 15)
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let external = self?.external else { return .noActionableNowPlayingItem }
            external.skip(-((event as? MPSkipIntervalCommandEvent)?.interval ?? 15))
            return .success
        }
        center.playCommand.addTarget { [weak player, weak self] _ in
            if let external = self?.external { external.play(); return .success }
            guard let player, player.resumeLastPlayback() else {
                return .noActionableNowPlayingItem
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak player, weak self] _ in
            if let external = self?.external { external.pause(); return .success }
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            if player.isPlaying { player.togglePlayPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak player, weak self] _ in
            if let external = self?.external { external.toggle(); return .success }
            guard let player else { return .noActionableNowPlayingItem }
            if !player.hasCurrentTrack {
                return player.resumeLastPlayback() ? .success : .noActionableNowPlayingItem
            }
            player.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak player] _ in
            player?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak player] _ in
            player?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak player, weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            if let external = self?.external { external.seek(event.positionTime); return .success }
            player?.seek(to: event.positionTime)
            return .success
        }

        // Liking is tied to the removed provider account system. Keep the
        // Control Center command unavailable rather than opening a hidden
        // built-in account request from a source-only player.
        center.likeCommand.isEnabled = false
    }

    /// Reflects the current track's hearted state on the like command.
    func refreshLikeState() {
        MPRemoteCommandCenter.shared().likeCommand.isActive = false
    }

    func updateMetadata(for track: Track, duration: TimeInterval) {
        currentTrack = track
        baseAlbumTitle = track.album.name
        baseArtist = track.artistNames
        currentLyric = ""
        info = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.artistNames,
            MPMediaItemPropertyAlbumTitle: track.album.name,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            // Declare the session as audio so system surfaces treat it as a
            // complete now-playing app (best-effort hardening for #36/#40).
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if external == nil { MPNowPlayingInfoCenter.default().nowPlayingInfo = info }
        // Restoring metadata must not pretend that a terminated/paused app is
        // already playing. This keeps Apple's default Play affordance visible
        // and lets the next remote Play command resume the saved track.
        MPNowPlayingInfoCenter.default().playbackState = player?.isPlaying == true ? .playing : .paused
        refreshLikeState()

        refreshArtworkMode()
    }

    /// Rebuilds the artwork object without resetting playback position or
    /// lyric metadata. iOS uses the artwork's bounds and resolution when the
    /// Lock Screen player is expanded, so this is also the live setting hook.
    func refreshArtworkMode() {
        guard let track = currentTrack else { return }
        artworkTask?.cancel()
        let artworkSize = lockScreenArtworkSize
        artworkTask = Task { [weak self] in
            let url: URL?
            if let directURL = track.album.picUrl?.resizedImageURL(artworkSize) {
                url = directURL
            } else {
                url = await Self.fallbackArtworkURL(for: track, size: artworkSize)
            }
            // Forced immersive cover: retry a failed download once, then fall back to a
            // generated cover so every track still gets full-size (and animated) artwork.
            var fetched: UIImage?
            if let url { fetched = await ImageCache.shared.image(for: url) }
            if fetched == nil, url != nil, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if let url { fetched = await ImageCache.shared.image(for: url) }
            }
            guard !Task.isCancelled, let self else { return }
            let loaded = fetched ?? Self.placeholderArtwork(for: track)
            // Video covers (16:9) are center-cropped so the system player shows a square cover.
            let image: UIImage = {
                let w = loaded.size.width, h = loaded.size.height
                guard w > 0, h > 0, abs(w - h) / max(w, h) > 0.03, let cg = loaded.cgImage else { return loaded }
                let s = loaded.scale
                let side = min(w, h) * s
                let rect = CGRect(x: (w * s - side) / 2, y: (h * s - side) / 2, width: side, height: side)
                guard let cropped = cg.cropping(to: rect) else { return loaded }
                return UIImage(cgImage: cropped, scale: s, orientation: loaded.imageOrientation)
            }()
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.info[MPMediaItemPropertyArtwork] = artwork
            if self.external == nil { MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info }
            await self.applyAnimatedArtwork(image: image, track: track)
        }
    }

    /// iOS 26 immersive lock-screen cover (looping video behind the controls).
    private func applyAnimatedArtwork(image: UIImage, track: Track) async {
        guard #available(iOS 26.0, *) else { return }
        let keys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        for key in keys { info[key] = nil }
        guard SettingsManager.shared.lockScreenImmersiveArtwork else {
            if external == nil { MPNowPlayingInfoCenter.default().nowPlayingInfo = info }
            return
        }
        let artworks = await LockScreenAnimatedArtwork.artworks(for: image, key: track.playbackKey)
        guard !Task.isCancelled, currentTrack?.playbackKey == track.playbackKey,
              SettingsManager.shared.lockScreenImmersiveArtwork else { return }
        for (name, artwork) in artworks {
            if let key = keys.first(where: { $0.lowercased().contains(name) }) { info[key] = artwork }
        }
        if external == nil { MPNowPlayingInfoCenter.default().nowPlayingInfo = info }
    }

    #if os(iOS)
    /// 锁屏沉浸封面 on: high-resolution (and animated) cover for every track; off: small cover only.
    private var lockScreenArtworkSize: Int {
        SettingsManager.shared.lockScreenImmersiveArtwork ? 1024 : 256
    }

    /// A generated square cover (track-tinted gradient with the first letter) for songs
    /// without a usable picture.
    private static func placeholderArtwork(for track: Track) -> UIImage {
        let seed = abs((track.name + track.artistNames).unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) })
        let hue = Double(seed % 360) / 360
        let size = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(hue: hue, saturation: 0.55, brightness: 0.55, alpha: 1).cgColor,
                          UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.25, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let initial = String(track.name.trimmingCharacters(in: .whitespaces).first ?? "♪")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 460, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85)
            ]
            let text = NSAttributedString(string: initial, attributes: attributes)
            let textSize = text.size()
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
        }
    }
    #else
    private var lockScreenArtworkSize: Int { 1024 }
    #endif

    #if os(iOS)
    /// NetEase displays the current lyric in the system Now Playing artist
    /// row. Mirror that behavior on iOS while retaining the real artist as a
    /// fallback whenever lyrics are unavailable or the track changes.
    func updateCurrentLyric(_ lyric: String?) {
        let value = lyric?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value != currentLyric else { return }
        currentLyric = value
        info[MPMediaItemPropertyArtist] = value.isEmpty ? baseArtist : value
        if external == nil { MPNowPlayingInfoCenter.default().nowPlayingInfo = info }
    }
    #endif

    /// The Control Center uses Apple's standard title/artist/album fields.
    /// Source and resolved quality belong in the in-app player, not in the
    /// lock-screen metadata requested by Moumusic.
    func updateResolvedQuality(_ quality: String?, for track: Track) {}

    private static func fallbackArtworkURL(for track: Track, size: Int) async -> URL? {
        let query = [track.name, track.artistNames]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let result = try? await NeteaseAPI.search(query, type: .songs, limit: 6),
              let match = result.songs?.first(where: { $0.name == track.name }) ?? result.songs?.first else { return nil }
        return match.album.picUrl?.resizedImageURL(size)
    }

    func updateElapsed(_ elapsed: TimeInterval, rate: Double) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if external == nil { MPNowPlayingInfoCenter.default().nowPlayingInfo = info }
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }
}
