#if DEBUG && os(iOS)
import AVFoundation
import MediaToolbox

/// Debug only: taps the audio the player really decodes, so its position can be compared with the player's clock.
/// The captured samples go to Documents/tap-N.f32 (mono float32) with tap-N.json (sample rate, the media time the tap
/// reported for the first sample, and the player clock when the capture began); a script then finds where in the song
/// those samples really are.
final class AudioTapProbe: @unchecked Sendable {
    static let shared = AudioTapProbe()
    static var enabled = false
    /// The player's clock, read from the audio thread.
    nonisolated(unsafe) static var clock: (() -> Double)?

    private let lock = NSLock()
    private var capturing = false
    private var samples: [Float] = []
    private var firstMedia: Double?
    private var firstClock: Double = 0
    fileprivate var sampleRate: Double = 0
    fileprivate var channels = 1
    fileprivate var isFloat = true
    fileprivate var interleaved = false
    private var counter = 0

    func makeMix(for track: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { _ in },
            prepare: { tap, _, format in
                let probe = Unmanaged<AudioTapProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let asbd = format.pointee
                probe.sampleRate = asbd.mSampleRate
                probe.channels = max(1, Int(asbd.mChannelsPerFrame))
                probe.isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                probe.interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange()
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
                let probe = Unmanaged<AudioTapProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                probe.consume(bufferList, frames: Int(framesOut.pointee), mediaStart: range.start.seconds)
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr,
              let tap else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    fileprivate func consume(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, mediaStart: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard capturing, frames > 0, isFloat else { return }
        if firstMedia == nil {
            firstMedia = mediaStart
            firstClock = AudioTapProbe.clock?() ?? 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var mono = [Float](repeating: 0, count: frames)
        if interleaved, let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[frame * channels + channel] }
                mono[frame] = sum / Float(channels)
            }
        } else {
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<frames { mono[frame] += data[frame] / Float(max(buffers.count, 1)) }
            }
        }
        samples.append(contentsOf: mono)
    }

    /// Silent probe: decodes `seconds` of a local file starting at `start` with AVAssetReader (no playback, no sound) and writes
    /// the samples like `capture` does. `firstMedia` is the timestamp AVFoundation gives the first decoded sample and
    /// `firstClock` the position that was asked for, so a script can tell how far the decoded sound really is from either.
    func readerCapture(file: URL, start: Double, seconds: Double) async -> String {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return "reader: cannot open \(file.lastPathComponent)" }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: seconds, preferredTimescale: 600))
        guard reader.startReading() else { return "reader: cannot start (\(String(describing: reader.error)))" }
        var taken: [Float] = []
        var firstPTS: Double?
        while let buffer = output.copyNextSampleBuffer() {
            if firstPTS == nil { firstPTS = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { taken.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / 4)) }
        }
        guard let firstPTS, !taken.isEmpty else { return "reader: nothing decoded at \(start) s" }
        lock.lock()
        counter += 1
        let number = counter
        lock.unlock()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let data = taken.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: docs.appendingPathComponent("tap-\(number).f32"))
        let meta = "{\"sampleRate\":48000.0,\"firstMedia\":\(firstPTS),\"firstClock\":\(start),\"frames\":\(taken.count)}"
        try? meta.write(to: docs.appendingPathComponent("tap-\(number).json"), atomically: true, encoding: .utf8)
        return String(format: "tap-%d: asked for %.1f s, first decoded sample stamped %.3f s, %d samples", number, start, firstPTS, taken.count)
    }

    /// Captures `seconds` of what is decoded now and writes it to Documents; returns a one-line description.
    func capture(seconds: Double) async -> String {
        lock.lock()
        samples = []
        firstMedia = nil
        capturing = true
        lock.unlock()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        lock.lock()
        capturing = false
        let taken = samples
        let media = firstMedia
        let clock = firstClock
        samples = []
        lock.unlock()
        guard let media, !taken.isEmpty else { return "tap: nothing captured (the tap did not run)" }
        counter += 1
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let data = taken.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: docs.appendingPathComponent("tap-\(counter).f32"))
        let meta = "{\"sampleRate\":\(sampleRate),\"firstMedia\":\(media),\"firstClock\":\(clock),\"frames\":\(taken.count)}"
        try? meta.write(to: docs.appendingPathComponent("tap-\(counter).json"), atomically: true, encoding: .utf8)
        return String(format: "tap-%d: %d samples at %.0f Hz, tap media time %.3f s, player clock %.3f s", counter, taken.count, sampleRate, media, clock)
    }
}
#endif
