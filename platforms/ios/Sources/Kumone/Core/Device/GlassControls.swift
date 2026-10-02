#if os(iOS)
import SwiftUI

/// Card used by the feedback / developer sheets: the app's own glass card.
typealias GlassCard = MouGlassCard

/// Capsule button used by the feedback / developer sheets.
struct GlassButton: View {
    let title: String
    var systemName: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemName {
                    Image(systemName: systemName)
                }
                Text(LocalizedStringKey(title))
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                if prominent {
                    Capsule().fill(Theme.accent)
                } else {
                    Capsule().fill(.thinMaterial)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
#endif
