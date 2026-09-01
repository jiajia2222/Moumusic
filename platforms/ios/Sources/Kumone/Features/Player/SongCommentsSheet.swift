import SwiftUI

/// Public song comments. This is deliberately read-only: no provider login
/// or account action is required to browse comments.
struct SongCommentsSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [NeteaseAPI.CommentItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var retryToken = 0

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在加载评论…")
                } else if let error {
                    VStack(spacing: 14) {
                        emptyState(title: "评论加载失败", detail: error, icon: "wifi.exclamationmark")
                        Button("重新加载") { retryToken += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                } else if comments.isEmpty {
                    emptyState(title: "暂无评论", detail: nil, icon: "text.bubble")
                } else {
                    List(comments) { comment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(comment.user?.nickname ?? "匿名用户")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("赞 \(comment.likedCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(comment.content)
                                .font(.body)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
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
        .task(id: "\(track.playbackKey)-\(retryToken)") { await loadComments() }
        .refreshable { await loadComments() }
        .presentationDetents([.medium, .large])
    }

    private func loadComments() async {
        isLoading = true
        error = nil
        comments = []
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
                // Comments are metadata, so allow a different edit length
                // while keeping the title/artist matching safeguards.
                neteaseID = try await NeteaseAPI.matchingSong(
                    for: track, requireDuration: false
                )?.id
            }

            guard let neteaseID else { throw SongCommentsError.noMatchingSong }
            comments = try await NeteaseAPI.comments(for: neteaseID).comments
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func emptyState(title: String, detail: String?, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
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
