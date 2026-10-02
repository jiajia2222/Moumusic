import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MoumusicLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        MoumusicLiveActivityWidget()
    }
}

struct MoumusicLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MoumusicActivityAttributes.self) { context in
            LockScreenPlayerView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.28))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.note.list")
                        .font(.title2)
                        .foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PlayerProgressView(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "music.note").foregroundStyle(.orange)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
            } minimal: {
                Image(systemName: "music.note").foregroundStyle(.orange)
            }
            .keylineTint(.orange)
        }
    }
}

private struct LockScreenPlayerView: View {
    let state: MoumusicActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.headline).lineLimit(1)
                    Text(state.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .font(.title3)
            }
            PlayerProgressView(state: state)
        }
        .padding(16)
    }
}

private struct PlayerProgressView: View {
    let state: MoumusicActivityAttributes.ContentState

    var body: some View {
        if state.isPlaying, state.endDate > state.startDate {
            ProgressView(timerInterval: state.startDate...state.endDate, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(.orange)
        } else {
            ProgressView(value: min(max(state.elapsed, 0), max(state.duration, 1)), total: max(state.duration, 1))
                .tint(.orange)
        }
    }
}
