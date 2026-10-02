#if os(iOS)
import SwiftUI
import UIKit

/// Numbers shown on the account card of the Bilibili "我的" page.
struct BilibiliAccountStats: Equatable {
    var uid: String?
    var level: Int?
    var coins: Double?
    var following: Int?
    var follower: Int?
    var blacklisted: Int?

    static func fetch(cookie: String?) async -> BilibiliAccountStats {
        var stats = BilibiliAccountStats()
        guard let cookie, !cookie.isEmpty else { return stats }

        func get(_ url: String) async -> [String: Any]? {
            guard let url = URL(string: url) else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["code"] as? Int) == 0 else { return nil }
            return root["data"] as? [String: Any]
        }

        if let nav = await get("https://api.bilibili.com/x/web-interface/nav") {
            if let mid = nav["mid"] as? Int { stats.uid = String(mid) }
            stats.level = (nav["level_info"] as? [String: Any])?["current_level"] as? Int
            if let money = nav["money"] as? Double {
                stats.coins = money
            } else if let money = nav["money"] as? Int {
                stats.coins = Double(money)
            }
        }
        if let relation = await get("https://api.bilibili.com/x/web-interface/nav/stat") {
            stats.following = relation["following"] as? Int
            stats.follower = relation["follower"] as? Int
        }
        if let blacks = await get("https://api.bilibili.com/x/relation/blacks?pn=1&ps=1") {
            stats.blacklisted = blacks["total"] as? Int ?? 0
        }
        return stats
    }
}

/// Beans-style account card: avatar, name, level badge, UID, a four-number
/// capsule and a sign-out row.
struct BilibiliBeansAccountCard: View {
    let avatarURL: URL?
    let name: String
    let uid: String?
    let stats: BilibiliAccountStats
    let onSignOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Group {
                    if let avatarURL {
                        CachedAsyncImage(url: avatarURL, animated: false) {
                            Color.secondary.opacity(0.2)
                        }
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        if let level = stats.level {
                            Text("LV\(level)")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange, in: Capsule())
                        }
                    }
                    if let uid {
                        Text("UID \(uid)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                statCell(stats.following.map(String.init) ?? "-", "关注")
                statCell(stats.follower.map(String.init) ?? "-", "粉丝")
                statCell(stats.blacklisted.map(String.init) ?? "-", "拉黑")
                statCell(stats.coins.map { String(Int($0)) } ?? "-", "硬币")
            }
            .padding(.vertical, 10)
            .background(Theme.accent.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.8))

            Button(action: onSignOut) {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .compatGlass(interactive: false, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.8)
        }
    }

    private func statCell(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.accent)
                .monospacedDigit()
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A titled card of tappable rows (icon, title, optional subtitle/badge, chevron).
struct BilibiliRowCard: View {
    struct Row: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        var subtitle: String?
        var badge: Int?
        let action: () -> Void
    }

    let title: String
    var titleIcon: String?
    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let titleIcon {
                    Image(systemName: titleIcon).font(.title3)
                }
                Text(title).font(.headline.weight(.semibold))
            }
            .padding(.bottom, 6)

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button(action: row.action) {
                    HStack(spacing: 16) {
                        Image(systemName: row.icon)
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .font(.title3)
                                .foregroundStyle(.primary)
                            if let subtitle = row.subtitle {
                                Text(subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if let badge = row.badge, badge > 0 {
                            Text("\(badge)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.red, in: Capsule())
                        }
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < rows.count - 1 {
                    Divider().padding(.leading, 50)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatGlass(interactive: false, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.8)
        }
    }
}

/// Light/dark toggle. The change is revealed with a circle that grows from
/// the button over a snapshot of the previous appearance.
struct ThemeRevealButton: View {
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var center: CGPoint = .zero

    var body: some View {
        Button {
            toggle()
        } label: {
            Image(systemName: colorScheme == .dark ? "sun.max.fill" : "moon.stars.fill")
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { center = CGPoint(x: proxy.frame(in: .global).midX, y: proxy.frame(in: .global).midY) }
                    .onChange(of: proxy.frame(in: .global)) { frame in
                        center = CGPoint(x: frame.midX, y: frame.midY)
                    }
            }
        }
        .accessibilityLabel(colorScheme == .dark ? "切换到浅色" : "切换到深色")
    }

    private func toggle() {
        let next: AppAppearance = colorScheme == .dark ? .light : .dark
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow),
            let snapshot = window.snapshotView(afterScreenUpdates: false) else {
            settings.appearance = next
            return
        }
        window.addSubview(snapshot)
        settings.appearance = next

        let bounds = window.bounds
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0),
                       CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height)]
        let radius = corners.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? bounds.height

        // The snapshot keeps the old look; a hole that grows from the button
        // uncovers the new appearance underneath.
        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        let start = UIBezierPath(rect: bounds)
        start.append(UIBezierPath(arcCenter: center, radius: 1, startAngle: 0, endAngle: .pi * 2, clockwise: true))
        let end = UIBezierPath(rect: bounds)
        end.append(UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true))
        mask.path = end.cgPath
        snapshot.layer.mask = mask

        CATransaction.begin()
        CATransaction.setCompletionBlock { snapshot.removeFromSuperview() }
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = start.cgPath
        animation.toValue = end.cgPath
        animation.duration = 0.55
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mask.add(animation, forKey: "reveal")
        CATransaction.commit()
    }
}
#endif
