import SwiftUI

/// Public song comments. This is deliberately read-only: no provider login
/// or account action is required to browse comments.
struct SongCommentsSheet: View {
    private enum Sort: String, CaseIterable, Identifiable {
        case hot
        case latest

        var id: String { rawValue }
        var title: String { self == .hot ? "热门评论" : "最新评论" }
    }

    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var hotComments: [NeteaseAPI.CommentItem] = []
    @State private var latestComments: [NeteaseAPI.CommentItem] = []
    @State private var sort: Sort = .hot
    @State private var isLoading = true
    @State private var error: String?
    @State private var retryToken = 0

    private var visibleComments: [NeteaseAPI.CommentItem] {
        let selected = sort == .hot ? hotComments : latestComments
        return selected.isEmpty ? latestComments : selected
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在加载评论")
                } else if let error {
                    VStack(spacing: 14) {
                        emptyState(title: "评论加载失败", detail: error, icon: "wifi.exclamationmark")
                        Button("重新加载") { retryToken += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                } else if visibleComments.isEmpty {
                    emptyState(title: "暂无评论", detail: nil, icon: "text.bubble")
                } else {
                    VStack(spacing: 0) {
                        Picker("评论排序", selection: $sort) {
                            ForEach(Sort.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.vertical, 10)

                        List(visibleComments) { comment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(comment.user?.nickname ?? "匿名用户")
                                        .font(.subheadline.weight(.medium))
                                    if let date = commentDate(comment.time) {
                                        Text(date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("赞 \(comment.likedCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(comment.content)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 4)
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task(id: "\(track.playbackKey)-\(retryToken)-\(sort.rawValue)") { await loadComments() }
        .refreshable { await loadComments() }
        .presentationDetents([.medium, .large])
    }

    private func loadComments() async {
        isLoading = true
        error = nil
        hotComments = []
        latestComments = []
        do {
            let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
            let neteaseID: Int?
            if let explicit = track.sourceMetadata["neteaseId"]
                ?? track.sourceMetadata["wyId"],
               let id = Int(explicit) {
                neteaseID = id
            } else if source.isEmpty || source == "wy" || source == "netease" || source == "163" {
                neteaseID = track.id
            } else {
                neteaseID = try await NeteaseAPI.matchingSong(
                    for: track, requireDuration: false
                )?.id
            }

            guard let neteaseID else { throw SongCommentsError.noMatchingSong }
            let response = try await NeteaseAPI.comments(
                for: neteaseID, order: sort == .hot ? .hot : .latest
            )
            hotComments = response.topComments + response.hotComments
            latestComments = response.comments
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func commentDate(_ milliseconds: Int64?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func emptyState(title: String, detail: String?, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private enum SongCommentsError: LocalizedError {
    case noMatchingSong

    var errorDescription: String? {
        "未找到对应的网易云歌曲，暂时无法显示评论"
    }
}
