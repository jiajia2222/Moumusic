#if os(iOS)
import SwiftUI

/// 听歌排行: the NetEase account's own play counts (`/v1/play/record`, as in NeteaseCloudMusicApi's
/// user_record). Both ranges come from the server, so "所有时间" is real account data.
struct ListeningRankView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerService
    @Environment(\.openLogin) private var openLogin

    @State private var week = true
    @State private var records: [PlayRecordItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("范围", selection: $week) {
                    Text("最近一周").tag(true)
                    Text("所有时间").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Layout.contentInset)

                if !account.isLoggedIn {
                    EmptyStateView(icon: "chart.bar", title: "登录网易云查看听歌排行", subtitle: "排行来自网易云账号的真实播放记录")
                        .frame(maxWidth: .infinity, minHeight: 260)
                    Button("登录网易云") { openLogin() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                } else if isLoading && records.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 260)
                } else if let errorMessage, records.isEmpty {
                    ErrorStateView(message: errorMessage) { Task { await load() } }
                        .frame(minHeight: 260)
                } else if records.isEmpty {
                    EmptyStateView(icon: "chart.bar", title: "暂无排行", subtitle: "多听几首歌再来看看")
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(records.enumerated()), id: \.offset) { index, item in
                            Button {
                                player.play(tracks: records.map { $0.song.normalizedForLXPlayback() }, source: .none,
                                            startAt: item.song.normalizedForLXPlayback())
                            } label: {
                                row(index: index, item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                }
                PlayerClearanceSpacer()
            }
            .padding(.top, 12)
        }
        .navigationTitle("听歌排行")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(week)-\(account.isLoggedIn)") { await load() }
        .refreshable { await load() }
    }

    private func row(index: Int, item: PlayRecordItem) -> some View {
        let maxScore = max(records.first?.score ?? 1, 1)
        return HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(index < 3 ? Theme.accent : .secondary)
                .frame(width: 30)
            CachedAsyncImage(url: item.song.album.picUrl?.resizedImageURL(120), animated: false)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.song.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(item.song.artistNames).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                GeometryReader { proxy in
                    Capsule().fill(Theme.accent.opacity(0.25))
                        .frame(width: proxy.size.width * CGFloat(item.score) / CGFloat(maxScore), height: 3)
                }
                .frame(height: 3)
            }
            Spacer(minLength: 0)
            if item.playCount > 0 {
                Text("\(item.playCount) 次").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @MainActor private func load() async {
        guard account.isLoggedIn, let uid = account.profile?.userId else { records = []; return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            records = try await NeteaseAPI.playRecords(uid: uid, week: week)
        } catch {
            errorMessage = "排行暂时无法读取，请稍后重试"
        }
    }
}
#endif
