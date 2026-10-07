import Foundation

/// Reads exported playlist files: LX Music (洛雪音乐) exports, which are the format aggregator apps use for lists that mix songs
/// of several platforms, Moumusic's own export, and (as the caller's fallback) any other JSON with a list of songs.
///
/// The file is parsed from its bytes (no text decoding, no link search: a playlist file is full of picture URLs, which the
/// link detection used to take for shared playlists), and every LX song is turned into the same `Track` shape the
/// catalogue search of its platform produces, so it plays through the same source and keeps the ids that source needs.
enum PlaylistFileParser {
    struct Result {
        var name: String
        var coverURL: String?
        var sourceName: String?
        var tracks: [Track]
    }

    /// Nil when the bytes are not JSON. An empty array means JSON that is not a format known here.
    static func parse(_ data: Data) -> [Result]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let own = ownExport(object, data: data) { return [own] }
        return parse(object)
    }

    static func parse(_ object: Any) -> [Result] {
        if let envelope = object as? [String: Any], let type = envelope["type"] as? String {
            let data = envelope["data"]
            switch type {
            case "playListPart", "playListPart_v2":
                if let list = data as? [String: Any], let result = lxList(list, fallbackName: "洛雪歌单") { return [result] }
            case "playList", "playList_v2":
                if let lists = data as? [[String: Any]] { return lists.compactMap { lxList($0, fallbackName: "洛雪歌单") } }
            case "allData", "allData_v2":
                guard let all = data as? [String: Any] else { break }
                var results: [Result] = []
                if let list = all["defaultList"] as? [String: Any], let r = lxList(list, fallbackName: "试听列表") { results.append(r) }
                if let list = all["loveList"] as? [String: Any], let r = lxList(list, fallbackName: "我的收藏") { results.append(r) }
                if let lists = all["userList"] as? [[String: Any]] { results += lists.compactMap { lxList($0, fallbackName: "洛雪歌单") } }
                return results
            default:
                break
            }
        }
        // A bare list of LX songs.
        if let songs = object as? [[String: Any]], songs.first.map(isLXSong) == true {
            let tracks = songs.compactMap(lxTrack)
            if !tracks.isEmpty { return [Result(name: "洛雪歌单", coverURL: nil, sourceName: "聚合", tracks: tracks)] }
        }
        return []
    }

    // MARK: Moumusic's own export

    /// The JSON `LocalPlaylistStore.exportText` writes: decoded as it is, so the songs keep every field (ids, platform, metadata).
    private static func ownExport(_ object: Any, data: Data) -> Result? {
        guard let root = object as? [String: Any], let tracks = root["tracks"] as? [[String: Any]],
              let first = tracks.first, first["durationMS"] != nil || first["sourceMetadata"] != nil else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let playlist = try? decoder.decode(LocalPlaylist.self, from: data), !playlist.tracks.isEmpty else { return nil }
        return Result(name: playlist.name, coverURL: playlist.coverURL, sourceName: playlist.sourceName, tracks: playlist.tracks)
    }

    // MARK: LX Music

    private static func lxList(_ list: [String: Any], fallbackName: String) -> Result? {
        let songs = (list["list"] as? [[String: Any]]) ?? []
        let tracks = songs.compactMap(lxTrack)
        guard !tracks.isEmpty else { return nil }
        let name = text(list["name"]) ?? fallbackName
        return Result(name: name, coverURL: tracks.first?.album.picUrl, sourceName: "聚合", tracks: tracks)
    }

    private static func isLXSong(_ item: [String: Any]) -> Bool {
        item["source"] is String && (item["singer"] != nil || item["meta"] != nil || item["interval"] != nil)
    }

    /// One LX song (current format with `meta`, or the older flat one) as the Track its platform's own search would give.
    private static func lxTrack(_ item: [String: Any]) -> Track? {
        guard let name = text(item["name"]), !name.isEmpty,
              let source = text(item["source"])?.lowercased() else { return nil }
        let meta = (item["meta"] as? [String: Any]) ?? [:]
        let id = text(item["id"]) ?? ""
        // "kw_12345": the platform prefix is LX's own, the song's id is what follows (or sits in `meta`).
        let bare = id.hasPrefix(source + "_") ? String(id.dropFirst(source.count + 1)) : id
        let songmid = text(item["songmid"]) ?? ""
        let singer = text(item["singer"]) ?? "未知歌手"
        let albumName = text(meta["albumName"]) ?? text(item["albumName"]) ?? ""
        let albumID = text(meta["albumId"]) ?? text(item["albumId"]) ?? ""
        let seconds = intervalSeconds(item["interval"])
        let cover = text(meta["picUrl"]) ?? text(item["img"]) ?? text(item["picUrl"])
        let songID = text(meta["songId"]) ?? ""

        let raw: [String: Any]
        let platform: LXCatalogPlatform
        switch source {
        case "kw":
            platform = .kw
            let rid = !songID.isEmpty ? songID : (!songmid.isEmpty ? songmid : bare)
            raw = ["id": rid, "name": name, "artist": singer, "album": albumName, "albumid": Int(albumID) ?? 0, "duration": seconds]
        case "kg":
            platform = .kg
            let hash = text(meta["hash"]) ?? text(item["hash"]) ?? (bare.count == 32 ? bare : songmid)
            raw = ["hash": hash, "audio_id": !songID.isEmpty ? songID : hash, "songname": name, "singername": singer,
                   "album_name": albumName, "album_id": Int(albumID) ?? 0, "timelength": seconds]
        case "tx":
            platform = .tx
            let mid = !bare.isEmpty && Int(bare) == nil ? bare : (!songmid.isEmpty ? songmid : bare)
            var row: [String: Any] = ["mid": mid, "name": name, "singer": singer, "interval": seconds,
                                      "album": ["mid": albumID, "name": albumName] as [String: Any]]
            if !songID.isEmpty { row["id"] = songID }
            if let media = text(meta["strMediaMid"]) { row["media_mid"] = media }
            raw = row
        case "mg":
            platform = .mg
            let copyright = !songmid.isEmpty ? songmid : bare
            var row: [String: Any] = ["songId": !songID.isEmpty ? songID : copyright, "copyrightId": copyright, "songName": name,
                                      "singerName": singer, "albumName": albumName, "duration": seconds]
            for key in ["lrcUrl", "mrcUrl", "trcUrl"] { if let v = text(meta[key]) { row[key] = v } }
            raw = row
        case "wy":
            // A NetEase song is a plain numeric id with the "wy" platform, like the lists imported from a NetEase link.
            guard let neteaseID = Int(!songID.isEmpty ? songID : (!bare.isEmpty ? bare : songmid)), neteaseID > 0 else { return nil }
            return Track(id: neteaseID, name: name, artists: artists(singer),
                         album: AlbumRef(id: Int(albumID) ?? 0, name: albumName, picUrl: cover),
                         durationMS: seconds * 1000, source: "wy", sourceMetadata: ["id": String(neteaseID)])
        default:
            return nil   // 本地歌曲 and platforms this app has no source for
        }
        guard let parsed = LXCatalogService.parseTrack(raw, source: platform) else { return nil }
        guard let cover, !cover.isEmpty, parsed.album.picUrl == nil else { return parsed }
        var metadata = parsed.sourceMetadata
        if metadata["coverURL"] == nil { metadata["coverURL"] = cover }
        return Track(id: parsed.id, name: parsed.name, artists: parsed.artists,
                     album: AlbumRef(id: parsed.album.id, name: parsed.album.name, picUrl: cover),
                     durationMS: parsed.durationMS, source: parsed.source, sourceMetadata: metadata)
    }

    // MARK: Values

    private static func artists(_ text: String) -> [ArtistRef] {
        text.split(whereSeparator: { "、/&,".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated().map { ArtistRef(id: $0.offset, name: $0.element) }
    }

    /// LX writes the length as "04:17" (or "1:02:03"); a plain number is already seconds.
    private static func intervalSeconds(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        guard let string = value as? String, !string.isEmpty else { return 0 }
        if string.contains(":") {
            return string.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
        }
        return Int(Double(string) ?? 0)
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
