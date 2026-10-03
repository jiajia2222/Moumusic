import SwiftUI

/// One private-message conversation (read-only history; replying stays in the Bilibili app).
struct BilibiliChatView: View {
    let thread: BilibiliAPI.PrivateMessageThread
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [BilibiliAPI.ChatMessage] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    } else if let errorMessage, messages.isEmpty {
                        ErrorStateView(message: errorMessage) { Task { await load() } }
                            .frame(minHeight: 240)
                    } else if messages.isEmpty {
                        EmptyStateView(icon: "bubble.left.and.bubble.right", title: "没有可显示的消息")
                            .frame(minHeight: 240)
                    }
                    ForEach(messages) { message in
                        bubble(message).id(message.id)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.vertical, 12)
            }
            .onChange(of: messages) { _ in
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .navigationTitle(thread.userName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .task { await load() }
    }

    private func bubble(_ message: BilibiliAPI.ChatMessage) -> some View {
        let mine = message.senderID != thread.userID
        return VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            Text(message.text)
                .font(.subheadline)
                .foregroundStyle(mine ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.thinMaterial),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .textSelection(.enabled)
            if let date = message.date {
                Text(Self.formatter.string(from: date)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            messages = try await BilibiliAPI.shared.conversation(talker: thread.userID, cookie: bilibili.cookie)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct BilibiliNoticeRow: View {
    let notice: BilibiliAPI.FeedNotice

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CachedAsyncImage(url: notice.avatarURL?.resizedImageURL(96), animated: false)
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.userName).font(.subheadline.weight(.semibold))
                Text(notice.action).font(.caption).foregroundStyle(.secondary)
                if !notice.content.isEmpty {
                    Text(notice.content).font(.footnote).lineLimit(4)
                }
                if let date = notice.date {
                    Text(Self.formatter.string(from: date)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mouMaterialBackground(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
