#if os(iOS)
import SwiftUI

struct DownloadOptionsSheet: View {
    let tracks: [Track]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedQuality: AudioQuality
    @State private var available: [AudioQuality] = []
    @State private var isLoading = true

    init(tracks: [Track]) {
        self.tracks = tracks
        _selectedQuality = State(initialValue: SettingsManager.shared.audioQuality)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("下载内容") {
                    Text(tracks.count == 1 ? tracks[0].name : "共 \(tracks.count) 首歌曲")
                        .lineLimit(2)
                    if tracks.count == 1 {
                        Text(tracks[0].artistNames)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("下载音质") {
                    ForEach(available.isEmpty ? [.standard] : available) { quality in
                        Button {
                            selectedQuality = quality
                        } label: {
                            HStack {
                                Text(quality.sourceDisplayName)
                                Spacer()
                                if selectedQuality == quality {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .frame(minHeight: 44)
                    }
                    Text(isLoading
                         ? "正在读取当前音源支持的音质…"
                         : "不支持的音质会自动降级，并显示实际下载音质")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        DownloadManager.shared.downloadBatch(tracks, quality: selectedQuality)
                        dismiss()
                    } label: {
                        Label(tracks.count > 1 ? "开始批量下载" : "开始下载",
                              systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("下载设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .task {
            guard let first = tracks.first else {
                isLoading = false
                return
            }
            available = await DownloadManager.shared.availableQualities(for: first)
            if !available.contains(selectedQuality), let first = available.first {
                selectedQuality = first
            }
            isLoading = false
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
