import Foundation
import SwiftUI

#if os(iOS)
/// Per-component layout data for the iPhone player.  This is deliberately
/// stored separately from the selected player mode: changing the mode never
/// destroys a user's adjustments in another mode.
enum PlayerLayoutPart: String, CaseIterable, Identifiable {
    case artwork = "封面"
    case metadata = "歌曲信息"
    case lyrics = "歌词"
    case progress = "进度与音质"
    case volume = "音量"
    case controls = "播放控制"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .artwork: "photo"
        case .metadata: "text.alignleft"
        case .lyrics: "quote.bubble"
        case .progress: "timeline.selection"
        case .volume: "speaker.wave.2"
        case .controls: "playpause"
        }
    }
}

struct PlayerLayoutEntry: Codable, Equatable {
    var horizontalOffset: CGFloat = 0
    var verticalOffset: CGFloat = 0
    var scale: CGFloat = 1

    var isDefault: Bool {
        abs(horizontalOffset) < 0.01 && abs(verticalOffset) < 0.01 && abs(scale - 1) < 0.01
    }
}

/// Ported from Beans' persistent layout model, adapted for Moumusic's six
/// native player surfaces.  Values are clamped before writing so an accidental
/// drag cannot leave a player control outside the visible screen.
@MainActor
final class PlayerLayoutStore: ObservableObject {
    static let shared = PlayerLayoutStore()

    @Published private(set) var layouts: [String: [String: PlayerLayoutEntry]] {
        didSet { scheduleSave() }
    }

    private static let storageKey = "moumusic.playerComponentLayouts.v1"
    private var pendingSave: DispatchWorkItem?

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode([String: [String: PlayerLayoutEntry]].self, from: data) else {
            layouts = [:]
            return
        }
        layouts = stored
    }

    func entry(for part: PlayerLayoutPart, mode: NowPlayingMode) -> PlayerLayoutEntry {
        layouts[mode.rawValue]?[part.rawValue] ?? PlayerLayoutEntry()
    }

    func update(_ entry: PlayerLayoutEntry, for part: PlayerLayoutPart, mode: NowPlayingMode) {
        var perMode = layouts[mode.rawValue] ?? [:]
        perMode[part.rawValue] = PlayerLayoutEntry(
            horizontalOffset: min(max(entry.horizontalOffset, -72), 72),
            verticalOffset: min(max(entry.verticalOffset, -96), 96),
            scale: min(max(entry.scale, 0.72), 1.28)
        )
        layouts[mode.rawValue] = perMode
    }

    func reset(part: PlayerLayoutPart, mode: NowPlayingMode) {
        var perMode = layouts[mode.rawValue] ?? [:]
        perMode.removeValue(forKey: part.rawValue)
        layouts[mode.rawValue] = perMode
    }

    func reset(mode: NowPlayingMode) {
        layouts.removeValue(forKey: mode.rawValue)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = layouts
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

/// A functional layout editor instead of a decorative player-mode picker.
/// Each card changes the real component in the currently selected player mode.
struct PlayerLayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var store = PlayerLayoutStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("编辑的播放器模式", selection: $settings.nowPlayingMode) {
                        ForEach(NowPlayingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Text("只修改当前模式。封面、歌词、进度和控制区互相独立，不会再因为切换样式而全部变成同一个布局。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("播放器布局")
                }

                ForEach(PlayerLayoutPart.allCases) { part in
                    layoutSection(part)
                }

                Section {
                    Button("还原当前模式布局", role: .destructive) {
                        store.reset(mode: settings.nowPlayingMode)
                    }
                }
            }
            .navigationTitle("自定义播放器布局")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func layoutSection(_ part: PlayerLayoutPart) -> some View {
        let entry = store.entry(for: part, mode: settings.nowPlayingMode)
        Section {
            HStack(spacing: 9) {
                Image(systemName: part.symbol)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                Text(part.rawValue)
                Spacer()
                if !entry.isDefault {
                    Button("还原") { store.reset(part: part, mode: settings.nowPlayingMode) }
                        .font(.caption.weight(.semibold))
                }
            }

            layoutSlider("左右位置", value: entry.horizontalOffset, range: -72...72, suffix: " pt") { value in
                var next = entry
                next.horizontalOffset = value
                store.update(next, for: part, mode: settings.nowPlayingMode)
            }
            layoutSlider("上下位置", value: entry.verticalOffset, range: -96...96, suffix: " pt") { value in
                var next = entry
                next.verticalOffset = value
                store.update(next, for: part, mode: settings.nowPlayingMode)
            }
            layoutSlider("缩放", value: entry.scale, range: 0.72...1.28, suffix: "×") { value in
                var next = entry
                next.scale = value
                store.update(next, for: part, mode: settings.nowPlayingMode)
            }
        }
    }

    private func layoutSlider(
        _ title: String,
        value: CGFloat,
        range: ClosedRange<CGFloat>,
        suffix: String,
        onChange: @escaping (CGFloat) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: suffix == "×" ? "%.2f×" : "%+.0f pt", Double(value)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(CGFloat($0)) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
        }
    }
}
#endif
