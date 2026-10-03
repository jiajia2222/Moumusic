#if os(iOS)
import PhotosUI
import SwiftUI
import UIKit

/// Custom avatar and card background for the profile card on the 我的 page.
@MainActor
final class ProfileAppearanceStore: ObservableObject {
    static let shared = ProfileAppearanceStore()

    @Published private(set) var avatar: UIImage?
    @Published private(set) var background: UIImage?
    /// Album picture for the Moumusic ID card, with the framing the user chose.
    @Published private(set) var cardBackground: UIImage?
    @Published var cardZoom: Double = UserDefaults.standard.object(forKey: "moumusic.profile.card.zoom") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(cardZoom, forKey: "moumusic.profile.card.zoom") }
    }
    @Published var cardOffsetX: Double = UserDefaults.standard.object(forKey: "moumusic.profile.card.x") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(cardOffsetX, forKey: "moumusic.profile.card.x") }
    }
    @Published var cardOffsetY: Double = UserDefaults.standard.object(forKey: "moumusic.profile.card.y") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(cardOffsetY, forKey: "moumusic.profile.card.y") }
    }
    @Published var nickname: String = UserDefaults.standard.string(forKey: "moumusic.profile.nickname") ?? "" {
        didSet { UserDefaults.standard.set(nickname.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "moumusic.profile.nickname") }
    }

    private init() {
        avatar = UIImage(contentsOfFile: Self.url("avatar").path)
        background = UIImage(contentsOfFile: Self.url("background").path)
        cardBackground = UIImage(contentsOfFile: Self.url("card").path)
    }

    func setCardBackground(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        try? rendered.jpegData(compressionQuality: 0.88)?.write(to: Self.url("card"), options: .atomic)
        cardBackground = rendered
        cardZoom = 1
        cardOffsetX = 0
        cardOffsetY = 0
    }

    func resetCardBackground() {
        try? FileManager.default.removeItem(at: Self.url("card"))
        cardBackground = nil
    }

    private static func url(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moumusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("profile-\(name).jpg")
    }

    func setAvatar(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        let side = min(image.size.width, image.size.height)
        let crop = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        let target = CGSize(width: 512, height: 512)
        let rendered = UIGraphicsImageRenderer(size: target).image { _ in
            let scale = target.width / side
            image.draw(in: CGRect(x: -crop.origin.x * scale, y: -crop.origin.y * scale,
                                  width: image.size.width * scale, height: image.size.height * scale))
        }
        try? rendered.jpegData(compressionQuality: 0.9)?.write(to: Self.url("avatar"), options: .atomic)
        avatar = rendered
    }

    func setBackground(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        let maxSide: CGFloat = 1400
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        try? rendered.jpegData(compressionQuality: 0.85)?.write(to: Self.url("background"), options: .atomic)
        background = rendered
    }

    func resetAvatar() {
        try? FileManager.default.removeItem(at: Self.url("avatar"))
        avatar = nil
    }

    func resetBackground() {
        try? FileManager.default.removeItem(at: Self.url("background"))
        background = nil
    }
}

struct ProfileCustomizeSheet: View {
    @ObservedObject private var store = ProfileAppearanceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var avatarItem: PhotosPickerItem?
    @State private var backgroundItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section("昵称") {
                    TextField("自定义昵称（留空使用账号昵称）", text: $store.nickname)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                }
                Section("头像") {
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        Label("选择头像", systemImage: "person.crop.circle")
                    }
                    if store.avatar != nil {
                        Button("恢复默认头像", role: .destructive) { store.resetAvatar() }
                    }
                }
                Section("背景图") {
                    PhotosPicker(selection: $backgroundItem, matching: .images) {
                        Label("选择背景图", systemImage: "photo")
                    }
                    if store.background != nil {
                        Button("移除背景图", role: .destructive) { store.resetBackground() }
                    }
                }
                Section {
                    Text("头像和背景只保存在本机，不会上传。默认头像来自你登录的账号。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("自定义资料卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .onChange(of: avatarItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { store.setAvatar(data) }
                    avatarItem = nil
                }
            }
            .onChange(of: backgroundItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { store.setBackground(data) }
                    backgroundItem = nil
                }
            }
        }
    }
}

/// The picture of the Moumusic ID card, zoomed and shifted by the user's framing.
struct ProfileCardBackgroundView: View {
    let image: UIImage
    let zoom: Double
    let x: Double
    let y: Double

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(zoom)
                .offset(x: x * proxy.size.width * 0.25 * zoom, y: y * proxy.size.height * 0.25 * zoom)
                .clipped()
        }
    }
}
#endif
