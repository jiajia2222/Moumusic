import Foundation
import UIKit

enum LyricBackgroundStore {
    static let pathKey = "beans.lyricBackground.image"
    static let dataKey = "beans.lyricBackground.data"
    static let blurKey = "beans.lyricBackground.blur"

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeansLyricBackground", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func save(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let imageData = normalizedJPEG(from: data) ?? data
        let url = directory.appendingPathComponent("lyric-background.jpg")
        do {
            BeansImageFileCache.remove(url.path)
            try imageData.write(to: url, options: .atomic)
            UserDefaults.standard.set(url.path, forKey: pathKey)
            UserDefaults.standard.set(imageData.base64EncodedString(), forKey: dataKey)
            return url.path
        } catch {
            return nil
        }
    }

    static func clear() {
        if let path = UserDefaults.standard.string(forKey: pathKey), !path.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            BeansImageFileCache.remove(path)
        }
        UserDefaults.standard.removeObject(forKey: pathKey)
        UserDefaults.standard.removeObject(forKey: dataKey)
    }

    static func refreshForExport() {
        guard let path = UserDefaults.standard.string(forKey: pathKey), !path.isEmpty,
              FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        UserDefaults.standard.set(data.base64EncodedString(), forKey: dataKey)
    }

    @discardableResult
    static func restoreFromBackup() -> String? {
        guard let b64 = UserDefaults.standard.string(forKey: dataKey),
              let data = Data(base64Encoded: b64) else { return nil }
        let savedPath = UserDefaults.standard.string(forKey: pathKey) ?? ""
        if !savedPath.isEmpty, FileManager.default.fileExists(atPath: savedPath) {
            return savedPath
        }
        let url = directory.appendingPathComponent("lyric-background.jpg")
        BeansImageFileCache.remove(url.path)
        if (try? data.write(to: url, options: .atomic)) != nil {
            UserDefaults.standard.set(url.path, forKey: pathKey)
            return url.path
        }
        return nil
    }

    private static func normalizedJPEG(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return nil }
        let longest = max(width, height)
        let target: CGFloat = 1600
        let scale = longest > target ? target / longest : 1
        let size = CGSize(width: width * scale, height: height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.86)
    }
}
