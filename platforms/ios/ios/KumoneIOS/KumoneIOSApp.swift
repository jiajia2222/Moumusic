import SwiftUI
import KumoneIOSFeature
import BackgroundTasks
import UIKit

@main
struct MoumusicIOSApp: App {
    @UIApplicationDelegateAdaptor(MoumusicAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            IOSMainWindow()
        }
    }
}

/// Requests an iOS-managed refresh window. iOS decides the actual execution
/// time; the coordinator still enforces the 12-hour limit and performs the
/// same check when the app returns to the foreground.
final class MoumusicAppDelegate: NSObject, UIApplicationDelegate {
    static let providerRefreshIdentifier = "com.jiajia2222.moumusic.provider-refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.providerRefreshIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleProviderRefresh(task)
        }
        scheduleProviderRefresh()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleProviderRefresh()
    }

    private func handleProviderRefresh(_ task: BGAppRefreshTask) {
        scheduleProviderRefresh()
        let work = Task { @MainActor in
            await MusicSessionRefreshCoordinator.shared.refreshIfNeeded(force: true)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    private func scheduleProviderRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.providerRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
