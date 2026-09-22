#if os(iOS)
import SwiftUI

/// Owns the one-time "What's New" presentation marker. The marker contains
/// both marketing and build versions so an in-place update shows the log once,
/// while relaunching the same installed build does not interrupt playback.
@MainActor
final class IOSUpdateLogStore: ObservableObject {
    static let shared = IOSUpdateLogStore()

    @Published var isPresented = false
    @Published private(set) var version = ReleaseChecker.currentDisplayVersion

    private let lastPresentedKey = "ios.updateLog.lastPresentedIdentity"

    func presentIfNeeded() {
        let identity = ReleaseChecker.currentIdentity
        guard identity.isValid else { return }
        let marker = "\(identity.shortVersion)#\(identity.buildNumber)"
        guard UserDefaults.standard.string(forKey: lastPresentedKey) != marker else { return }
        UserDefaults.standard.set(marker, forKey: lastPresentedKey)
        version = identity.displayVersion
        isPresented = true
    }

    func present() {
        version = ReleaseChecker.currentDisplayVersion
        isPresented = true
    }
}

struct IOSUpdateLogSheet: View {
    @StateObject private var updateLog = IOSUpdateLogStore.shared
    @Environment(\.dismiss) private var dismiss

    private let items: [(String, String, String)] = [
        ("arrow.triangle.2.circlepath", "版本自检", "启动后先进入主界面，再在后台查询 GitHub 最新版本；检查失败不会挡住播放。"),
        ("waveform", "播放与音质", "优先使用已登录账号的可用音质，失败后按当前设置回退到已启用的 LX 音源。"),
        ("text.bubble", "歌词与体验", "继续优化歌词、封面和播放切换，并保留设置中手动查看更新日志的入口。"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("WHAT'S NEW")
                            .font(.caption.weight(.bold))
                            .tracking(1.8)
                            .foregroundStyle(Theme.accent)
                        Text("更新日志")
                            .font(.largeTitle.weight(.bold))
                        Text("Moumusic \(updateLog.version)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: item.0)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(LocalizedStringKey(item.1)).font(.headline)
                                    Text(LocalizedStringKey(item.2))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 15)
                            if index < items.count - 1 {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .padding(20)
            }
            .navigationTitle("更新日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif
