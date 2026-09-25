import AVFoundation
import Combine
import Foundation
import MediaToolbox

/// Ten-band equalizer migrated from Beans-Music 1.8.1 and adapted to
/// Moumusic's existing AVPlayer processing tap.  The player remains an
/// AVPlayer; this object only changes PCM samples after the source has been
/// resolved and before AudioSpectrum analyses them.
enum MoumusicEqualizerPreset: String, CaseIterable, Identifiable, Equatable {
    case flat
    case bass
    case vocal
    case pop
    case rock
    case classical
    case jazz
    case electronic
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flat: return "默认"
        case .bass: return "低音增强"
        case .vocal: return "人声"
        case .pop: return "流行"
        case .rock: return "摇滚"
        case .classical: return "古典"
        case .jazz: return "爵士"
        case .electronic: return "电子"
        case .custom: return "自定义"
        }
    }

    var gains: [Double]? {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: return [6, 5, 3, 1, 0, 0, -1, -1, 0, 0]
        case .vocal: return [-2, -1, 0, 2, 4, 4, 3, 2, 0, -1]
        case .pop: return [2, 2, 1, 0, 2, 3, 2, 1, 2, 2]
        case .rock: return [5, 4, 2, -1, -2, 1, 3, 4, 5, 4]
        case .classical: return [3, 2, 1, 0, 0, 1, 2, 3, 4, 4]
        case .jazz: return [3, 2, 1, 2, -1, -1, 0, 2, 3, 3]
        case .electronic: return [5, 4, 1, -2, -1, 2, 4, 3, 5, 4]
        case .custom: return nil
        }
    }
}

struct MoumusicEqualizerCustomPreset: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var gains: [Double]
    var preampGain: Double

    init(id: String = UUID().uuidString, name: String, gains: [Double], preampGain: Double) {
        self.id = id
        self.name = name
        self.gains = gains
        self.preampGain = preampGain
    }
}

/// Persistent equalizer state and the real-time biquad processor used by the
/// shared AudioSpectrum tap.  All audio-thread state is guarded by one lock;
/// no SwiftUI view is involved in sample processing.
final class MoumusicEqualizer: ObservableObject {
    static let shared = MoumusicEqualizer()
    static let bandFrequencies: [Double] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let maximumGain: Double = 12

    @Published private(set) var isEnabled: Bool
    @Published private(set) var bandGains: [Double]
    @Published private(set) var selectedPreset: MoumusicEqualizerPreset
    @Published private(set) var selectedCustomPresetName: String?
    @Published private(set) var preampGain: Double
    @Published private(set) var customPresets: [MoumusicEqualizerCustomPreset]

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var processingEnabled = false
    private var processingPreampLinear: Float = 1
    private var processingFormatIsFloat32 = false
    private var sampleRate: Double = 44_100
    private var coefficients: [MoumusicBiquad] = Array(repeating: .identity, count: 10)
    private var filterStates: [MoumusicBiquadState] = Array(repeating: .zero, count: 80)
    private var pendingPersistWorkItem: DispatchWorkItem?

    private static let enabledKey = "moumusic.equalizer.enabled"
    private static let gainsKey = "moumusic.equalizer.bandGains"
    private static let presetKey = "moumusic.equalizer.preset"
    private static let customPresetNameKey = "moumusic.equalizer.customPresetName"
    private static let customPresetsKey = "moumusic.equalizer.customPresets"
    private static let preampKey = "moumusic.equalizer.preampGain"
    private static let maximumChannels = 8

    private init() {
        let storedGains = defaults.array(forKey: Self.gainsKey)?.compactMap { ($0 as? NSNumber)?.doubleValue }
        let normalizedGains = Self.normalizedGains(storedGains)
        let storedPreset = defaults.string(forKey: Self.presetKey)
            .flatMap(MoumusicEqualizerPreset.init(rawValue:)) ?? .flat
        let storedCustom = defaults.data(forKey: Self.customPresetsKey)
            .flatMap { try? JSONDecoder().decode([MoumusicEqualizerCustomPreset].self, from: $0) } ?? []

        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        bandGains = normalizedGains
        selectedPreset = storedPreset
        selectedCustomPresetName = defaults.string(forKey: Self.customPresetNameKey)
        preampGain = Self.normalizedGain((defaults.object(forKey: Self.preampKey) as? NSNumber)?.doubleValue ?? 0)
        customPresets = storedCustom.compactMap { preset in
            let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return MoumusicEqualizerCustomPreset(
                id: preset.id,
                name: name,
                gains: Self.normalizedGains(preset.gains),
                preampGain: Self.normalizedGain(preset.preampGain)
            )
        }
        processingEnabled = isEnabled
        processingPreampLinear = Self.linearGain(for: preampGain)
        rebuildCoefficientsLocked(using: normalizedGains)
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        lock.lock()
        processingEnabled = enabled
        lock.unlock()
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func setBandGain(at index: Int, to gain: Double) {
        guard bandGains.indices.contains(index) else { return }
        let normalized = Self.normalizedGain(gain)
        guard bandGains[index] != normalized else { return }
        var updated = bandGains
        updated[index] = normalized
        bandGains = updated
        selectedPreset = .custom
        selectedCustomPresetName = nil
        lock.lock()
        rebuildCoefficientsLocked(using: updated)
        lock.unlock()
        schedulePersist()
    }

    func setPreampGain(_ gain: Double) {
        let normalized = Self.normalizedGain(gain)
        guard preampGain != normalized else { return }
        preampGain = normalized
        selectedPreset = .custom
        selectedCustomPresetName = nil
        lock.lock()
        processingPreampLinear = Self.linearGain(for: normalized)
        lock.unlock()
        schedulePersist()
    }

    func applyPreset(_ preset: MoumusicEqualizerPreset) {
        guard let gains = preset.gains else { return }
        let normalized = Self.normalizedGains(gains)
        bandGains = normalized
        selectedPreset = preset
        selectedCustomPresetName = nil
        preampGain = 0
        lock.lock()
        processingPreampLinear = 1
        rebuildCoefficientsLocked(using: normalized)
        lock.unlock()
        persistNow()
    }

    func applyCustomPreset(_ preset: MoumusicEqualizerCustomPreset) {
        let normalized = Self.normalizedGains(preset.gains)
        bandGains = normalized
        selectedPreset = .custom
        selectedCustomPresetName = preset.name
        preampGain = Self.normalizedGain(preset.preampGain)
        lock.lock()
        processingPreampLinear = Self.linearGain(for: preampGain)
        rebuildCoefficientsLocked(using: normalized)
        lock.unlock()
        persistNow()
    }

    @discardableResult
    func saveCustomPreset(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let preset = MoumusicEqualizerCustomPreset(name: trimmed, gains: bandGains, preampGain: preampGain)
        if let index = customPresets.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            customPresets[index] = MoumusicEqualizerCustomPreset(id: customPresets[index].id, name: trimmed, gains: preset.gains, preampGain: preset.preampGain)
        } else {
            customPresets.append(preset)
        }
        selectedPreset = .custom
        selectedCustomPresetName = trimmed
        persistNow()
        return true
    }

    func deleteCustomPreset(_ preset: MoumusicEqualizerCustomPreset) {
        customPresets.removeAll { $0.id == preset.id }
        if selectedCustomPresetName == preset.name { selectedCustomPresetName = nil }
        persistNow()
    }

    func reset() { applyPreset(.flat) }

    // MARK: Audio tap hooks

    func prepare(with format: AudioStreamBasicDescription) {
        lock.lock()
        sampleRate = max(format.mSampleRate, 8_000)
        processingFormatIsFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && format.mBitsPerChannel == 32
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        filterStates = Array(repeating: .zero, count: Self.maximumChannels * Self.bandFrequencies.count)
        rebuildCoefficientsLocked(using: bandGains)
        lock.unlock()
    }

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard frameCount > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard processingEnabled, processingFormatIsFloat32 else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var firstChannelIndex = 0
        for buffer in buffers {
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            defer { firstChannelIndex += channelCount }
            guard let rawData = buffer.mData else { continue }
            let samples = rawData.assumingMemoryBound(to: Float.self)
            let availableFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            let framesToProcess = min(frameCount, availableFrames)
            guard framesToProcess > 0 else { continue }

            for channelOffset in 0..<channelCount {
                let channel = min(firstChannelIndex + channelOffset, Self.maximumChannels - 1)
                let stateOffset = channel * Self.bandFrequencies.count
                for frame in 0..<framesToProcess {
                    let sampleIndex = frame * channelCount + channelOffset
                    var sample = samples[sampleIndex] * processingPreampLinear
                    for bandIndex in coefficients.indices {
                        let stateIndex = stateOffset + bandIndex
                        let coefficient = coefficients[bandIndex]
                        var state = filterStates[stateIndex]
                        let filtered = coefficient.b0 * sample + state.z1
                        state.z1 = coefficient.b1 * sample - coefficient.a1 * filtered + state.z2
                        state.z2 = coefficient.b2 * sample - coefficient.a2 * filtered
                        filterStates[stateIndex] = state
                        sample = filtered
                    }
                    samples[sampleIndex] = sample.isFinite ? min(max(sample, -4), 4) : 0
                }
            }
        }
    }

    private func schedulePersist() {
        pendingPersistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistNow() }
        pendingPersistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func persistNow() {
        pendingPersistWorkItem?.cancel()
        pendingPersistWorkItem = nil
        defaults.set(bandGains, forKey: Self.gainsKey)
        defaults.set(selectedPreset.rawValue, forKey: Self.presetKey)
        if let selectedCustomPresetName { defaults.set(selectedCustomPresetName, forKey: Self.customPresetNameKey) }
        else { defaults.removeObject(forKey: Self.customPresetNameKey) }
        defaults.set(preampGain, forKey: Self.preampKey)
        if let data = try? JSONEncoder().encode(customPresets) { defaults.set(data, forKey: Self.customPresetsKey) }
    }

    private static func normalizedGains(_ values: [Double]?) -> [Double] {
        let values = values ?? []
        return bandFrequencies.indices.map { normalizedGain($0 < values.count ? values[$0] : 0) }
    }

    private static func normalizedGain(_ value: Double) -> Double {
        let clamped = min(max(value, -maximumGain), maximumGain)
        return (clamped * 2).rounded() / 2
    }

    private static func linearGain(for gain: Double) -> Float { Float(pow(10, gain / 20)) }

    private func rebuildCoefficientsLocked(using gains: [Double]) {
        coefficients = zip(Self.bandFrequencies, Self.normalizedGains(gains)).map {
            MoumusicBiquad.peaking(frequency: $0.0, gain: $0.1, sampleRate: sampleRate)
        }
    }
}

private struct MoumusicBiquad {
    let b0: Float
    let b1: Float
    let b2: Float
    let a1: Float
    let a2: Float

    static let identity = MoumusicBiquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    static func peaking(frequency: Double, gain: Double, sampleRate: Double) -> MoumusicBiquad {
        guard abs(gain) > 0.001 else { return .identity }
        let f = min(max(frequency, 20), sampleRate * 0.45)
        let amplitude = pow(10, gain / 40)
        let omega = 2 * Double.pi * f / sampleRate
        let alpha = sin(omega) / 2
        let cosine = cos(omega)
        let a0 = 1 + alpha / amplitude
        return MoumusicBiquad(
            b0: Float((1 + alpha * amplitude) / a0),
            b1: Float((-2 * cosine) / a0),
            b2: Float((1 - alpha * amplitude) / a0),
            a1: Float((-2 * cosine) / a0),
            a2: Float((1 - alpha / amplitude) / a0)
        )
    }
}

private struct MoumusicBiquadState {
    var z1: Float = 0
    var z2: Float = 0
    static let zero = MoumusicBiquadState()
}
