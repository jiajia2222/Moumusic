#if os(macOS)
import Combine
import Sparkle
import SwiftUI

/// Wraps Sparkle's standard updater so SwiftUI menus can observe its state.
@MainActor
final class UpdaterManager: ObservableObject {
    static let shared = UpdaterManager()

    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        controller.updater.automaticallyChecksForUpdates = SettingsManager.shared.autoCheckUpdates
    }

    /// Toggle Sparkle's scheduled update checks (#42).
    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = UpdaterManager.shared

    var body: some View {
        Button("检查更新…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
#else
import SwiftUI

struct CheckForUpdatesButton: View {
    var body: some View {
        EmptyView()
    }
}
#endif
