import SwiftUI

extension Notification.Name {
    /// 顶部头像按钮：请求切换到「我的」标签页。
    static let beansOpenProfileTab = Notification.Name("beans.openProfileTab")
}

/// 主页 / 精选 / 歌单 页顶部栏：左侧当前平台（点击切换），中间可放搜索框，右侧「我的」入口。
@MainActor
struct PlatformHeaderBar<Center: View>: View {
    @AppStorage("beans.homeSource") private var homeSourceRaw = SearchProvider.netease.rawValue
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    let center: Center

    init(@ViewBuilder center: () -> Center) {
        self.center = center()
    }

    private var current: SearchProvider {
        let saved = SearchProvider(rawValue: homeSourceRaw) ?? .netease
        return platformPrefs.ensureVisible(saved)
    }

    var body: some View {
        HStack(spacing: 12) {
            platformButton
            if Center.self == EmptyView.self {
                Spacer(minLength: 0)
            } else {
                center.frame(maxWidth: .infinity)
            }
            avatarButton
        }
    }

    private var platformButton: some View {
        Menu {
            ForEach(platformPrefs.enabledSearchProviders) { provider in
                Button {
                    BeansHaptics.select()
                    if provider.isVideoPlatform {
                        BilibiliPresenter.shared.open()
                    } else {
                        homeSourceRaw = provider.rawValue
                    }
                } label: {
                    Label(LocalizedStringKey(provider.rawValue), systemImage: provider == current ? "checkmark" : provider.icon)
                }
            }
        } label: {
            PlatformMark(provider: current, size: 48)
                .padding(2)
                .background { BeansGlass(shape: Circle(), forceLiquid: true) }
                .clipShape(Circle())
        }
        .accessibilityLabel("切换平台")
    }

    private var avatarButton: some View {
        Button {
            BeansHaptics.tap()
            NotificationCenter.default.post(name: .beansOpenProfileTab, object: nil)
        } label: {
            ZStack {
                if let image = BeansAvatarStore.shared.image {
                    Image(uiImage: image).resizable().scaledToFill().clipShape(Circle())
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.beansLabel)
                }
            }
            .frame(width: 48, height: 48)
            .background { BeansGlass(shape: Circle(), forceLiquid: true) }
            .clipShape(Circle())
            .contentShape(Circle())
        }
        .buttonStyle(GlassPressButtonStyle())
        .accessibilityLabel("我的")
    }
}

extension PlatformHeaderBar where Center == EmptyView {
    init() {
        self.init { EmptyView() }
    }
}
