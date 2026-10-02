import Foundation
import Combine

@MainActor
final class AfdianSupportStore: ObservableObject {
    static let shared = AfdianSupportStore()

    @Published private(set) var sponsors: [AfdianSponsorService.Sponsor] = []
    @Published private(set) var stats: AfdianSponsorService.Stats?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

    private init() {}

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let lastUpdated,
           Date().timeIntervalSince(lastUpdated) < 10 * 60 {
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let snapshot = try await AfdianSponsorService.shared.load()
            sponsors = snapshot.sponsors
            stats = snapshot.stats
            lastUpdated = Date()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
