#if os(iOS)
import AVFoundation
import QuartzCore

extension SettingsManager {
    /// Lyrics are shown slightly ahead of the playback clock: the clock runs ahead of what is
    /// actually heard by the output latency (large on Bluetooth), the progress observer ticks
    /// every ~0.1 s, and a line needs a moment to render. The user's own offset is added on top.
    var effectiveLyricsOffset: Double {
        lyricsOffset + LyricLatencyCache.value + 0.12
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
