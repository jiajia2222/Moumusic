#if os(iOS)
import AVFoundation
import QuartzCore

extension SettingsManager {
    /// Lyrics are shown ahead of the playback clock: the output latency (large on Bluetooth), the ~0.1 s
    /// progress tick, the spring animation of the line change and the render time all make a line look late,
    /// and a line that lights up just before it is sung reads as in time. The user's own offset is added on top.
    var effectiveLyricsOffset: Double {
        lyricsOffset + songLyricsOffset + LyricLatencyCache.value + 0.20
    }
}

/// Reading AVAudioSession latency is not free and the karaoke views ask every frame; refresh
/// the value at most once per second (route changes such as Bluetooth take effect within it).
private enum LyricLatencyCache {
    private static var cached: Double = 0
    private static var updatedAt: Double = 0

    static var value: Double {
        let now = CACurrentMediaTime()
        if now - updatedAt > 1 {
            let session = AVAudioSession.sharedInstance()
            cached = min(0.6, max(0, session.outputLatency + session.ioBufferDuration))
            updatedAt = now
        }
        return cached
    }
}
#endif
