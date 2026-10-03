import SwiftUI

/// 哔哩哔哩设置（iOS 15–18）：播放、弹幕、屏蔽词、空降助手。键名与播放器共用。
struct CompatBiliSettingsView: View {
    @Environment(\.presentationMode) private var presentation

    @AppStorage("moumusic.bili.autoplay") private var autoplay = true
    @AppStorage("moumusic.bili.autoFullscreen") private var autoFullscreen = true
    @AppStorage("moumusic.bili.sponsorBlock") private var sponsorBlock = true
    @AppStorage("moumusic.bili.preferredQuality") private var preferredQuality = 0
    @AppStorage("moumusic.bili.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("moumusic.bili.danmaku.opacity") private var opacity = 0.9
    @AppStorage("moumusic.bili.danmaku.fontScale") private var fontScale = 1.0
    @AppStorage("moumusic.bili.danmaku.area") private var area = 0.6
    @AppStorage("moumusic.bili.danmaku.level") private var level = 2
    @AppStorage("moumusic.bili.danmaku.hideTop") private var hideTop = false
    @AppStorage("moumusic.bili.danmaku.hideBottom") private var hideBottom = false
    @AppStorage("moumusic.bili.danmaku.blocklist") private var blocklist = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("播放")) {
                    Toggle("打开视频自动播放", isOn: $autoplay)
                    Toggle("横屏自动全屏（竖屏视频自动竖屏全屏）", isOn: $autoFullscreen)
                    Toggle("自动跳过广告片段（空降助手）", isOn: $sponsorBlock)
                    Picker("默认画质", selection: $preferredQuality) {
                        Text("自动（最高可用）").tag(0)
                        Text("720P").tag(64)
                        Text("1080P").tag(80)
                        Text("1080P 高码率").tag(112)
                        Text("1080P 60 帧").tag(116)
                        Text("4K").tag(120)
                    }
                    Text("实际画质取决于视频本身和账号权限，播放页的画质菜单可临时切换。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("弹幕")) {
                    Toggle("显示弹幕", isOn: $danmakuEnabled)
                    Picker("弹幕速度", selection: $level) {
                        Text("极慢").tag(0)
                        Text("慢").tag(1)
                        Text("中等").tag(2)
                        Text("快").tag(3)
                        Text("极快").tag(4)
                    }
                    .pickerStyle(.segmented)
                    slider("不透明度", value: $opacity, range: 0.2...1, text: "\(Int(opacity * 100))%")
                    slider("字号", value: $fontScale, range: 0.6...1.6, text: String(format: "%.1fx", fontScale))
                    Picker("显示区域", selection: $area) {
                        Text("1/4").tag(0.25)
                        Text("半屏").tag(0.5)
                        Text("3/5").tag(0.6)
                        Text("3/4").tag(0.75)
                        Text("全屏").tag(1.0)
                    }
                    Toggle("屏蔽顶部弹幕", isOn: $hideTop)
                    Toggle("屏蔽底部弹幕", isOn: $hideBottom)
                    TextField("弹幕屏蔽词（用逗号或空格分隔）", text: $blocklist)
                }
            }
            .navigationTitle("哔哩哔哩设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(text).foregroundColor(.secondary) }
            Slider(value: value, in: range)
        }
    }
}
