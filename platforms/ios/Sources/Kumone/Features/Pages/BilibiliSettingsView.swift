import SwiftUI

/// Bilibili has its own settings page so video/audio switches do not get lost
/// among global playback, lyrics, and LX-source preferences.
struct BilibiliSettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("moumusic.bili.preferredQuality") private var preferredQuality = 80
    @AppStorage("moumusic.bili.autoplay") private var autoplay = true
    @AppStorage("moumusic.bili.autoFullscreen") private var autoFullscreen = true
    @AppStorage("moumusic.bili.danmaku.opacity") private var danmakuOpacity = 0.9
    @AppStorage("moumusic.bili.danmaku.fontScale") private var danmakuScale = 1.0
    @AppStorage("moumusic.bili.danmaku.area") private var danmakuArea = 0.6
    @AppStorage("moumusic.bili.danmaku.speed") private var danmakuSpeed = 90.0
    @AppStorage("moumusic.bili.danmaku.hideTop") private var hideTopDanmaku = false
    @AppStorage("moumusic.bili.danmaku.hideBottom") private var hideBottomDanmaku = false

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

                settingsCard("视频偏好") {
                    Picker("默认清晰度", selection: $preferredQuality) {
                        Text("8K 超高清").tag(127)
                        Text("杜比视界").tag(126)
                        Text("HDR 真彩").tag(125)
                        Text("4K 超清").tag(120)
                        Text("1080P 60帧").tag(116)
                        Text("1080P 高码率").tag(112)
                        Text("1080P").tag(80)
                        Text("720P").tag(64)
                        Text("480P").tag(32)
                        Text("360P").tag(16)
                    }
                    Text("实际清晰度取决于视频与账号权限（4K、8K、杜比视界、HDR 需要大会员，且视频本身提供该规格）；播放页的「画质」菜单可临时切换。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("打开视频自动播放", isOn: $autoplay)
                    Toggle("横屏自动全屏（竖屏视频播放时自动竖屏全屏）", isOn: $autoFullscreen)
                    Toggle("显示弹幕", isOn: $settings.bilibiliDanmakuEnabled)
                    Label("解码：高画质优先 HEVC，其余 H.264，系统硬件解码；音频自动选用杜比/无损/最高码率", systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard("弹幕") {
                    sliderRow("不透明度", value: $danmakuOpacity, range: 0.2...1, text: "\(Int(danmakuOpacity * 100))%")
                    sliderRow("字号", value: $danmakuScale, range: 0.6...1.6, text: String(format: "%.1fx", danmakuScale))
                    Picker("显示区域", selection: $danmakuArea) {
                        Text("1/4 屏").tag(0.25)
                        Text("半屏").tag(0.5)
                        Text("3/4 屏").tag(0.75)
                        Text("全屏").tag(1.0)
                    }
                    sliderRow("滚动速度（固定值，越右越快）", value: $danmakuSpeed, range: 40...240,
                              text: "\(Int(danmakuSpeed)) 点/秒")
                    Toggle("屏蔽顶部弹幕", isOn: $hideTopDanmaku)
                    Toggle("屏蔽底部弹幕", isOn: $hideBottomDanmaku)
                    Text("播放中修改约 1 秒内生效。看过的视频会记住进度，下次打开自动续播。")
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

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(text).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    private func settingsCard<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline.weight(.semibold))
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(14)
                .mouMaterialBackground(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}
