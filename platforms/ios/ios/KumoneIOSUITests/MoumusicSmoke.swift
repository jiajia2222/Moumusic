import XCTest

/// Simulator smoke test: switches the home platform through every catalogue, opens the Explore tab on each,
/// and saves screenshots into $SHOT_DIR (TEST_RUNNER_SHOT_DIR) so layout / empty-state / error bugs show up.
final class MoumusicSmoke: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    private func save(_ name: String) {
        let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    private func platformMenu(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS '平台' AND label CONTAINS '点击切换'")).firstMatch
    }

    /// Opens the top-left platform menu and picks `name`; returns false when the menu or item is missing.
    @discardableResult
    private func pick(_ app: XCUIApplication, _ name: String) -> Bool {
        let menu = platformMenu(app)
        guard menu.waitForExistence(timeout: 6) else { return false }
        menu.tap()
        let item = app.buttons[name]
        guard item.waitForExistence(timeout: 4) else { app.tap(); return false }
        item.tap()
        return true
    }

    @MainActor
    func testPlatformsAndExplore() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-moumusic.skipUpdateCheck", "YES"]
        app.launch()
        sleep(8)
        // The "what's new" sheet and any alert.
        if app.buttons["完成"].firstMatch.waitForExistence(timeout: 3) { app.buttons["完成"].firstMatch.tap() }
        if app.alerts.buttons["知道了"].exists { app.alerts.buttons["知道了"].tap() }
        sleep(4)
        save("01-home-wy")

        for (index, name) in ["QQ 音乐", "酷狗", "酷我", "咪咕", "网易云"].enumerated() {
            if pick(app, name) {
                sleep(9)
                save("02-home-\(index)-\(name)")
            } else {
                save("02-home-\(index)-\(name)-MENU-NOT-FOUND")
            }
        }

        app.buttons["发现"].firstMatch.tap()
        sleep(8)
        save("03-explore-initial")
        for (index, name) in ["QQ 音乐", "酷狗", "酷我", "咪咕"].enumerated() {
            if pick(app, name) {
                sleep(8)
                save("04-explore-\(index)-\(name)")
            } else {
                save("04-explore-\(index)-\(name)-MENU-NOT-FOUND")
            }
        }
        // Pull to refresh on the current Explore page.
        app.swipeDown()
        sleep(6)
        save("05-explore-after-refresh")
    }
}
