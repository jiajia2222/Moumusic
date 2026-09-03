import Foundation

/// Keeps a record rotating continuously across pause/resume without jumping
/// back to zero degrees.
public struct RecordRotationState: Equatable, Sendable {
    public static let defaultDegreesPerSecond: Double = 24

    public let degreesPerSecond: Double
    private(set) public var isAnimating = false
    private var baseAngle = 0.0
    private var startedAt = Date(timeIntervalSinceReferenceDate: 0)
    private var stoppedAngle = 0.0

    public init(degreesPerSecond: Double = defaultDegreesPerSecond) {
        self.degreesPerSecond = degreesPerSecond
    }

    public mutating func start(at date: Date = Date()) {
        guard !isAnimating else { return }
        baseAngle = stoppedAngle
        startedAt = date
        isAnimating = true
    }

    public mutating func stop(at date: Date = Date(), extraTravelDegrees: Double = 0) {
        guard isAnimating else { return }
        stoppedAngle = currentAngle(at: date) + extraTravelDegrees
        isAnimating = false
    }

    public func currentAngle(at date: Date) -> Double {
        guard isAnimating else { return stoppedAngle }
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        return baseAngle + elapsed * degreesPerSecond
    }

    public mutating func reset(to angle: Double = 0) {
        baseAngle = angle
        stoppedAngle = angle
        isAnimating = false
    }
}
