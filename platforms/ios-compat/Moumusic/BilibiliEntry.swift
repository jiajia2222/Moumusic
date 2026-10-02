import SwiftUI
import UIKit

#if !MOUMUSIC_COMPAT
import CiliCiliKit

/// 哔哩哔哩全屏模块的统一入口：平台切换按钮、搜索页和「我的」页都通过它打开。
@MainActor
final class BilibiliPresenter: ObservableObject {
    static let shared = BilibiliPresenter()
    @Published var isPresented = false

    func open() { isPresented = true }
    func close() { isPresented = false }
}

/// 全功能版：在应用根视图挂载一次全屏 CiliCili。
struct BilibiliHostModifier: ViewModifier {
    @ObservedObject private var presenter = BilibiliPresenter.shared

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $presenter.isPresented) {
                BilibiliContainer(onClose: { presenter.close() })
            }
    }
}

extension View {
    func bilibiliHost() -> some View { modifier(BilibiliHostModifier()) }
}

/// 「我的」页顶部的哔哩哔哩入口卡片。
struct BilibiliEntryCard: View {
    var body: some View {
        Button {
            BeansHaptics.tap()
            BilibiliPresenter.shared.open()
        } label: {
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "play.tv")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color(red: 0.0, green: 0.63, blue: 0.84))
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("哔哩哔哩")
                            .font(BeansFont.appFont(16, .bold))
                            .foregroundStyle(Color.beansLabel)
                        Text("浏览视频、直播、热搜、评论，并进入哔哩哔哩我的")
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(Color.beansComment)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.beansComment)
                }
            }
        }
        .buttonStyle(GlassPressButtonStyle())
    }
}

/// 账号登录面板里的哔哩哔哩卡片：登录和退出都在哔哩哔哩模块内完成。
struct BilibiliAccountCard: View {
    let onOpen: () -> Void

    var body: some View {
        Button {
            BeansHaptics.tap()
            onOpen()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { BilibiliPresenter.shared.open() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "play.tv")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color(red: 0.0, green: 0.63, blue: 0.84), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("哔哩哔哩")
                        .font(BeansFont.appFont(15, .semibold))
                        .foregroundStyle(Color.beansLabel)
                    Text("扫码或网页登录，在哔哩哔哩模块内管理账号")
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                }
                Spacer()
                Text("打开")
                    .font(BeansFont.appFont(13, .semibold))
                    .foregroundStyle(Color.beansAmber)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background { BeansGlass(shape: Capsule()) }
            }
            .padding(14)
            .background { BeansGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
    }
}

private struct BilibiliContainer: View {
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            CiliCiliHostView()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.45))
                    .padding(12)
            }
            .accessibilityLabel("关闭哔哩哔哩")
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

/// 播放器横竖屏切换需要宿主 AppDelegate 把 CiliCili 的方向锁返回给系统。
final class MoumusicAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { CiliCiliBridge.supportedOrientations }
    }
}
#else
/// 适配版（iOS 15–18）不包含哔哩哔哩模块：入口全部为空操作。
@MainActor
final class BilibiliPresenter: ObservableObject {
    static let shared = BilibiliPresenter()
    func open() {}
    func close() {}
}

struct BilibiliEntryCard: View {
    var body: some View { EmptyView() }
}

extension View {
    func bilibiliHost() -> some View { self }
}
#endif
