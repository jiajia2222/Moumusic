import Foundation
import SwiftUI
import WidgetKit
import ActivityKit
import UIKit
import KumoneIOSFeature

private let widgetSuite = "group.com.jiajia2222.moumusic"

private enum WidgetKeys {
    static let title = "widget.track.title"
    static let artist = "widget.track.artist"
    static let lyric = "widget.lyric"
    static let updatedAt = "widget.updatedAt"
}

struct LyricsWidgetEntry: TimelineEntry {
    let date: Date
    let title: String
    let artist: String
    let lyric: String

    var hasTrack: Bool {
        !title.isEmpty && title != "Moumusic"
    }

    var displayLyric: String {
        lyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无歌词" : lyric
    }
}

struct LyricsWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LyricsWidgetEntry {
        LyricsWidgetEntry(
            date: .now,
            title: "Moumusic",
            artist: "歌词小组件",
            lyric: "播放歌曲后显示当前歌词"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LyricsWidgetEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricsWidgetEntry>) -> Void) {
        let entry = loadEntry()
        // The app calls reloadTimelines when the current lyric changes. This
        // entry is only a safety refresh for a widget restored after the app
        // was suspended; WidgetKit may throttle it according to system budget.
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(45))))
    }

    private func loadEntry() -> LyricsWidgetEntry {
        let defaults = UserDefaults(suiteName: widgetSuite)
        let updatedAt = defaults?.double(forKey: WidgetKeys.updatedAt) ?? 0
        return LyricsWidgetEntry(
            date: updatedAt > 0 ? Date(timeIntervalSince1970: updatedAt) : .now,
            title: defaults?.string(forKey: WidgetKeys.title) ?? "Moumusic",
            artist: defaults?.string(forKey: WidgetKeys.artist) ?? "歌词小组件",
            lyric: defaults?.string(forKey: WidgetKeys.lyric) ?? "播放歌曲后显示当前歌词"
        )
    }
}

struct MoumusicLyricsWidgetView: View {
    let entry: LyricsWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if #available(iOS 17.0, *) {
            content
                .containerBackground(for: .widget) {
                    WidgetBackground()
                }
        } else {
            content
                .background(WidgetBackground())
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            SmallLyricsView(entry: entry)
        case .systemMedium:
            MediumLyricsView(entry: entry)
        case .systemLarge:
            LargeLyricsView(entry: entry)
        case .accessoryRectangular:
            LockScreenLyricsView(entry: entry)
        case .accessoryInline:
            Text("Moumusic  ·  \(entry.displayLyric)")
                .lineLimit(1)
        default:
            SmallLyricsView(entry: entry)
        }
    }
}

private struct WidgetHeader: View {
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            Text("M")
                .font(.system(size: compact ? 10 : 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: compact ? 20 : 24, height: compact ? 20 : 24)
                .background(.primary, in: Circle())
            Text("Moumusic")
                .font(.system(size: compact ? 11 : 13, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
            Image(systemName: "waveform")
                .font(.system(size: compact ? 11 : 14, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
        }
        .foregroundStyle(.primary)
    }
}

private struct SmallLyricsView: View {
    let entry: LyricsWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(compact: true)
            Spacer(minLength: 8)
            Text(entry.displayLyric)
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .lineLimit(3)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            TrackLabel(entry: entry, compact: true)
        }
        .padding(14)
        .widgetSurface(cornerRadius: 22)
    }
}

private struct MediumLyricsView: View {
    let entry: LyricsWidgetEntry

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                WidgetHeader(compact: false)
                Text(entry.displayLyric)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.78)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text("当前歌词")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(.primary.opacity(0.12))
                .frame(width: 1)

            TrackLabel(entry: entry, compact: false)
                .frame(width: 116, alignment: .leading)
        }
        .padding(16)
        .widgetSurface(cornerRadius: 24)
    }
}

private struct LargeLyricsView: View {
    let entry: LyricsWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(compact: false)
            Spacer(minLength: 18)
            Text("当前歌词")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(entry.displayLyric)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .lineLimit(5)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.leading)
                .padding(.top, 8)
            Spacer(minLength: 20)
            TrackLabel(entry: entry, compact: false)
        }
        .padding(20)
        .widgetSurface(cornerRadius: 28)
    }
}

private struct LockScreenLyricsView: View {
    let entry: LyricsWidgetEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "quote.bubble.fill")
                .font(.caption)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayLyric)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Text(entry.hasTrack ? entry.title : "Moumusic")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct TrackLabel: View {
    let entry: LyricsWidgetEntry
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            Text(entry.hasTrack ? entry.title : "等待播放")
                .font(.system(size: compact ? 12 : 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Text(entry.hasTrack && !entry.artist.isEmpty ? entry.artist : "打开 Moumusic 播放歌曲")
                .font(.system(size: compact ? 10 : 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct WidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color(red: 0.075, green: 0.08, blue: 0.09) : Color(red: 0.94, green: 0.96, blue: 0.95))
            Circle()
                .fill(.mint.opacity(colorScheme == .dark ? 0.16 : 0.12))
                .frame(width: 170, height: 170)
                .blur(radius: 34)
                .offset(x: 76, y: -64)
            Circle()
                .fill(.blue.opacity(colorScheme == .dark ? 0.11 : 0.08))
                .frame(width: 150, height: 150)
                .blur(radius: 38)
                .offset(x: -86, y: 72)
        }
        .ignoresSafeArea()
    }
}

private extension View {
    func widgetSurface(cornerRadius: CGFloat) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.primary.opacity(0.10), lineWidth: 0.8)
            }
    }
}

struct MoumusicLyricsWidget: Widget {
    let kind = "MoumusicLyricsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LyricsWidgetProvider()) { entry in
            MoumusicLyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("Moumusic 歌词")
        .description("在主屏幕或锁屏查看当前播放歌词")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryInline,
        ])
    }
}

@available(iOS 16.1, *)
private struct PlaybackArtwork: View {
    let urlString: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let image = sharedImage {
                image
                    .resizable()
                    .scaledToFill()
            } else if let urlString, let url = URL(string: urlString), !url.isFileURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    /// The app writes artwork into the App Group before or immediately after
    /// starting the activity. Reading that file synchronously is reliable in
    /// the widget extension even when the device is locked or offline.
    private var sharedImage: Image? {
        guard let cachedURL = MoumusicSharedArtworkStore.cachedURL(for: urlString),
              let data = try? Data(contentsOf: cachedURL),
              let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
    }

    private var placeholder: some View {
        ZStack {
            Color.white.opacity(0.14)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

@available(iOS 16.1, *)
private struct PlaybackLyricText: View {
    let lyric: String?

    var body: some View {
        if let lyric,
           !lyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(lyric)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

@available(iOS 16.1, *)
private struct PlaybackProgressView: View {
    let state: MoumusicPlaybackActivityAttributes.ContentState

    var body: some View {
        if state.isPlaying {
            ProgressView(timerInterval: playbackInterval, countsDown: false)
                .tint(.red)
        } else {
            ProgressView(
                value: state.duration > 0 ? state.elapsed : 0,
                total: max(state.duration, 1)
            )
            .tint(.red)
        }
    }

    private var playbackInterval: ClosedRange<Date> {
        let duration = max(state.duration, 1)
        let elapsed = min(max(state.elapsed, 0), duration)
        let start = state.updatedAt.addingTimeInterval(-elapsed)
        return start...start.addingTimeInterval(duration)
    }
}

@available(iOS 16.1, *)
private struct PlaybackActivityLockScreenView: View {
    let state: MoumusicPlaybackActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            PlaybackArtwork(urlString: state.artworkURL, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(state.artist.isEmpty ? "Moumusic" : state.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                PlaybackLyricText(lyric: state.currentLyric)
                PlaybackProgressView(state: state)
            }
            Spacer(minLength: 0)
            Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .activityBackgroundTint(.black.opacity(0.86))
        .activitySystemActionForegroundColor(.white)
    }
}

@available(iOS 16.1, *)
struct MoumusicPlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MoumusicPlaybackActivityAttributes.self) { context in
            PlaybackActivityLockScreenView(state: context.state)
                .widgetURL(URL(string: "moumusic://now-playing"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PlaybackArtwork(urlString: context.state.artworkURL, size: 42)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        PlaybackLyricText(lyric: context.state.currentLyric)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PlaybackProgressView(state: context.state)
                }
            } compactLeading: {
                PlaybackArtwork(urlString: context.state.artworkURL, size: 22)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption.weight(.semibold))
            } minimal: {
                Image(systemName: context.state.isPlaying ? "waveform" : "music.note")
                    .font(.caption.weight(.semibold))
            }
            .widgetURL(URL(string: "moumusic://now-playing"))
            .keylineTint(.red)
        }
    }
}

@main
struct MoumusicWidgetBundle: WidgetBundle {
    var body: some Widget {
        MoumusicLyricsWidget()
        if #available(iOS 16.1, *) {
            MoumusicPlaybackLiveActivity()
        }
    }
}
