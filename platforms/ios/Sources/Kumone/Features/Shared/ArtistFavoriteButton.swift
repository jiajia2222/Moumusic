import SwiftUI

/// Round heart button of an artist page: keeps the artist in the local favourites ("我的收藏" → 收藏), which works for every
/// platform and without a login (the NetEase account follow is a separate button).
struct ArtistFavoriteButton: View {
    let source: String
    let providerID: String
    let name: String
    let coverURL: String?

    @ObservedObject private var favorites = FavoritesStore.shared

    var body: some View {
        let isFavorite = favorites.contains(kind: .artist, source: source, providerID: providerID)
        Button {
            let added = favorites.toggle(kind: .artist, source: source, providerID: providerID,
                                         name: name, coverURL: coverURL)
            ToastCenter.shared.show(added ? "已收藏歌手" : "已取消收藏歌手")
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFavorite ? Theme.accent : .primary)
                .frame(width: 38, height: 38)
                .background(.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(isFavorite ? "取消收藏歌手" : "收藏歌手")
    }
}
