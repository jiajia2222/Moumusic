import SwiftUI
import UIKit

/// 歌词海报：选几句歌词，配上封面主色背景，生成一张图片分享（Moumusic 原创功能）。
struct LyricPosterSheet: View {
    let song: Song
    let lyrics: [LyricLine]
    let currentTime: Double

    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int> = []
    @State private var coverImage: UIImage?
    @State private var tint: Color = Color(red: 0.2, green: 0.25, blue: 0.4)
    @State private var shareItem: ShareFileItem?
    @State private var rendering = false

    private var lines: [(index: Int, text: String)] {
        lyrics.enumerated().compactMap { index, line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (index, text)
        }
    }

    private var chosenTexts: [String] {
        lines.filter { selected.contains($0.index) }.map { $0.text }
    }

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                VStack(spacing: 12) {
                    LyricPosterCanvas(song: song, lines: chosenTexts.isEmpty ? ["选择下方歌词生成海报"] : chosenTexts, cover: coverImage, tint: tint)
                        .aspectRatio(4.0 / 5.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.horizontal, 40)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(lines, id: \.index) { item in
                                let isOn = selected.contains(item.index)
                                Button {
                                    BeansHaptics.select()
                                    if isOn { selected.remove(item.index) }
                                    else if selected.count < 6 { selected.insert(item.index) }
                                    else { ToastCenter.shared.show("最多选择 6 句") }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isOn ? Color.beansAmber : Color.beansComment)
                                        Text(item.text)
                                            .font(BeansFont.appFont(15))
                                            .foregroundStyle(Color.beansLabel)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(isOn ? Color.beansAmber.opacity(0.12) : Color.beansLabel.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    GlassButton(title: rendering ? "正在生成…" : "生成海报并分享", systemName: "square.and.arrow.up", prominent: true) {
                        Task { await render() }
                    }
                    .disabled(chosenTexts.isEmpty || rendering)
                    .opacity(chosenTexts.isEmpty ? 0.5 : 1)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("歌词海报")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .task { await prepare() }
    }

    @MainActor
    private func prepare() async {
        // 默认选中当前播放位置开始的 3 句。
        if let current = lyrics.lastIndex(where: { $0.time <= currentTime }) {
            let nearby = lines.filter { $0.index >= current }.prefix(3).map { $0.index }
            selected = Set(nearby)
        }
        guard let url = song.coverURL, let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
        coverImage = image
        if let color = PaletteExtractor.dominantColor(in: image) { tint = color.color }
    }

    @MainActor
    private func render() async {
        rendering = true
        defer { rendering = false }
        let size = CGSize(width: 1080, height: 1350)
        let poster = LyricPosterCanvas(song: song, lines: chosenTexts, cover: coverImage, tint: tint)
            .frame(width: size.width, height: size.height)
        let host = UIHostingController(rootView: poster)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .clear
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) }
        window.isHidden = true
        guard let data = image.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Moumusic-lyrics-\(Int(Date().timeIntervalSince1970)).png")
        try? data.write(to: url)
        shareItem = ShareFileItem(url: url)
    }
}

/// 海报画布（预览与导出共用）：封面主色渐变 + 模糊封面 + 歌词 + 歌曲信息。
struct LyricPosterCanvas: View {
    let song: Song
    let lines: [String]
    let cover: UIImage?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let u = geo.size.width / 1080
            ZStack {
                LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55), Color.black.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let cover {
                    Image(uiImage: cover)
                        .resizable().scaledToFill()
                        .blur(radius: 60 * u)
                        .opacity(0.35)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 40 * u) {
                    HStack(spacing: 28 * u) {
                        Group {
                            if let cover { Image(uiImage: cover).resizable().scaledToFill() }
                            else { Color.white.opacity(0.15) }
                        }
                        .frame(width: 150 * u, height: 150 * u)
                        .clipShape(RoundedRectangle(cornerRadius: 28 * u, style: .continuous))
                        VStack(alignment: .leading, spacing: 8 * u) {
                            Text(song.name).font(.system(size: 46 * u, weight: .bold)).lineLimit(2)
                            Text(song.artists).font(.system(size: 32 * u)).opacity(0.75).lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 30 * u) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 58 * u, weight: .bold))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Text("Moumusic").font(.system(size: 30 * u, weight: .semibold))
                        Spacer()
                        Text("听见喜欢的每一句").font(.system(size: 28 * u))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
                .padding(80 * u)
            }
        }
    }
}
