import SwiftUI

extension Array where Element == Track {
    /// The songs of a playlist that match what was typed in its search field (name, artist or album).
    func matching(_ query: String) -> [Track] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return self }
        return filter {
            $0.name.localizedStandardContains(query)
                || $0.artistNames.localizedStandardContains(query)
                || $0.album.name.localizedStandardContains(query)
        }
    }
}

/// The row that appears under the navigation bar when the round search button of a playlist is tapped.
struct TrackSearchField: View {
    @Binding var text: String
    @Binding var isSearching: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索歌单内歌曲", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.search)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(.primary.opacity(0.07), in: Capsule())

            Button("取消") {
                text = ""
                isSearching = false
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .onAppear { focused = true }
    }
}

extension View {
    /// A small round search button at the top right of a playlist; tapping it shows or hides the search row
    /// (`TrackSearchField`). Hiding it clears the search.
    func trackSearchButton(isSearching: Binding<Bool>, text: Binding<String>) -> some View {
        #if os(iOS)
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isSearching.wrappedValue { text.wrappedValue = "" }
                        isSearching.wrappedValue.toggle()
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("搜索歌单内歌曲")
            }
        }
        #else
        self
        #endif
    }
}
