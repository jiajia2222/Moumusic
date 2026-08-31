import SwiftUI
import WidgetKit

private let widgetSuite = "group.com.jiajia2222.moumusic"

struct LyricsWidgetEntry: TimelineEntry {
    let date: Date
    let title: String
    let artist: String
    let lyric: String
}

struct LyricsWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LyricsWidgetEntry {
        LyricsWidgetEntry(date: .now, title: "Moumusic", artist: "", lyric: "播放歌曲后显示实时歌词")
    }

    func getSnapshot(in context: Context, completion: @escaping (LyricsWidgetEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricsWidgetEntry>) -> Void) {
        completion(Timeline(entries: [loadEntry()], policy: .after(.now.addingTimeInterval(60))))
    }

    private func loadEntry() -> LyricsWidgetEntry {
        let defaults = UserDefaults(suiteName: widgetSuite)
        return LyricsWidgetEntry(
            date: .now,
            title: defaults?.string(forKey: "widget.track.title") ?? "Moumusic",
            artist: defaults?.string(forKey: "widget.track.artist") ?? "",
            lyric: defaults?.string(forKey: "widget.lyric") ?? "播放歌曲后显示实时歌词"
        )
    }
}

struct MoumusicLyricsWidgetView: View {
    let entry: LyricsWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("歌词", systemImage: "quote.bubble.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(entry.lyric)
                .font(.headline)
                .lineLimit(3)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            Text(entry.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if !entry.artist.isEmpty {
                Text(entry.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .background {
            LinearGradient(colors: [.pink.opacity(0.24), .orange.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

@main
struct MoumusicLyricsWidget: Widget {
    let kind = "MoumusicLyricsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LyricsWidgetProvider()) { entry in
            MoumusicLyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("Moumusic 歌词")
        .description("显示当前播放歌曲的同步歌词")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}
