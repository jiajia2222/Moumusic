import SwiftUI

/// Song comments are always read from NetEase. A non-NetEase track is matched
/// to its NetEase metadata record before comments are loaded or posted.
struct SongCommentsSheet: View {
    private enum Sort: String, CaseIterable, Identifiable {
        case hot
        case latest

        var id: String { rawValue }
        var title: String { self == .hot ? "热门评论" : "最新评论" }
    }

    let track: Track
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openLogin) private var openLogin
    @State private var hotComments: [DisplayComment] = []
    @State private var latestComments: [DisplayComment] = []
    @State private var sort: Sort = .hot
    @State private var isLoading = true
    @State private var error: String?
    @State private var retryToken = 0
    @State private var metadataNotice: String?
    @State private var neteaseSongID: Int?
    @State private var draft = ""
    @State private var canPost = false
    @State private var isPosting = false
    @State private var postStatus: String?
    @State private var postStatusIsError = false

    private var visibleComments: [DisplayComment] {
        let selected = sort == .hot ? hotComments : latestComments
        if !selected.isEmpty { return selected }
        return sort == .hot ? latestComments : hotComments
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            commentComposer
        }
        .presentationDetents([.medium, .large])
    }

    private var commentComposer: some View {
        VStack(spacing: 6) {
            if let postStatus {
                Text(postStatus)
                    .font(.caption)
                    .foregroundStyle(postStatusIsError ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if canPost {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("发表评论（网易云）", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        Task { await postComment() }
                    } label: {
                        if isPosting {
                            ProgressView()
                                .frame(width: 44, height: 44)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .frame(width: 44, height: 44)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPosting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("发表评论")
                }
            } else {
                Button {
                    openLogin()
                } label: {
                    Label("登录网易云后发表评论", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func loadComments() async {
        isLoading = true
        error = nil
        hotComments = []
        latestComments = []
        metadataNotice = nil
        postStatus = nil
        canPost = NeteaseClient.shared.isLoggedIn

        do {
            let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
            let sourceIsNetease = source.isEmpty || source == "wy" || source == "netease" || source == "163"
            let neteaseID = try await resolveNeteaseSongID(sourceIsNetease: sourceIsNetease)
            neteaseSongID = neteaseID

            let response = try await NeteaseAPI.comments(
                for: neteaseID,
                order: sort == .hot ? .hot : .latest
            )
            hotComments = uniqueComments((response.topComments + response.hotComments).map(DisplayComment.init))
            latestComments = uniqueComments(response.comments.map(DisplayComment.init))
            if !sourceIsNetease {
                metadataNotice = "当前歌曲来自 \(LXCatalogPlatform.displayName(for: source))；评论和发表评论均使用网易云。"
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func resolveNeteaseSongID(sourceIsNetease: Bool) async throws -> Int {
        if let explicit = track.sourceMetadata["neteaseId"] ?? track.sourceMetadata["wyId"],
           let id = Int(explicit) {
            return id
        }
        if sourceIsNetease { return track.id }
        guard let match = try await NeteaseAPI.matchingSong(for: track, requireDuration: false) else {
            throw SongCommentsError.noMatchingSong
        }
        return match.id
    }

    private func postComment() async {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        guard let neteaseSongID else {
            postStatus = "当前歌曲未匹配到网易云，暂时无法发表评论。"
            postStatusIsError = true
            return
        }

        isPosting = true
        postStatus = nil
        defer { isPosting = false }

        do {
            try await NeteaseAPI.addComment(songID: neteaseSongID, content: content)
            draft = ""
            await loadComments()
            postStatus = "评论已发送到网易云。"
            postStatusIsError = false
        } catch is CancellationError {
            return
        } catch {
            postStatus = error.localizedDescription
            postStatusIsError = true
            canPost = NeteaseClient.shared.isLoggedIn
        }
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
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
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
        "暂未找到对应的网易云歌曲，无法读取或发表评论。"
    }
}
