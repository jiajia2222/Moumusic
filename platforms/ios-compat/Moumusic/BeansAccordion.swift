import SwiftUI

/// 卡片分组：圆角玻璃容器，内部由多行组成（设置页、「我的」页共用）。
struct BeansCardGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background { BeansGlass(shape: RoundedRectangle(cornerRadius: 30, style: .continuous)) }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

/// 卡片分组上方的小标题（账号与平台 / 外观与界面 …）。
struct BeansGroupTitle: View {
    let text: String
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(BeansFont.appFont(14, .medium))
            .foregroundStyle(Color.beansComment)
            .padding(.horizontal, 14)
            .padding(.top, 6)
    }
}

/// 行之间的分隔线（左侧缩进到文字起点）。
struct BeansRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.beansLabel.opacity(0.10))
            .frame(height: 0.7)
            .padding(.leading, 62)
            .padding(.trailing, 16)
    }
}

private struct RowLabel: View {
    let icon: String
    let title: String
    var subtitle: String?
    var trailingText: String?
    var chevron: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.beansAmber)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(BeansFont.appFont(18, .medium))
                    .foregroundStyle(Color.beansLabel)
                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(BeansFont.appFont(13))
                        .foregroundStyle(Color.beansComment)
                }
            }
            Spacer(minLength: 8)
            if let trailingText {
                Text(trailingText)
                    .font(BeansFont.appFont(15))
                    .foregroundStyle(Color.beansComment)
            }
            if let chevron {
                Image(systemName: chevron)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.beansComment)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }
}

/// 点击进入下一级（右侧 ›）。
struct BeansNavRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var trailingText: String?
    let action: () -> Void

    var body: some View {
        Button {
            BeansHaptics.tap()
            action()
        } label: {
            RowLabel(icon: icon, title: title, subtitle: subtitle, trailingText: trailingText, chevron: "chevron.right")
        }
        .buttonStyle(.plain)
    }
}

/// 点击在原位展开（右侧 ⌄ / ⌃），内容显示在行下方。
struct BeansExpandRow<Content: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var trailingText: String?
    @Binding var expanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                BeansHaptics.select()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { expanded.toggle() }
            } label: {
                RowLabel(icon: icon, title: title, subtitle: subtitle, trailingText: trailingText,
                         chevron: expanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.plain)
            if expanded {
                content()
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
    }
}
