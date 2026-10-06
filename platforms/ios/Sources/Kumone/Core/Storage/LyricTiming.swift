#if os(iOS)
import AVFoundation
import QuartzCore

extension SettingsManager {
    /// Lyrics are shown ahead of the playback clock: the output latency (large on Bluetooth), the ~0.1 s
    /// progress tick, the spring animation of the line change and the render time all make a line look late,
    /// and a line that lights up just before it is sung reads as in time. The user's own offset is added on top.
    var effectiveLyricsOffset: Double {
        lyricsOffset + songLyricsOffset + LyricLatencyCache.value + Self.lyricsLead
    }

    /// The fixed part of the automatic lead, in seconds.
    static let lyricsLead = 0.20

    /// What the app adds to the lyric clock by itself: the output route, its latency, and the fixed lead. Shown in the
    /// lyric settings (so a wrong default can be reported as a number) and written to the diagnostic log.
    var automaticLyricsCompensation: (route: String, latency: Double, lead: Double) {
        (AudioRouteName.current, LyricLatencyCache.value, Self.lyricsLead)
    }
}

enum AudioRouteName {
    static var current: String {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType else { return "未知" }
        switch port {
        case .builtInSpeaker: return "扬声器"
        case .builtInReceiver: return "听筒"
        case .headphones: return "有线耳机"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "蓝牙"
        case .airPlay: return "AirPlay"
        case .carAudio: return "车载音频"
        case .usbAudio: return "USB 音频"
        default: return port.rawValue
        }
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
