import SwiftUI
import UniformTypeIdentifiers

/// 导入歌单到本地音乐库：网易云歌单链接、歌单 JSON、或「歌名 - 歌手」文本列表。
/// 歌单只保存到本机，不会修改原音乐软件。
struct PlaylistImportSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var working = false
    @State private var progressText = ""
    @State private var errorText: String?
    @State private var showFileImporter = false

    private struct Entry { let name: String; let artist: String }

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("粘贴或导入歌单").font(BeansFont.appFont(17, .bold)).foregroundStyle(Color.beansLabel)
                                Text("粘贴网易云歌单链接，或粘贴其他平台导出的歌单 JSON，也可以每行写一首「歌名 - 歌手」。歌单只保存到本机，不会修改原音乐软件。")
                                    .font(BeansFont.appFont(12)).foregroundStyle(Color.beansComment)
                                ZStack(alignment: .topLeading) {
                                    if input.isEmpty {
                                        Text("请输入歌单链接或歌单 JSON 文件内容")
                                            .font(BeansFont.appFont(13)).foregroundStyle(Color.beansComment)
                                            .padding(.top, 8).padding(.leading, 5)
                                    }
                                    TextEditor(text: $input)
                                        .font(BeansFont.appFont(13))
                                        .frame(minHeight: 150)
                                        .beansScrollContentBackgroundHidden()
                                        .autocapitalization(.none)
                                        .disableAutocorrection(true)
                                }
                            }
                        }
                        if let errorText {
                            Text(errorText).font(BeansFont.appFont(13)).foregroundStyle(Color.red)
                        }
                        if working {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(progressText).font(BeansFont.appFont(12)).foregroundStyle(Color.beansComment)
                            }
                        }
                        HStack(spacing: 10) {
                            GlassButton(title: "选择 JSON / 文本文件", systemName: "doc") { showFileImporter = true }
                            GlassButton(title: working ? "正在导入…" : "导入", systemName: "square.and.arrow.down", prominent: true) {
                                Task { await runImport() }
                            }
                            .disabled(working)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("导入歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json, .plainText, .text], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                    input = text
                    errorText = nil
                } else {
                    errorText = "读取文件失败：无法读取文件内容"
                }
            case .failure(let error):
                errorText = "读取文件失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 导入

    @MainActor
    private func runImport() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { errorText = "请输入歌单链接或歌单 JSON 文件内容"; return }
        working = true
        errorText = nil
        defer { working = false }

        var name = "导入歌单"
        var songs: [Song] = []
        do {
            if let id = Self.neteasePlaylistID(in: text) {
                progressText = "正在读取网易云歌单…"
                songs = try await NetEaseAPI.shared.playlistTracks(id: id)
                name = "网易云歌单 \(id)"
            } else {
                let parsed: (title: String?, entries: [Entry])
                if text.hasPrefix("{") || text.hasPrefix("[") {
                    guard let result = Self.parseJSON(text) else { errorText = "无法识别歌单格式"; return }
                    parsed = result
                } else {
                    parsed = (nil, Self.parseLines(text))
                }
                if let title = parsed.title, !title.isEmpty { name = title }
                guard !parsed.entries.isEmpty else { errorText = "歌单中没有可导入的歌曲"; return }
                songs = await match(parsed.entries)
            }
        } catch {
            errorText = "读取歌单失败：\(error.localizedDescription)"
            return
        }

        guard !songs.isEmpty else { errorText = "歌单中没有可导入的歌曲"; return }
        let playlist = LocalLibraryStore.shared.createPlaylist(name: name)
        let added = LocalLibraryStore.shared.addSongs(songs, to: playlist.id)
        ToastCenter.shared.show("歌单已导入到本地音乐库")
        BeansLogger.shared.log("导入歌单：\(name) 歌曲 \(added) 首", level: .info)
        dismiss()
    }

    /// 没有平台 id 的条目：按「歌名 歌手」到网易云搜索并取最接近的一首。
    private func match(_ entries: [Entry]) async -> [Song] {
        var result: [Song] = []
        for (index, entry) in entries.enumerated() {
            progressText = "正在匹配歌曲 \(index + 1)/\(entries.count)：\(entry.name)"
            let keyword = [entry.name, entry.artist].filter { !$0.isEmpty }.joined(separator: " ")
            guard let candidates = try? await NetEaseAPI.shared.search(keyword: keyword, limit: 6), !candidates.isEmpty else { continue }
            let wanted = entry.name.lowercased()
            let best = candidates.first { $0.name.lowercased() == wanted }
                ?? candidates.first { $0.name.lowercased().contains(wanted) || wanted.contains($0.name.lowercased()) }
                ?? candidates.first
            if let best { result.append(best) }
        }
        return result
    }

    private static func neteasePlaylistID(in text: String) -> Int? {
        guard text.contains("163.com") || text.contains("music.163") || text.contains("y.music") else { return nil }
        let patterns = [#"playlist\?id=(\d+)"#, #"playlist/(\d+)"#, #"[?&]id=(\d+)"#]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(m.range(at: 1), in: text), let id = Int(text[range]) { return id }
        }
        return nil
    }

    private static func parseLines(_ text: String) -> [Entry] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            for separator in [" - ", " – ", " — ", "-", "／", "/"] {
                if let r = line.range(of: separator) {
                    let name = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let artist = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { return Entry(name: name, artist: artist) }
                }
            }
            return Entry(name: line, artist: "")
        }
    }

    private static func parseJSON(_ text: String) -> (title: String?, entries: [Entry])? {
        guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var title: String?
        var array: [Any] = []
        if let list = root as? [Any] {
            array = list
        } else if let dict = root as? [String: Any] {
            title = dict["name"] as? String ?? dict["title"] as? String
            if let playlist = dict["playlist"] as? [String: Any] {
                title = title ?? playlist["name"] as? String
                array = playlist["tracks"] as? [Any] ?? []
            }
            if array.isEmpty {
                for key in ["songs", "tracks", "list", "musicList", "data"] {
                    if let list = dict[key] as? [Any] { array = list; break }
                }
            }
        }
        let entries: [Entry] = array.compactMap { item in
            guard let d = item as? [String: Any] else { return nil }
            let name = (d["name"] ?? d["title"] ?? d["songName"] ?? d["songname"]) as? String ?? ""
            guard !name.isEmpty else { return nil }
            var artist = ""
            if let s = (d["artist"] ?? d["singer"]) as? String { artist = s }
            else if let list = (d["artists"] ?? d["ar"] ?? d["singers"]) as? [Any] {
                artist = list.compactMap { ($0 as? [String: Any])?["name"] as? String ?? $0 as? String }.joined(separator: " ")
            }
            return Entry(name: name, artist: artist)
        }
        return (title, entries)
    }
}
