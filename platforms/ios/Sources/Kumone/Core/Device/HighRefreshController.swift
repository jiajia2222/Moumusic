#if os(iOS)
import QuartzCore
import SwiftUI

/// "强制 120Hz" switch. Off follows the system; on keeps a display link that
/// requests the maximum frame rate while the app is in the foreground.
@MainActor
final class HighRefreshController: ObservableObject {
    static let shared = HighRefreshController()
    static let defaultsKey = "moumusic.forceHighRefresh"

    @Published var isForced: Bool {
        didSet {
            UserDefaults.standard.set(isForced, forKey: Self.defaultsKey)
            apply()
        }
    }

    private var link: CADisplayLink?

    private init() {
        isForced = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    func apply() {
        link?.invalidate()
        link = nil
        guard isForced else { return }
        let proxy = DisplayLinkProxy()
        let newLink = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        newLink.add(to: .main, forMode: .common)
        link = newLink
    }
}

private final class DisplayLinkProxy: NSObject {
    @objc func tick() {}
}
#endif
