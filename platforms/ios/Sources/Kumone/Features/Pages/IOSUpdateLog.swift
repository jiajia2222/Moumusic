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
        ("waveform", "音质更真实", "音质以音频文件实测为准（FLAC 位深 / 采样率 / 声道、MP3 码率），同一首歌的音质列表不再忽有忽无；没拿到所选音质时先重试再降级，并新增「音质降级时提示」开关，每首歌的音质详情写入诊断日志。"),
        ("music.note.list", "平台音质", "QQ 音乐、酷狗按每首歌的真实音质表显示可选档位，各平台用自己的音质名称（臻品 / 蝰蛇 / PQ·HQ·SQ·ZQ）；新增酷我、咪咕官方路线（无需登录）；本平台没有所选音质时才去其他平台找，播放失败也会换平台。"),
        ("square.grid.2x2", "首页与发现", "首页只显示各平台官方排行榜（咪咕暂无榜单，显示热门歌单），公告可点 X 关闭；发现页保留官方推荐歌单，下拉刷新不再失败、不再整页下移，每次刷新会换一批歌曲，不再闪回旧列表；酷我封面修复。"),
        ("bolt.fill", "播放更快", "自动模式有音源时优先走第三方，不再先探测官方账号；备用音源只在主音源完全失败时才用，起播更快；试听片段改为起播后再检测；切换音质立即从原位置继续播放。"),
        ("play.rectangle", "哔哩哔哩", "「听视频」改走 HLS，加载更快；弹幕按 120Hz 更流畅；横屏全屏更稳；新增默认字幕、默认倍速与控件背景设置；点 UP 主名进入主页并可关注；相关视频直接替换当前页；搜索支持模糊匹配、UP 主合集与下拉刷新。"),
        ("timer", "细节修复", "睡眠定时显示分钟与倒计时，到点同时停止哔哩哔哩播放；锁屏沉浸封面开关即时生效；歌词同步修复；首页标题不再重复。"),
        ("iphone", "iOS 15–18 兼容版", "修复点进歌单、专辑等详情页空白的问题。"),
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
