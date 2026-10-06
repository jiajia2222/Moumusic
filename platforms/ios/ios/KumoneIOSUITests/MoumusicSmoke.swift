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

    /// Record-player mode: the turntable page, then the full lyric page after tapping the record.
    @MainActor
    func testVinylLyrics() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-moumusic.skipUpdateCheck", "YES", "-moumusic.debugNowPlaying", "vinyl"]
        app.launch()
        sleep(22)
        save("10-vinyl-turntable")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        sleep(3)
        save("11-vinyl-lyrics")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        sleep(2)
        save("12-vinyl-back")
    }

    /// The original AMLL lyric player (web view) on the lyrics page: three frames a few seconds apart.
    @MainActor
    func testAMLLOriginal() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-moumusic.skipUpdateCheck", "YES", "-settings.lyricsDisplayStyle", "amll", "-moumusic.debugAMLL", "YES",
                                "-moumusic.debugNowPlaying", "lyrics"]
        app.launch()
        sleep(26)
        save("40-amll-1")
        sleep(4)
        save("41-amll-2")
        sleep(4)
        save("42-amll-3")
    }

    /// AMLL lyrics while the songs change: A, then B, then A again (a restart). Screenshots after each stage.
    @MainActor
    func testAMLLSwitch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-moumusic.skipUpdateCheck", "YES", "-settings.lyricsDisplayStyle", "amll", "-moumusic.debugAMLL", "YES",
                                "-moumusic.debugNowPlaying", "lyrics", "-moumusic.debugSwitch", "YES"]
        app.launch()
        sleep(20)
        save("50-switch-A")
        sleep(12)
        save("51-switch-B")
        sleep(14)
        save("52-switch-A-again")
        sleep(10)
        save("53-switch-final")
    }

    /// The audio is said to be shorter than the lyrics: the lyrics are looked up again, and stay when nothing fits.
    @MainActor
    func testLyricVersionCheck() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-moumusic.skipUpdateCheck", "YES", "-settings.lyricsDisplayStyle", "amll",
                                "-moumusic.debugNowPlaying", "lyrics", "-moumusic.debugVersionFlow", "YES"]
        app.launch()
        sleep(52)
        save("60-version-check")
    }

    /// The classic player page (volume bar alignment).
    @MainActor
    func testClassicPlayer() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-moumusic.skipUpdateCheck", "YES", "-moumusic.debugNowPlaying", "classic"]
        app.launch()
        sleep(22)
        save("30-classic-player")
    }

    /// Explore keeps the platform picked there after opening a playlist and coming back.
    @MainActor
    func testExploreKeepsPlatform() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-moumusic.skipUpdateCheck", "YES"]
        app.launch()
        sleep(8)
        if app.buttons["完成"].firstMatch.waitForExistence(timeout: 3) { app.buttons["完成"].firstMatch.tap() }
        app.buttons["发现"].firstMatch.tap()
        sleep(4)
        pick(app, "酷我")
        sleep(8)
        save("20-explore-kuwo-before")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.27, dy: 0.40)).tap()
        sleep(6)
        save("21-playlist-open")
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
        sleep(4)
        save("22-explore-after-back")
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
        sleep(2)
        save("05a-explore-2s-after-pull")
        sleep(4)
        save("05-explore-after-refresh")
    }
}
