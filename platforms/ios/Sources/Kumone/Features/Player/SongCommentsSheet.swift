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
    @State private var hotComments: [DisplayComment] = []
    @State private var latestComments: [DisplayComment] = []
    @State private var sort: Sort = .hot
    @State private var isLoading = true
    @State private var error: String?
    @State private var retryToken = 0
    @State private var metadataNotice: String?

    private var visibleComments: [DisplayComment] {
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

                        if let metadataNotice {
                            Text(metadataNotice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }

                        List(visibleComments) { comment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(comment.author ?? "匿名用户")
                                        .font(.subheadline.weight(.medium))
                                    if let date = commentDate(comment.date) {
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
        metadataNotice = nil
        do {
            let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
            let sourceIsNetease = source.isEmpty || source == "wy" || source == "netease" || source == "163"
            if !sourceIsNetease {
                metadataNotice = "当前歌曲来自 \(LXCatalogPlatform(rawValue: source)?.displayName ?? source)；优先显示该平台公开评论。"
                if let response = try? await LXCommentsService.comments(for: track) {
                    hotComments = uniqueComments(response.hot.map(DisplayComment.init))
                    latestComments = uniqueComments(response.latest.map(DisplayComment.init))
                    isLoading = false
                    return
                }
                metadataNotice = "当前歌曲来自 \(LXCatalogPlatform(rawValue: source)?.displayName ?? source)；该平台评论暂不可用，正在尝试公开元数据匹配。"
            }

            let neteaseID: Int?
            if let explicit = track.sourceMetadata["neteaseId"]
                ?? track.sourceMetadata["wyId"],
                let id = Int(explicit) {
                neteaseID = id
            } else if sourceIsNetease {
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
            hotComments = uniqueComments((response.topComments + response.hotComments).map(DisplayComment.init))
            latestComments = uniqueComments(response.comments.map(DisplayComment.init))
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func uniqueComments(_ comments: [DisplayComment]) -> [DisplayComment] {
        var seen = Set<String>()
        return comments.filter { seen.insert($0.id).inserted }
    }

    private func commentDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return Self.dateFormatter.string(from: date)
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

private struct DisplayComment: Identifiable, Hashable {
    let id: String
    let content: String
    let author: String?
    let likedCount: Int
    let date: Date?

    init(_ comment: LXComment) {
        id = comment.id
        content = comment.content
        author = comment.author
        likedCount = comment.likedCount
        date = comment.date
    }

    init(_ comment: NeteaseAPI.CommentItem) {
        id = String(comment.id)
        content = comment.content
        author = comment.user?.nickname
        likedCount = comment.likedCount
        if let time = comment.time, time > 0 {
            date = Date(timeIntervalSince1970: TimeInterval(time) / 1000)
        } else {
            date = nil
        }
    }
}

private enum SongCommentsError: LocalizedError {
    case noMatchingSong

    var errorDescription: String? {
        "暂未找到公开评论对应的歌曲，请稍后重试"
    }
}
