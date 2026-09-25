import Foundation
import SwiftUI

#if os(iOS)

/// Coordinates the short iOS launch transition and the first online warm-up.
///
/// The launch screen is deliberately time-bounded. Network requests continue
/// in the background after the main UI appears, so a slow provider can never
/// turn launch into a blank screen or an infinite spinner.
@MainActor
final class IOSStartupCoordinator: ObservableObject {
    static let shared = IOSStartupCoordinator()

    enum Phase: Equatable {
        case idle
        case warming
        case ready
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isOnline = false
    @Published private(set) var message = String(localized: "正在连接在线服务")

    private var didStart = false
    private var preloadTasks: [Task<Void, Never>] = []

    private init() {}

    var isReady: Bool { phase == .ready }

    func start(
        player: PlayerService,
        account: AccountStore,
        settings: SettingsManager
    ) async {
        guard !didStart else { return }
        didStart = true
        phase = .warming
        message = String(localized: "正在预加载在线内容")

        let startedAt = Date()
        player.startRuntime()

        // Keep the first network requests together. The page models also own
        // their normal refresh tasks, so each operation is safe to run twice:
        // their caches/coordinators collapse duplicate work.
        preloadTasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            self.isOnline = await Self.probeOnlineService()
            if !self.isOnline {
                self.message = String(localized: "在线服务暂时不可用，稍后可重试")
            }
        })

        preloadTasks.append(Task { @MainActor in
            await account.bootstrap()
        })

        preloadTasks.append(Task { @MainActor in
            await MusicSessionRefreshCoordinator.shared.refreshIfNeeded()
        })

        // Start the real home request during the splash. It populates the
        // shared HomeViewModel cache used by the first visible page.
        preloadTasks.append(Task { @MainActor in
            await HomeViewModel.shared.load(
                loggedIn: account.isLoggedIn,
                mode: settings.homeRecommendationMode,
                platform: settings.homeRecommendationPlatform,
                qishuiSessionRevision: 0
            )
        })

        // Loading the selected LX bridge here makes capabilities and quality
        // information available before the first tap on a song. The health
        // request is read-only and continues after the splash if a provider
        // takes longer than the launch animation.
        preloadTasks.append(Task { @MainActor in
            _ = await LXUserAPIService.shared.checkSelectedSource()
        })

        // Warm the live search hint independently from the home feed. This is
        // intentionally tiny, but means the native search surface has online
        // data ready when it is opened immediately after launch.
        preloadTasks.append(Task { @MainActor in
            _ = try? await NeteaseAPI.searchDefaultKeyword()
        })

        // Keep the animation short and predictable. The online tasks above
        // are not awaited here; they remain active and update shared caches.
        let minimumDuration: TimeInterval = 0.72
        let remaining = minimumDuration - Date().timeIntervalSince(startedAt)
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }

        phase = .ready
        message = isOnline
            ? String(localized: "在线内容已开始加载")
            : String(localized: "已进入应用，在线内容稍后重试")
    }

    private static func probeOnlineService() async -> Bool {
        guard let url = URL(string: "https://music.163.com/favicon.ico") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return false }
            // A server response, including a rate-limit or auth response,
            // still proves that the device has a usable network route.
            return (200..<500).contains(response.statusCode)
        } catch {
            return false
        }
    }
}

struct IOSStartupSplashView: View {
    @ObservedObject var coordinator: IOSStartupCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animateMark = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Theme.accent.opacity(0.16),
                    Color(uiColor: .systemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(.thinMaterial)
                        .frame(width: 92, height: 92)

                    Circle()
                        .stroke(Theme.accent.opacity(0.32), lineWidth: 1.5)
                        .frame(width: 92, height: 92)
                        .scaleEffect(animateMark ? 1.12 : 0.9)
                        .opacity(animateMark ? 0.1 : 0.8)

                    Image(systemName: "waveform")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .scaleEffect(animateMark ? 1.04 : 0.94)
                }

                VStack(spacing: 8) {
                    Text("Moumusic")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(coordinator.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                ProgressView()
                    .tint(Theme.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(String(localized: "正在加载在线内容"))
            }
            .padding(.horizontal, 32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Moumusic 正在启动并预加载在线内容"))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                animateMark = true
            }
        }
    }
}

#endif
