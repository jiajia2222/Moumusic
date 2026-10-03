#if os(iOS)
import SwiftUI

/// Search history (local) and Bilibili's hot searches, shown while the search field is empty.
enum BiliSearchHistory {
    private static let key = "moumusic.bili.searchHistory"

    static var items: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = items.filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(list.prefix(15)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

struct BilibiliSearchSuggestions: View {
    let onPick: (String) -> Void

    @State private var history = BiliSearchHistory.items
    @State private var hot: [String] = []

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !history.isEmpty {
                HStack {
                    Text("搜索历史").font(.headline)
                    Spacer()
                    Button("清空") {
                        BiliSearchHistory.clear()
                        history = []
                    }
                    .font(.footnote)
                }
                chips(history)
            }
            if !hot.isEmpty {
                Text("哔哩哔哩热搜").font(.headline)
                chips(hot)
            }
            if history.isEmpty && hot.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "搜索哔哩哔哩视频、UP 主或合集")
                    .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .task {
            history = BiliSearchHistory.items
            hot = await BilibiliAPI.shared.hotSearchKeywords()
        }
    }

    private func chips(_ words: [String]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(words, id: \.self) { word in
                Button { onPick(word) } label: {
                    Text(word)
                        .font(.subheadline)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
#endif
