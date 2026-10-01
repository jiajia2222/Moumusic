import SwiftUI

/// 批量下载：按顺序下载一批歌曲，完成后可一次性分享。
@MainActor
final class BatchDownloadManager: ObservableObject {
    static let shared = BatchDownloadManager()

    enum Phase { case idle, running, finished, cancelled }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var title = ""
    @Published private(set) var total = 0
    @Published private(set) var completed = 0
    @Published private(set) var currentName = ""
    @Published private(set) var succeeded: [URL] = []
    @Published private(set) var failedNames: [String] = []
    @Published private(set) var errorText: String?

    private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .running }

    var summary: String {
        switch phase {
        case .idle: return ""
        case .running: return "正在下载 \(completed)/\(total)：\(currentName)"
        case .finished: return "批量下载完成：成功 \(succeeded.count)，失败 \(failedNames.count)"
        case .cancelled: return "已取消：成功 \(succeeded.count)"
        }
    }

    func start(songs: [Song], title: String, quality: DownloadQuality = .downloadCurrent) {
        guard !isRunning else { return }
        let unique = Self.deduplicated(songs)
        guard !unique.isEmpty else {
            errorText = "当前歌单没有歌曲"
            return
        }
        errorText = nil
        self.title = title
        total = unique.count
        completed = 0
        succeeded = []
        failedNames = []
        phase = .running
        BeansLogger.shared.log("开始批量下载：\(title) 共 \(unique.count) 首 音质=\(quality.rawValue)", level: .info)
        task = Task { [weak self] in
            for song in unique {
                if Task.isCancelled { break }
                guard let self = self else { return }
                self.currentName = song.name
                let result = await DownloadManager.shared.download(song: song, quality: quality)
                switch result {
                case .success(let value): self.succeeded.append(value.url)
                case .failure: self.failedNames.append(song.name)
                }
                self.completed += 1
            }
            guard let self = self else { return }
            self.phase = Task.isCancelled ? .cancelled : .finished
            BeansLogger.shared.log("\(self.summary)", level: .info)
        }
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        phase = .cancelled
        BeansLogger.shared.log("批量下载已取消", level: .info)
    }

    func reset() {
        guard !isRunning else { return }
        phase = .idle
        succeeded = []
        failedNames = []
        completed = 0
        total = 0
    }

    private static func deduplicated(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.identityKey).inserted }
    }
}

struct BatchDownloadSheet: View {
    let songs: [Song]
    let title: String

    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = BatchDownloadManager.shared
    @AppStorage(ThirdPartyAudioQuality.downloadStorageKey) private var qualityRaw = ThirdPartyAudioQuality.kb320.rawValue
    @State private var showShare = false

    private var quality: DownloadQuality { DownloadQuality(sourceValue: qualityRaw) ?? .kb320 }

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(title).font(BeansFont.appFont(18, .bold)).foregroundStyle(Color.beansLabel)
                                Text("共 \(songs.count) 首 · 按顺序下载并保存在本地，可在完成后一次性分享")
                                    .font(BeansFont.appFont(12)).foregroundStyle(Color.beansComment)
                                Picker("音质", selection: $qualityRaw) {
                                    ForEach([DownloadQuality.kb128, .kb320, .flac], id: \.rawValue) { q in
                                        Text(q.displayName).tag(q.rawValue)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .disabled(manager.isRunning)
                            }
                        }
                        if manager.phase != .idle {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    if manager.total > 0 {
                                        ProgressView(value: Double(manager.completed), total: Double(max(manager.total, 1)))
                                            .tint(Color.beansAmber)
                                    }
                                    Text(manager.summary).font(BeansFont.appFont(13)).foregroundStyle(Color.beansLabel)
                                    if !manager.failedNames.isEmpty {
                                        Text("失败：" + manager.failedNames.prefix(8).joined(separator: "、") + (manager.failedNames.count > 8 ? "…" : ""))
                                            .font(BeansFont.appFont(11)).foregroundStyle(Color.red)
                                    }
                                }
                            }
                        }
                        if let error = manager.errorText {
                            Text(error).font(BeansFont.appFont(13)).foregroundStyle(Color.red)
                        }
                        actionButtons
                    }
                    .padding(16)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("批量下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: manager.succeeded)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if manager.isRunning {
            GlassButton(title: "取消批量下载", systemName: "xmark.circle") { manager.cancel() }
        } else {
            GlassButton(title: manager.phase == .idle ? "开始批量下载" : "重新批量下载", systemName: "arrow.down.circle", prominent: true) {
                manager.start(songs: songs, title: title, quality: quality)
            }
            if !manager.succeeded.isEmpty {
                GlassButton(title: "分享已下载歌曲（\(manager.succeeded.count)）", systemName: "square.and.arrow.up") {
                    showShare = true
                }
            }
        }
    }
}

/// 歌曲列表页右上角的「批量下载 / 复制全部歌名」菜单。
struct BatchDownloadToolbarModifier: ViewModifier {
    let songs: [Song]
    let title: String

    @EnvironmentObject private var theme: ThemeStore
    @State private var showSheet = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showSheet = true
                        } label: {
                            Label("批量下载歌单", systemImage: "arrow.down.circle")
                        }
                        .disabled(songs.isEmpty)
                        Button {
                            UIPasteboard.general.string = songs.map { "\($0.name) - \($0.artists)" }.joined(separator: "\n")
                            ToastCenter.shared.show("已复制全部歌名")
                        } label: {
                            Label("复制全部歌名", systemImage: "doc.on.doc")
                        }
                        .disabled(songs.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showSheet) {
                BatchDownloadSheet(songs: songs, title: title)
                    .environmentObject(theme)
            }
    }
}

extension View {
    func batchDownloadToolbar(songs: [Song], title: String) -> some View {
        modifier(BatchDownloadToolbarModifier(songs: songs, title: title))
    }
}
