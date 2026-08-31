import SwiftUI

/// Public song comments. This is deliberately read-only: no provider login
/// or account action is required to browse comments.
struct SongCommentsSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [NeteaseAPI.CommentItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在加载评论…")
                } else if let error {
                    emptyState(title: "评论加载失败", detail: error, icon: "wifi.exclamationmark")
                } else if comments.isEmpty {
                    emptyState(title: "暂无评论", detail: nil, icon: "text.bubble")
                } else {
                    List(comments) { comment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(comment.user?.nickname ?? "匿名用户")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("赞 (comment.likedCount)")
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
        .task(id: track.id) {
            do {
                comments = try await NeteaseAPI.comments(for: track.id).comments
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
        .presentationDetents([.medium, .large])
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
