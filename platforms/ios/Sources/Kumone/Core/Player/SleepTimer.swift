import Combine
import Foundation

/// Stops playback after a fixed duration or when the current track ends.
/// The timer lives with the shared player so it continues working when the
/// now-playing page is dismissed or a CarPlay scene is connected.
@MainActor
final class SleepTimer: ObservableObject {
    enum State: Equatable {
        case inactive
        case countdown(deadline: Date)
        case endOfCurrentTrack

        var isActive: Bool { self != .inactive }
    }

    @Published private(set) var state: State = .inactive

    var onDeadlineReached: (() -> Void)?

    private var deadlineTask: Task<Void, Never>?
    private var generation = 0

    func schedule(afterMinutes minutes: Int) {
        precondition(minutes > 0, "Sleep timer duration must be positive")

        generation += 1
        let scheduledGeneration = generation
        deadlineTask?.cancel()

        let seconds = TimeInterval(minutes * 60)
        state = .countdown(deadline: Date.now.addingTimeInterval(seconds))
        deadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  self.generation == scheduledGeneration else { return }

            self.deadlineTask = nil
            self.state = .inactive
            self.onDeadlineReached?()
        }
    }

    func scheduleAtEndOfCurrentTrack() {
        generation += 1
        deadlineTask?.cancel()
        deadlineTask = nil
        state = .endOfCurrentTrack
    }

    func cancel() {
        generation += 1
        deadlineTask?.cancel()
        deadlineTask = nil
        state = .inactive
    }

    func consumeEndOfCurrentTrack() -> Bool {
        guard state == .endOfCurrentTrack else { return false }
        cancel()
        return true
    }
}
