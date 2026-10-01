import SwiftUI
import UIKit

#if !MOUMUSIC_COMPAT
import CiliCiliKit

/// 全功能版：把 CiliCili（哔哩哔哩）作为全屏模块打开。
struct BilibiliEntryCard: View {
    @State private var showBilibili = false

    var body: some View {
        Button {
            BeansHaptics.tap()
            showBilibili = true
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
        .fullScreenCover(isPresented: $showBilibili) {
            BilibiliContainer(onClose: { showBilibili = false })
        }
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
/// 适配版（iOS 15–18）不包含哔哩哔哩模块。
struct BilibiliEntryCard: View {
    var body: some View { EmptyView() }
}
#endif
