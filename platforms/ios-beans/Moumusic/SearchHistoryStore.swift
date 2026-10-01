import Foundation

/// 搜索历史：最近搜索记录，UserDefaults 持久化，最多保留 20 条（按最近优先去重）
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()

    @Published private(set) var history: [String] = []

    private let defaults = UserDefaults.standard
    private let key = "beans.search.history.v1"
    private let maxCount = 20

    private init() {
        history = defaults.stringArray(forKey: key) ?? []
    }

    /// 记录一次搜索（去重后置顶）
    func record(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        history.insert(trimmed, at: 0)
        if history.count > maxCount {
            history.removeLast(history.count - maxCount)
        }
        defaults.set(history, forKey: key)
    }

    /// 删除单条历史
    func remove(_ keyword: String) {
        history.removeAll { $0 == keyword }
        defaults.set(history, forKey: key)
    }

    /// 清空全部历史
    func clear() {
        history = []
        defaults.removeObject(forKey: key)
    }
}
