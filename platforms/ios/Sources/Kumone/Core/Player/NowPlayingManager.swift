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

    func attach(to player: PlayerService) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak player] _ in
            guard let player, player.resumeLastPlayback() else {
                return .noActionableNowPlayingItem
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            if player.isPlaying { player.togglePlayPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak player] _ in
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
        center.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
            guard let url,
                  let loaded = await ImageCache.shared.image(for: url),
                  let self, !Task.isCancelled else { return }
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
            MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
            await self.applyAnimatedArtwork(image: image, track: track)
        }
    }

    /// iOS 26 immersive lock-screen cover (looping video behind the controls).
    private func applyAnimatedArtwork(image: UIImage, track: Track) async {
        guard #available(iOS 26.0, *) else { return }
        let keys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        for key in keys { info[key] = nil }
        guard SettingsManager.shared.lockScreenImmersiveArtwork else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        }
        let artworks = await LockScreenAnimatedArtwork.artworks(for: image, key: track.playbackKey)
        guard !Task.isCancelled, currentTrack?.playbackKey == track.playbackKey else { return }
        for (name, artwork) in artworks {
            if let key = keys.first(where: { $0.lowercased().contains(name) }) { info[key] = artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    #if os(iOS)
    private var lockScreenArtworkSize: Int {
        SettingsManager.shared.lockScreenImmersiveArtwork ? 1024 : 256
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }
}
