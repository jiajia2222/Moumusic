import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The portable part of Moumusic's library.  Provider cookies and account
/// credentials are intentionally not part of this document: they remain in
/// the Keychain and never enter an exported file or iCloud KVS.
private struct MoumusicBackupPayload: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let settingsPlist: Data
    let favoriteTracks: [Track]
    let favoriteCollections: [FavoriteCollection]
    let localPlaylists: [LocalPlaylist]
}

/// JSON document used by the system Files importer/exporter.
struct MoumusicBackupFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    static let writableContentTypes: [UTType] = [.json]

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Coordinates explicit JSON export/import with an optional iCloud KVS copy.
/// KVS is used instead of an iCloud document container so the feature remains
/// usable for a locally signed build; the app still enforces the small KVS
/// payload limit and always keeps Files export as the lossless fallback.
@MainActor
final class AppDataBackupManager: ObservableObject {
    static let shared = AppDataBackupManager()

    @Published var automaticICloudBackup: Bool {
        didSet {
            UserDefaults.standard.set(automaticICloudBackup, forKey: Self.automaticKey)
            if automaticICloudBackup {
                scheduleAutomaticBackup()
            } else {
                backupTask?.cancel()
                statusMessage = "iCloud 自动备份已关闭"
            }
        }
    }
    @Published private(set) var lastBackupDate: Date?
    @Published private(set) var isICloudAvailable = false
    @Published private(set) var statusMessage = ""

    private static let automaticKey = "moumusic.backup.automaticICloud"
    private static let lastBackupKey = "moumusic.backup.lastICloudDate"
    private static let iCloudKey = "moumusic.backup.payload.v1"
    private static let currentSchema = 1
    private static let maxKVSBytes = 900_000

    private var backupTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private var isWritingBackup = false
    private var suppressNextDefaultsNotification = false

    private init() {
        automaticICloudBackup = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
        lastBackupDate = UserDefaults.standard.object(forKey: Self.lastBackupKey) as? Date

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.suppressNextDefaultsNotification {
                self.suppressNextDefaultsNotification = false
                return
            }
            guard !self.isWritingBackup else { return }
            self.scheduleAutomaticBackup()
        }

        NSUbiquitousKeyValueStore.default.synchronize()
        refreshAvailability()
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        backupTask?.cancel()
    }

    func startAutomaticBackup() {
        refreshAvailability()
        guard automaticICloudBackup else { return }
        // On a new device, restore first.  Otherwise the first scheduled
        // write could replace an existing cloud snapshot with an empty local
        // library before the user has had a chance to open Settings.
        if isICloudAvailable, !hasLocalLibraryData, restoreFromICloud() {
            return
        }
        scheduleAutomaticBackup()
    }

    func refreshAvailability() {
        isICloudAvailable = FileManager.default.ubiquityIdentityToken != nil
        if !isICloudAvailable, automaticICloudBackup {
            statusMessage = "iCloud 不可用；可继续使用文件导出"
        }
    }

    func setStatusMessage(_ message: String) {
        statusMessage = message
    }

    func prepareExportDocument() -> MoumusicBackupFileDocument? {
        do {
            return MoumusicBackupFileDocument(data: try makeBackupData())
        } catch {
            statusMessage = "备份导出失败：\(error.localizedDescription)"
            return nil
        }
    }

    func importBackup(data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(MoumusicBackupPayload.self, from: data)
        guard payload.schemaVersion <= Self.currentSchema else {
            throw BackupError.unsupportedVersion
        }

        restoreSettings(from: payload.settingsPlist)
        SettingsManager.shared.reloadFromDefaults()
        FavoritesStore.shared.replaceTracks(payload.favoriteTracks)
        FavoritesStore.shared.replaceCollections(payload.favoriteCollections)
        LocalPlaylistStore.shared.replacePlaylists(payload.localPlaylists)
        statusMessage = "已恢复收藏、歌单和应用设置"
        NotificationCenter.default.post(name: .moumusicBackupDidRestore, object: nil)
    }

    @discardableResult
    func restoreFromICloud() -> Bool {
        refreshAvailability()
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: Self.iCloudKey) else {
            statusMessage = "iCloud 中暂无 Moumusic 备份"
            return false
        }

        do {
            try importBackup(data: data)
            statusMessage = "已从 iCloud 恢复数据"
            return true
        } catch {
            statusMessage = "iCloud 备份无法读取：\(error.localizedDescription)"
            return false
        }
    }

    func scheduleAutomaticBackup() {
        guard automaticICloudBackup else { return }
        backupTask?.cancel()
        backupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled, let self else { return }
            self.performICloudBackup()
        }
    }

    private func performICloudBackup() {
        refreshAvailability()
        guard automaticICloudBackup, isICloudAvailable else { return }

        do {
            let data = try makeBackupData()
            guard data.count <= Self.maxKVSBytes else {
                statusMessage = "备份超过 iCloud 快速同步容量，请使用文件导出"
                return
            }

            isWritingBackup = true
            NSUbiquitousKeyValueStore.default.set(data, forKey: Self.iCloudKey)
            NSUbiquitousKeyValueStore.default.synchronize()
            let now = Date()
            lastBackupDate = now
            suppressNextDefaultsNotification = true
            UserDefaults.standard.set(now, forKey: Self.lastBackupKey)
            isWritingBackup = false
            statusMessage = "已自动备份到 iCloud"
        } catch {
            isWritingBackup = false
            statusMessage = "iCloud 自动备份失败：\(error.localizedDescription)"
        }
    }

    private var hasLocalLibraryData: Bool {
        !FavoritesStore.shared.tracks.isEmpty
            || !FavoritesStore.shared.items.isEmpty
            || !LocalPlaylistStore.shared.playlists.isEmpty
    }

    private func makeBackupData() throws -> Data {
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        let portableSettings = defaults.filter {
            !Self.isSensitiveKey($0.key) && !Self.isBackupInternalKey($0.key)
        }
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: portableSettings,
            format: .binary,
            options: 0
        )

        let payload = MoumusicBackupPayload(
            schemaVersion: Self.currentSchema,
            exportedAt: Date(),
            settingsPlist: plistData,
            favoriteTracks: FavoritesStore.shared.tracks,
            favoriteCollections: FavoritesStore.shared.items,
            localPlaylists: LocalPlaylistStore.shared.playlists
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    private func restoreSettings(from data: Data) {
        guard !data.isEmpty else { return }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let values = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else { return }

        for (key, value) in values
            where !Self.isSensitiveKey(key) && !Self.isBackupInternalKey(key) {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowercased = key.lowercased()
        return ["cookie", "token", "password", "credential", "secret", "session", "p12"]
            .contains { lowercased.contains($0) }
    }

    /// These values are either duplicated in the typed payload or are local
    /// caches that do not belong in iCloud KVS. In particular, the wallpaper
    /// fallback can be hundreds of KB of Base64 and would make a valid backup
    /// exceed the KVS limit even though the actual library is small.
    private static func isBackupInternalKey(_ key: String) -> Bool {
        switch key {
        case "moumusic.favoriteCollections.v1",
             "moumusic.favoriteTracks.v1",
             "moumusic.localPlaylists.v1",
             "moumusic.backup.automaticICloud",
             "moumusic.backup.lastICloudDate",
             "moumusic.backup.payload.v1",
             "moumusic.background.data.v1",
             "moumusic.background.path.v1":
            return true
        default:
            return false
        }
    }

    enum BackupError: LocalizedError {
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: return "备份来自更新版本，当前版本无法恢复"
            }
        }
    }
}

extension Notification.Name {
    static let moumusicBackupDidRestore = Notification.Name("moumusic.backup.didRestore")
}
