import SwiftUI

/// 平台标识：使用系统符号 + 平台主题色，不使用任何第三方品牌图片。
struct PlatformMark: View {
    let provider: SearchProvider
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(provider.tint)
            Image(systemName: provider.icon)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
