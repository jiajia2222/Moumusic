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

    private init() {}

    func attach(to player: PlayerService) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            if !player.isPlaying { player.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
            if player.isPlaying { player.togglePlayPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak player] _ in
            guard let player, player.hasCurrentTrack else { return .noActionableNowPlayingItem }
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
        baseAlbumTitle = track.album.name
        info = [
            MPMediaItemPropertyTitle: track.name,
            MPMediaItemPropertyArtist: track.artistNames,
            MPMediaItemPropertyAlbumTitle: "\(track.album.name) · 来源：\(sourceName(track.source))",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            // Declare the session as audio so system surfaces treat it as a
            // complete now-playing app (best-effort hardening for #36/#40).
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
        refreshLikeState()

        artworkTask?.cancel()
        // 1024px: the lock screen's tap-to-fullscreen artwork presentation
        // needs high-resolution art to engage.
        artworkTask = Task { [weak self] in
        let url: URL?
        if let directURL = track.album.picUrl?.resizedImageURL(1024) {
            url = directURL
        } else {
            url = await Self.fallbackArtworkURL(for: track)
        }
            guard let url,
                  let image = await ImageCache.shared.image(for: url),
                  let self, !Task.isCancelled else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
        }
    }

    /// Adds the actually served LX quality to the system metadata after the
    /// URL has resolved. This is what Control Center and the lock screen can
    /// display; the requested setting is not necessarily the served quality.
    func updateResolvedQuality(_ quality: String?, for track: Track) {
        guard track.id == player?.currentTrack?.id else { return }
        let qualityText = quality.map { qualityName($0) } ?? "解析中"
        info[MPMediaItemPropertyAlbumTitle] = "\(baseAlbumTitle) · 来源：\(sourceName(track.source)) · 音质：\(qualityText)"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static func fallbackArtworkURL(for track: Track) async -> URL? {
        let query = [track.name, track.artistNames]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let result = try? await NeteaseAPI.search(query, type: .songs, limit: 6),
              let match = result.songs?.first(where: { $0.name == track.name }) ?? result.songs?.first else { return nil }
        return match.album.picUrl?.resizedImageURL(1024)
    }

    private func sourceName(_ source: String?) -> String {
        switch source?.lowercased() {
        case "wy", "netease", "163": return "网易云"
        case "kw", "kuwo": return "酷我"
        case "kg", "kugou": return "酷狗"
        case "tx", "qq", "qqmusic": return "QQ音乐"
        case "mg", "migu": return "咪咕"
        default: return source?.isEmpty == false ? source! : "未知"
        }
    }

    private func qualityName(_ value: String) -> String {
        AudioQuality(lxType: value)?.displayName ?? value.uppercased()
    }

    func updateElapsed(_ elapsed: TimeInterval, rate: Double) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }
}
