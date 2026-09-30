import SwiftUI

/// Bilibili has its own settings page so video/audio switches do not get lost
/// among global playback, lyrics, and LX-source preferences.
struct BilibiliSettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsCard("内容") {
                    Picker("B 站模式", selection: $settings.bilibiliMode) {
                        ForEach(BilibiliMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
#if os(iOS)
                    .pickerStyle(.segmented)
#endif
                    Text(settings.bilibiliMode.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("显示弹幕", isOn: $settings.bilibiliDanmakuEnabled)

                    Text("听与看是互斥模式；切换后只保留当前模式的入口，避免播放器同时出现两套能力。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard("首页推荐") {
                    Picker("推荐客户端", selection: $settings.bilibiliRecommendationSource) {
                        ForEach(BilibiliRecommendationSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
#if os(iOS)
                    .pickerStyle(.segmented)
#endif
                    Text(settings.bilibiliRecommendationSource.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                settingsCard("说明") {
                    Label("登录仅用于同步 B 站公开资料、推荐和播放记录。", systemImage: "lock.shield")
                        .font(.subheadline)
                    Text("视频页面支持推荐、排行榜、分区、搜索与直播；播放清晰度和字幕选项会在对应内容页面提供。账号登录仍在“账号与同步”中管理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("哔哩哔哩设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func settingsCard<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline.weight(.semibold))
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}
