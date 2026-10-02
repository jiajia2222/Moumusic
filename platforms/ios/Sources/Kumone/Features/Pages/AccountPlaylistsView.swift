#if os(iOS)
import SwiftUI

/// Playlists of the signed-in Kugou and QQ Music accounts.
struct AccountPlaylistsView: View {
    @EnvironmentObject private var qqMusic: QQMusicSessionStore
    @EnvironmentObject private var kugou: KugouSessionStore

    @State private var kugouLists: [KugouAPI.CloudPlaylist] = []
    @State private var qqLists: [QQMusicAPI.AccountPlaylist] = []
    @State private var isLoading = false
    @State private var kugouError: String?
    @State private var qqError: String?

    var body: some View {
        List {
            if !kugou.isLoggedIn && !qqMusic.isLoggedIn {
                Text("登录酷狗音乐或 QQ 音乐后，这里会显示你的歌单。")
                    .foregroundStyle(.secondary)
            }
            if kugou.isLoggedIn {
                Section {
                    if let kugouError, kugouLists.isEmpty {
                        Text(kugouError).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(kugouLists) { list in
                        NavigationLink {
                            AccountPlaylistTracksView(title: list.name) {
                                let rows = try await KugouAPI.shared.cloudPlaylistSongs(
                                    id: list.id, cookie: kugou.cookie ?? "")
                                return rows.compactMap { Self.kugouTrack($0) }
                            }
                        } label: {
                            row(name: list.name, count: list.count, cover: list.coverURL)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        BrandIconView(name: "BrandKugou").frame(width: 20, height: 20)
                        Text("酷狗音乐")
                    }
                }
            }
            if qqMusic.isLoggedIn {
                Section {
                    if let qqError, qqLists.isEmpty {
                        Text(qqError).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(qqLists) { list in
                        NavigationLink {
                            AccountPlaylistTracksView(title: list.name) {
                                try await LXCatalogService.playlistDetail(source: .tx, id: list.id).tracks
                            }
                        } label: {
                            row(name: list.name, count: list.count, cover: list.coverURL)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        BrandIconView(name: "BrandQQ").frame(width: 20, height: 20)
                        Text("QQ 音乐")
                    }
                }
            }
        }
        .navigationTitle("账号歌单")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && kugouLists.isEmpty && qqLists.isEmpty { ProgressView() }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(name: String, count: Int, cover: String?) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: cover?.resizedImageURL(160), animated: false) {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.semibold)).lineLimit(1)
                if count > 0 {
                    Text("\(count) 首").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if kugou.isLoggedIn, let cookie = await kugou.cookieWithDevice() {
            do {
                kugouLists = try await KugouAPI.shared.userPlaylists(cookie: cookie)
                kugouError = kugouLists.isEmpty ? "没有读取到歌单，详情见 设置 → 诊断日志" : nil
            } catch {
                kugouError = "酷狗歌单读取失败：\(error.localizedDescription)"
                DiagnosticLogStore.shared.append(level: .error, category: "Kugou", message: "云歌单读取失败", detail: "\(error)")
            }
        }
        if qqMusic.isLoggedIn, let cookie = qqMusic.cookie {
            do {
                qqLists = try await QQMusicAPI.shared.userPlaylists(cookie: cookie)
                qqError = qqLists.isEmpty ? "没有读取到歌单，详情见 设置 → 诊断日志" : nil
            } catch {
                qqError = "QQ 音乐歌单读取失败：\(error.localizedDescription)"
                DiagnosticLogStore.shared.append(level: .error, category: "QQ 音乐", message: "账号歌单读取失败", detail: "\(error)")
            }
        }
    }

    /// Cloud-playlist rows name the song "歌手 - 歌名"; split it for the shared track parser.
    static func kugouTrack(_ raw: [String: Any]) -> Track? {
        var item = raw
        if item["songname"] == nil, let full = (raw["name"] ?? raw["filename"]) as? String {
            let parts = full.components(separatedBy: " - ")
            if parts.count >= 2 {
                item["singername"] = item["singername"] ?? parts[0]
                item["songname"] = parts.dropFirst().joined(separator: " - ")
            } else {
                item["songname"] = full
            }
        }
        if item["timelength"] == nil, let seconds = raw["timelen"] as? Int { item["timelength"] = seconds }
        return LXCatalogService.parseTrack(item, source: .kg)
    }
}

struct AccountPlaylistTracksView: View {
    let title: String
    let load: () async throws -> [Track]

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            } else if let errorMessage, tracks.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                TrackListView(tracks: tracks)
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                tracks = try await load()
                if tracks.isEmpty { errorMessage = "这个歌单暂时读取不到歌曲" }
            } catch {
                errorMessage = "读取失败：\(error.localizedDescription)"
            }
            isLoading = false
        }
    }
}

/// "我的歌单" shelf shown at the top of a platform's own home page (Kugou / QQ Music).
struct PlatformAccountPlaylists: View {
    let platform: LXCatalogPlatform

    @EnvironmentObject private var qqMusic: QQMusicSessionStore
    @EnvironmentObject private var kugou: KugouSessionStore
    @State private var kugouLists: [KugouAPI.CloudPlaylist] = []
    @State private var qqLists: [QQMusicAPI.AccountPlaylist] = []

    private var isLoggedIn: Bool {
        (platform == .kg && kugou.isLoggedIn) || (platform == .tx && qqMusic.isLoggedIn)
    }

    var body: some View {
        Group {
            if isLoggedIn, !(kugouLists.isEmpty && qqLists.isEmpty) {
                Shelf(title: "我的歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    if platform == .kg {
                        ForEach(kugouLists) { list in
                            NavigationLink {
                                AccountPlaylistTracksView(title: list.name) {
                                    let rows = try await KugouAPI.shared.cloudPlaylistSongs(
                                        id: list.id, cookie: kugou.cookie ?? "")
                                    return rows.compactMap { AccountPlaylistsView.kugouTrack($0) }
                                }
                            } label: {
                                CoverCardBody(coverURL: list.coverURL?.resizedImageURL(384),
                                              title: list.name, subtitle: "\(list.count) 首")
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        ForEach(qqLists) { list in
                            NavigationLink {
                                AccountPlaylistTracksView(title: list.name) {
                                    try await LXCatalogService.playlistDetail(source: .tx, id: list.id).tracks
                                }
                            } label: {
                                CoverCardBody(coverURL: list.coverURL?.resizedImageURL(384),
                                              title: list.name, subtitle: "\(list.count) 首")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task(id: "\(platform.rawValue)-\(kugou.sessionRevision)-\(qqMusic.sessionRevision)") {
            if platform == .kg, kugou.isLoggedIn, let cookie = await kugou.cookieWithDevice() {
                kugouLists = (try? await KugouAPI.shared.userPlaylists(cookie: cookie)) ?? []
            } else if platform == .tx, qqMusic.isLoggedIn, let cookie = qqMusic.cookie {
                qqLists = (try? await QQMusicAPI.shared.userPlaylists(cookie: cookie)) ?? []
            }
        }
    }
}
#endif