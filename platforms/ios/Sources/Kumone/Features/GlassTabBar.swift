#if os(iOS)
import SwiftUI

/// Floating tab bar for iOS 16–25 (no native Liquid Glass), modelled on
/// Telegram's `TabBarComponent` / `LiquidLensView`:
///   • a full-height glass capsule (56pt content + 4pt inset = 64pt), near
///     full-width;
///   • a sliding selection **capsule that fills the bar height**, tinted the
///     way Telegram tints it — a faint darkening (black @ 7.5%) in light /
///     white @ 10% in dark, not a bright chip;
///   • items whose 23pt filled icon and 10pt semibold label share one colour:
///     black @ 80% unselected, accent when selected;
///   • **an interactive pill you can drag** across the tabs — the lens tracks
///     your finger and switches tabs live, then settles with a spring on
///     release; a plain tap slides it there instead.
struct GlassTabBar: View {
    struct Item: Identifiable {
        let tab: IOSTab
        let title: LocalizedStringKey
        let icon: String
        var id: IOSTab { tab }
    }

    let items: [Item]
    @Binding var selection: IOSTab
    var onReselect: (IOSTab) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    /// Finger x (in content space) while actively dragging the pill; nil at rest.
    @State private var dragX: CGFloat?
    @State private var isDragging = false

    private let innerInset: CGFloat = 4
    private let contentHeight: CGFloat = 56
    private let settle = Animation.spring(response: 0.35, dampingFraction: 0.82)

    var body: some View {
        GeometryReader { geo in
            let count = max(items.count, 1)
            let cellW = geo.size.width / CGFloat(count)
            let selectedIndex = items.firstIndex { $0.tab == selection } ?? 0
            let restX = cellW * (CGFloat(selectedIndex) + 0.5)
            let pillX = isDragging
                ? min(max(dragX ?? restX, cellW / 2), geo.size.width - cellW / 2)
                : restX

            ZStack(alignment: .leading) {
                selectionPill
                    .frame(width: cellW - 8, height: contentHeight)
                    .position(x: pillX, y: geo.size.height / 2)

                HStack(spacing: 0) {
                    ForEach(items) { item in
                        itemLabel(item)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(cellW: cellW, count: count))
        }
        .frame(height: contentHeight)
        .padding(innerInset)
        .background { Capsule().fill(.regularMaterial) }
        .overlay {
            Capsule().strokeBorder(.white.opacity(colorScheme == .dark ? 0.08 : 0.22),
                                   lineWidth: 0.5)
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 12, y: 4)
        .padding(.horizontal, 12)
    }

    private func itemLabel(_ item: GlassTabBar.Item) -> some View {
        let isSelected = selection == item.tab
        return VStack(spacing: 3) {
            Image(systemName: item.icon)
                .font(.system(size: 23, weight: .semibold))
                .symbolVariant(.fill)
            Text(item.title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(isSelected
                         ? AnyShapeStyle(Theme.accent)
                         : AnyShapeStyle(Color.primary.opacity(0.8)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// The sliding indicator — a bar-height capsule with Telegram's faint tint.
    private var selectionPill: some View {
        Capsule(style: .continuous)
            .fill(colorScheme == .dark
                  ? Color.white.opacity(0.10)
                  : Color.black.opacity(0.075))
    }

    private func index(for x: CGFloat, cellW: CGFloat, count: Int) -> Int {
        min(max(Int(x / cellW), 0), count - 1)
    }

    private func dragGesture(cellW: CGFloat, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Wait for a clear horizontal intent before "lifting" the pill,
                // so a plain tap slides rather than teleporting to the finger.
                if !isDragging && abs(value.translation.width) < 8 { return }
                isDragging = true
                dragX = value.location.x
                let tab = items[index(for: value.location.x, cellW: cellW, count: count)].tab
                if tab != selection { selection = tab }   // live switch, pill tracks finger
            }
            .onEnded { value in
                let tab = items[index(for: value.location.x, cellW: cellW, count: count)].tab
                if isDragging {
                    withAnimation(settle) { selection = tab; dragX = nil }
                } else if tab == selection {
                    onReselect(tab)
                } else {
                    withAnimation(settle) { selection = tab }
                }
                isDragging = false
            }
    }
}
#endif
