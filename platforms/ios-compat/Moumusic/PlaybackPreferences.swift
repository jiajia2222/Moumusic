import Foundation
import Network

/// 播放来源：自动（官方优先，失败后用第三方）/ 仅官方 / 仅第三方。
enum PlaybackSourceMode: String, CaseIterable, Identifiable {
    case auto, official, thirdParty

    static let key = "beans.playback.sourceMode"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .official: return "官方"
        case .thirdParty: return "第三方"
        }
    }

    var hint: String {
        switch self {
        case .auto: return "优先官方，失败后尝试已启用音源"
        case .official: return "只使用当前平台官方播放地址"
        case .thirdParty: return "只使用已启用的第三方音源"
        }
    }

    nonisolated static var current: PlaybackSourceMode {
        PlaybackSourceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto
    }
}

/// 当前网络类型（Wi-Fi / 蜂窝），供「按网络类型选择音质」使用。
final class BeansNetworkType {
    static let shared = BeansNetworkType()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "Beans.NetworkType")
    private let lock = NSLock()
    private var cellular = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock()
            self.cellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    var isCellular: Bool {
        lock.lock(); defer { lock.unlock() }
        return cellular
    }
}

enum PlaybackPreferenceKeys {
    static let qualityByNetwork = "beans.audioQuality.byNetwork"
    static let qualityWifi = "beans.audioQuality.wifi"
    static let qualityCellular = "beans.audioQuality.cellular"
    static let crossPlatformFallback = "beans.playback.crossPlatformFallback"

    /// 播放失败时是否匹配其它平台的同一首歌（默认开启）。
    static var crossPlatformFallbackEnabled: Bool {
        UserDefaults.standard.object(forKey: crossPlatformFallback) as? Bool ?? true
    }
}
