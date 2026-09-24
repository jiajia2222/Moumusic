import SwiftUI

struct DailySongsView: View {
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openLogin) private var openLogin

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if account.isLoggedIn {
                    header
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, 16)
                }

                if !account.isLoggedIn {
                    loginState
                        .frame(minHeight: 300)
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                    .frame(minHeight: 300)
                } else if tracks.isEmpty {
                    EmptyStateView(icon: "calendar.badge.clock", title: "暂无每日推荐",
                                   subtitle: "多听几首歌培养口味，每天 6:00 更新")
                        .frame(minHeight: 300)
                } else {
                    TrackListView(tracks: tracks, source: .daily, context: .daily)
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("每日推荐")
        .task(id: account.isLoggedIn) {
            if tracks.isEmpty {
                await load()
            }
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(url: tracks.first?.album.picUrl?.resizedImageURL(1024))
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 26, weight: .medium))
                        Text(dateString)
                            .font(.system(size: 14, weight: .medium))
                            .opacity(0.85)
                    }
                    Text("每日推荐")
                        .font(.system(size: 30, weight: .bold))
                    Text("根据你的音乐口味 · 每天 6:00 更新")
                        .font(.system(size: 12))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)

                Spacer()

                Button {
                    player.play(tracks: tracks, source: .daily, context: .daily)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Theme.accentGradient, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    }

    private var loginState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("登录后查看每日推荐")
                .font(.title3.weight(.semibold))
            Text("登录只用于同步推荐和听歌记录，播放仍然使用已导入的 LX 音源。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("去登录") { openLogin() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity)
    }

    private var dateString: String {
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return fmt.string(from: .now)
    }

    private func load() async {
        guard account.isLoggedIn else {
            isLoading = false
            errorMessage = String(localized: "登录后才能查看每日推荐")
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            // Daily recommendations come from NetEase's account API, but
            // playback must still use the selected LX source. Mark every
            // track with the same normalized source metadata as the home
            // NetEase feed so the row, quality picker, lyrics fallback and
            // player all see one consistent Track shape.
            tracks = try await NeteaseAPI.dailyRecommendSongs()
                .map { $0.normalizedForLXPlayback() }
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}
