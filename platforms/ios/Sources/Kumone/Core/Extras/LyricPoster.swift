#if os(iOS)
import SwiftUI
import UIKit

/// Lyric poster: pick a few lines, render them on a cover-tinted canvas and
/// share the image (Moumusic original).
struct LyricPosterSheet: View {
    let track: Track
    let lyrics: [LyricLine]
    let currentTime: Double

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int> = []
    @State private var coverImage: UIImage?
    @State private var tint: Color = Color(red: 0.2, green: 0.25, blue: 0.4)
    @State private var shareURL: URL?
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
        NavigationStack {
            VStack(spacing: 12) {
                LyricPosterCanvas(
                    track: track,
                    lines: chosenTexts.isEmpty ? ["选择下方歌词生成海报"] : chosenTexts,
                    cover: coverImage,
                    tint: tint
                )
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 40)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(lines, id: \.index) { item in
                            let isOn = selected.contains(item.index)
                            Button {
                                if isOn {
                                    selected.remove(item.index)
                                } else if selected.count < 6 {
                                    selected.insert(item.index)
                                } else {
                                    ToastCenter.shared.show("最多选择 6 句")
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isOn ? Theme.accent : Color.secondary)
                                    Text(item.text)
                                        .font(.system(size: 15))
                                        .foregroundStyle(Color.primary)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    isOn ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                GlassButton(
                    title: rendering ? "正在生成…" : "生成海报并分享",
                    systemName: "square.and.arrow.up",
                    prominent: true
                ) {
                    Task { await render() }
                }
                .disabled(chosenTexts.isEmpty || rendering)
                .opacity(chosenTexts.isEmpty ? 0.5 : 1)
                .padding(.bottom, 16)
            }
            .navigationTitle("歌词海报")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL {
                ActivityShareSheet(items: [shareURL])
            }
        }
        .task { await prepare() }
    }

    @MainActor
    private func prepare() async {
        if let current = lyrics.lastIndex(where: { $0.time <= currentTime }) {
            selected = Set(lines.filter { $0.index >= current }.prefix(3).map { $0.index })
        }
        guard let url = track.album.picUrl?.resizedImageURL(768),
              let image = await ImageCache.shared.image(for: url) else { return }
        coverImage = image
        tint = ArtworkPalette.extract(from: image, cacheKey: url.absoluteString).primary
    }

    @MainActor
    private func render() async {
        rendering = true
        defer { rendering = false }
        let size = CGSize(width: 1080, height: 1350)
        let poster = LyricPosterCanvas(track: track, lines: chosenTexts, cover: coverImage, tint: tint)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: poster)
        renderer.scale = 1
        guard let image = renderer.uiImage, let data = image.pngData() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Moumusic-lyrics-\(Int(Date().timeIntervalSince1970)).png")
        try? data.write(to: url)
        shareURL = url
    }
}

struct LyricPosterCanvas: View {
    let track: Track
    let lines: [String]
    let cover: UIImage?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let u = geo.size.width / 1080
            ZStack {
                LinearGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.55), Color.black.opacity(0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
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
                            if let cover {
                                Image(uiImage: cover).resizable().scaledToFill()
                            } else {
                                Color.white.opacity(0.15)
                            }
                        }
                        .frame(width: 150 * u, height: 150 * u)
                        .clipShape(RoundedRectangle(cornerRadius: 28 * u, style: .continuous))
                        VStack(alignment: .leading, spacing: 8 * u) {
                            Text(track.name).font(.system(size: 46 * u, weight: .bold)).lineLimit(2)
                            Text(track.artistNames).font(.system(size: 32 * u)).opacity(0.75).lineLimit(1)
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

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
