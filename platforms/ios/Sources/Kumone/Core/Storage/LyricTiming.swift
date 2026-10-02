#if os(iOS)
import AVFoundation

extension SettingsManager {
    /// Lyrics are shown slightly ahead of the playback clock: the clock runs ahead of what is
    /// actually heard by the output latency (large on Bluetooth), the progress observer ticks
    /// every ~0.1 s, and a line needs a moment to render. The user's own offset is added on top.
    var effectiveLyricsOffset: Double {
        let session = AVAudioSession.sharedInstance()
        let hardware = min(0.6, max(0, session.outputLatency + session.ioBufferDuration))
        return lyricsOffset + hardware + 0.12
    }
}
#endif
