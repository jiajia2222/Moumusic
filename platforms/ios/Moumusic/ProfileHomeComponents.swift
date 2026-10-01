import SwiftUI
import UIKit

// MARK: - 头像 / 昵称

/// 「我的」资料卡的头像：保存在本机，可更换。
@MainActor
final class BeansAvatarStore: ObservableObject {
    static let shared = BeansAvatarStore()
    @Published private(set) var image: UIImage?

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Profile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("avatar.jpg")
    }

    private init() {
        image = UIImage(contentsOfFile: Self.fileURL.path)
    }

    func set(_ data: Data) {
        guard let source = UIImage(data: data) else { return }
        let side: CGFloat = 512
        let scale = max(side / source.size.width, side / source.size.height)
        let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let cropped = renderer.image { _ in
            source.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        try? cropped.jpegData(compressionQuality: 0.9)?.write(to: Self.fileURL, options: .atomic)
        image = cropped
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.fileURL)
        image = nil
    }
}

// MARK: - 资料卡

@MainActor
struct ProfileIdentityCard: View {
    @ObservedObject private var reporter = DeviceReporter.shared
    @ObservedObject private var stats = ListeningStatsStore.shared
    @ObservedObject private var avatar = BeansAvatarStore.shared
    @AppStorage("beans.profile.customNickname") private var nickname = ""
    @State private var showAvatarPicker = false
    @State private var showNameEditor = false
    @State private var nameDraft = ""
    @State private var copied = false

    private var displayName: String { nickname.isEmpty ? "Mou" : nickname }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.04, green: 0.05, blue: 0.09)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            ProfileDialArt()
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    avatarView
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            nameDraft = nickname
                            showNameEditor = true
                        } label: {
                            Text(displayName)
                                .font(BeansFont.appFont(26, .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        idPill
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.beansAmber)
                }
                Rectangle().fill(.white.opacity(0.10)).frame(height: 0.7)
                HStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 19))
                        .foregroundStyle(Color.beansAmber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("听歌时长")
                            .font(BeansFont.appFont(13))
                            .foregroundStyle(.white.opacity(0.62))
                        Text(stats.formattedDuration.replacingOccurrences(of: "分钟", with: " 分钟").replacingOccurrences(of: "小时", with: " 小时 "))
                            .font(BeansFont.appFont(24, .bold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    if stats.streakDays > 1 {
                        Label("连续 \(stats.streakDays) 天", systemImage: "flame.fill")
                            .font(BeansFont.appFont(12, .semibold))
                            .foregroundStyle(Color.beansAmber)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                }
                footprints
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
        .sheet(isPresented: $showAvatarPicker) {
            WallpaperPhotoPicker { data in
                BeansAvatarStore.shared.set(data)
                BeansHaptics.success()
            }
            .ignoresSafeArea()
        }
        .alert("修改昵称", isPresented: $showNameEditor) {
            TextField("昵称", text: $nameDraft)
            Button("保存") { nickname = String(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16)) }
            Button("取消", role: .cancel) {}
        }
    }

    /// 近 7 天听歌足迹：每天一根柱子，今天高亮。
    private var footprints: some View {
        let days = stats.lastSevenDays()
        let peak = max(days.map(\.minutes).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("近 7 天听歌足迹")
                .font(BeansFont.appFont(11))
                .foregroundStyle(.white.opacity(0.5))
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(index == days.count - 1 ? Color.beansAmber : Color.white.opacity(day.minutes > 0 ? 0.38 : 0.12))
                            .frame(height: max(4, 34 * CGFloat(day.minutes / peak)))
                        Text(day.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 52, alignment: .bottom)
        }
    }

    private var avatarView: some View {
        Button {
            BeansHaptics.tap()
            showAvatarPicker = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = avatar.image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Circle().fill(.white.opacity(0.06))
                            Image(systemName: "person.fill")
                                .font(.system(size: 38))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(Circle())
                Image(systemName: "camera.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.beansAmber, in: Circle())
                    .overlay(Circle().strokeBorder(Color(red: 0.05, green: 0.06, blue: 0.1), lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if avatar.image != nil {
                Button(role: .destructive) { BeansAvatarStore.shared.clear() } label: { Label("删除头像", systemImage: "trash") }
            }
        }
    }

    private var idPill: some View {
        let id = reporter.displayID.isEmpty ? "—" : reporter.displayID
        let exclusive = !reporter.exclusiveID.isEmpty
        return Button {
            UIPasteboard.general.string = id
            BeansHaptics.success()
            ToastCenter.shared.show("用户 ID 已复制")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: exclusive ? "star.fill" : "number")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(.white.opacity(exclusive ? 0 : 0.35), in: Circle())
                Text("ID · \(id)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
            }
            .foregroundStyle(exclusive
                             ? (reporter.badgeStyle == .classicGold ? Color(red: 0.23, green: 0.16, blue: 0.0) : Color(red: 0.96, green: 0.84, blue: 0.48))
                             : Color.white.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(exclusive
                               ? AnyShapeStyle(reporter.badgeStyle == .classicGold
                                               ? LinearGradient(colors: [Color(red: 1, green: 0.89, blue: 0.54), Color(red: 0.88, green: 0.66, blue: 0.18)], startPoint: .leading, endPoint: .trailing)
                                               : LinearGradient(colors: [Color(red: 0.04, green: 0.04, blue: 0.06), Color(red: 0.29, green: 0.16, blue: 0.48)], startPoint: .leading, endPoint: .trailing))
                               : AnyShapeStyle(Color.white.opacity(0.22)))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

/// 资料卡背景：仪表盘刻度与指针（纯装饰）。
struct ProfileDialArt: View {
    private let labels = ["0", "5", "10", "20", "50", "100", "200", "500", "1G", "2G", "5G"]

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height * 1.25)
            let center = CGPoint(x: geo.size.width * 0.52, y: geo.size.height * 0.62)
            ZStack {
                Circle()
                    .trim(from: 0.12, to: 0.82)
                    .stroke(Color(red: 0.16, green: 0.24, blue: 0.5).opacity(0.38), style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round))
                    .frame(width: size * 0.88, height: size * 0.88)
                    .rotationEffect(.degrees(95))
                    .position(center)
                ForEach(Array(labels.enumerated()), id: \.offset) { index, text in
                    let fraction = Double(index) / Double(labels.count - 1)
                    let angle = Angle.degrees(150 + fraction * 240)
                    let radius = size * 0.43
                    Text(text)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.28))
                        .rotationEffect(angle + .degrees(90))
                        .position(x: center.x + CGFloat(cos(angle.radians)) * radius,
                                  y: center.y + CGFloat(sin(angle.radians)) * radius)
                }
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.0), .white.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: size * 0.34, height: 10)
                    .offset(x: size * 0.17)
                    .rotationEffect(.degrees(-38))
                    .position(center)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 自愿赞助（music.nadev.xyz 爱发电接口）

struct SponsorSupporter: Identifiable, Hashable {
    let id: String
    let name: String
    let plan: String
    let avatarURL: URL?
    let time: Date?
}

@MainActor
final class SponsorStore: ObservableObject {
    static let shared = SponsorStore()
    static let siteBase = "https://music.nadev.xyz"
    static let afdianURL = URL(string: "https://www.ifdian.net/a/moumou2026")!

    @Published private(set) var supporters: [SponsorSupporter] = []
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    private var lastLoad = Date.distantPast

    func load(force: Bool = false) async {
        if !force, Date().timeIntervalSince(lastLoad) < 600, !supporters.isEmpty { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            guard let url = URL(string: Self.siteBase + "/api/aifadian/sponsors") else { return }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = root["supporters"] as? [[String: Any]] else { failed = true; return }
            supporters = list.map { item in
                let t = (item["lastSupportTime"] as? Double) ?? (item["lastSupportTime"] as? Int).map(Double.init)
                return SponsorSupporter(
                    id: item["id"] as? String ?? UUID().uuidString,
                    name: item["name"] as? String ?? "支持者",
                    plan: item["plan"] as? String ?? "",
                    avatarURL: (item["avatar"] as? String).flatMap(URL.init(string:)),
                    time: t.map { Date(timeIntervalSince1970: $0) }
                )
            }
            lastLoad = Date()
        } catch {
            failed = true
        }
    }
}

@MainActor
struct SponsorExpandedContent: View {
    @ObservedObject private var store = SponsorStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("感谢每一位支持者，让 Moumusic 能持续维护。赞助完全自愿，不影响任何功能。")
                .font(BeansFont.appFont(13))
                .foregroundStyle(Color.beansComment)
            GlassButton(title: "前往爱发电支持", systemName: "heart.fill", prominent: true) {
                UIApplication.shared.open(SponsorStore.afdianURL)
            }
            Text("支持者")
                .font(BeansFont.appFont(14, .semibold))
                .foregroundStyle(Color.beansLabel)
            if store.loading && store.supporters.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if store.failed && store.supporters.isEmpty {
                Text("支持者名单暂时无法加载，稍后再试")
                    .font(BeansFont.appFont(12)).foregroundStyle(Color.beansComment)
            } else if store.supporters.isEmpty {
                Text("还没有支持者，成为第一位吧")
                    .font(BeansFont.appFont(12)).foregroundStyle(Color.beansComment)
            }
            ForEach(store.supporters) { person in
                HStack(spacing: 10) {
                    AsyncImage(url: person.avatarURL) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFill() }
                        else { Color.beansLabel.opacity(0.1) }
                    }
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(person.name).font(BeansFont.appFont(14, .medium)).foregroundStyle(Color.beansLabel).lineLimit(1)
                        if !person.plan.isEmpty {
                            Text(person.plan).font(BeansFont.appFont(11)).foregroundStyle(Color.beansComment)
                        }
                    }
                    Spacer()
                    if let time = person.time {
                        Text(Self.dateText(time)).font(BeansFont.appFont(11)).foregroundStyle(Color.beansComment)
                    }
                }
            }
        }
        .task { await store.load() }
    }

    private static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - 音乐收藏

@MainActor
struct FavoritesSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var favorites = FavoritesStore.shared
    @State private var filter = 0

    private var groups: [(String, [Song])] {
        [("网易云音乐", favorites.neteaseFavoriteSongs), ("QQ音乐", favorites.qqFavoriteSongs),
         ("酷狗音乐", favorites.kugouFavoriteSongs), ("酷我 / 咪咕", favorites.extraFavoriteSongs)]
    }

    private var songs: [Song] {
        filter == 0 ? groups.flatMap { $0.1 } : groups[filter - 1].1
    }

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                VStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("全部", 0)
                            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                                chip("\(group.0) \(group.1.count)", index + 1)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    if songs.isEmpty {
                        Spacer()
                        Text("还没有收藏的歌曲").font(BeansFont.appFont(14)).foregroundStyle(Color.beansComment)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                                    SongCell(song: song, glassRow: true, playbackContext: songs, playbackIndex: index) {
                                        player.play(songs: songs, startAt: index)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 120)
                        }
                        .beansScrollIndicatorsHidden()
                    }
                }
            }
            .navigationTitle("音乐收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func chip(_ title: String, _ tag: Int) -> some View {
        let selected = filter == tag
        return Button { filter = tag } label: {
            Text(title)
                .font(BeansFont.appFont(13, selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Color.beansLabel)
                .padding(.horizontal, 14).frame(height: 34)
                .background(selected ? Color.beansAmber : Color.beansLabel.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
