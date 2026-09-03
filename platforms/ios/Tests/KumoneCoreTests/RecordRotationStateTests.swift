import XCTest
@testable import KumoneCore

final class RecordRotationStateTests: XCTestCase {
    func testPauseAndResumePreserveRotation() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var state = RecordRotationState()
        state.start(at: start)
        XCTAssertEqual(state.currentAngle(at: start.addingTimeInterval(2)), 48, accuracy: 0.001)

        state.stop(at: start.addingTimeInterval(2))
        XCTAssertEqual(state.currentAngle(at: start.addingTimeInterval(4)), 48, accuracy: 0.001)

        state.start(at: start.addingTimeInterval(4))
        XCTAssertEqual(state.currentAngle(at: start.addingTimeInterval(5)), 72, accuracy: 0.001)
    }

    func testResetStopsAtRequestedAngle() {
        var state = RecordRotationState()
        state.reset(to: 135)
        XCTAssertFalse(state.isAnimating)
        XCTAssertEqual(state.currentAngle(at: Date()), 135, accuracy: 0.001)
    }
}
