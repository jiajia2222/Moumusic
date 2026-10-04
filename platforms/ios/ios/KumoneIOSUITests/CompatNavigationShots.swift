import XCTest

/// Diagnosis aid for the compat simulator workflow: opens the app, taps into a playlist and a few other
/// places and saves screenshots into $SHOT_DIR (passed as TEST_RUNNER_SHOT_DIR).
final class CompatNavigationShots: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    private func save(_ name: String) {
        let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    private func tap(_ app: XCUIApplication, _ x: Double, _ y: Double) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }

    @MainActor
    func testHomeAndDetails() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-moumusic.skipUpdateCheck", "YES"]
        app.launch()
        sleep(18)
        if app.alerts.buttons["知道了"].exists { app.alerts.buttons["知道了"].tap() }
        sleep(1)
        save("1-home")

        // First recommended-playlist card.
        tap(app, 0.27, 0.64)
        sleep(8)
        save("2-after-tap-playlist")

        // Back (system swipe / back button), then the Explore tab.
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
        sleep(2)
        save("3-after-back")
        if app.buttons["发现"].exists { app.buttons["发现"].tap() }
        sleep(8)
        save("4-explore")
        tap(app, 0.3, 0.45)
        sleep(8)
        save("5-explore-tap")
    }
}
