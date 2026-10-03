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
        ("person.crop.circle", "个人资料卡", "每台设备拥有独立的 Moumusic ID，资料卡片可自定义头像与背景，并显示听歌时长。"),
        ("gearshape", "设置重新整理", "设置分为外观与界面、播放与音效、账号与平台、关于与支持四类，并支持搜索。"),
        ("bubble.left.and.text.bubble.right", "问题反馈", "新增反馈工单，可附带图片、视频或文件，并查看开发者回复。"),
        ("gauge.with.dots.needle.67percent", "显示与性能", "新增强制 120Hz 开关，默认跟随系统。"),
        ("text.bubble", "歌词体验", "歌词同步新增提前、延后 0.1 秒与重置，并继续支持逐字歌词。"),
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
                    .mouMaterialBackground(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
