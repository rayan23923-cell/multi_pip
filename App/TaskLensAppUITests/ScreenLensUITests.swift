import XCTest

/// Screen Lens: the unsupported path on this simulator (iOS 26 has no
/// ScreenCaptureKit), and the full lifecycle with a stand-in capture.
final class ScreenLensUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(fakeCapture: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-TaskLensUITestStore", "-TaskLensResetStore"]
        if fakeCapture { app.launchArguments.append("-TaskLensScreenLensFake") }
        app.launch()
        app.open(URL(string: "tasklens://lens")!)
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scrolls the Lens list until the element is on screen.
    private func reveal(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 10) -> XCUIElement {
        let target = element(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(identifier) not found")
        var swipes = 0
        while !target.isHittable && swipes < 5 {
            app.swipeUp()
            swipes += 1
        }
        return target
    }

    /// Scrolls the lazy list until one of two elements exists.
    private func revealEither(_ app: XCUIApplication, _ first: String, _ second: String) -> Bool {
        let a = element(app, first), b = element(app, second)
        if a.waitForExistence(timeout: 3) || b.exists { return true }
        for _ in 0..<10 {
            app.swipeUp()
            if a.waitForExistence(timeout: 1) || b.exists { return true }
        }
        app.printScreen(missing: "\(first) or \(second)")
        return false
    }

    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 10) {
        reveal(app, identifier, timeout: timeout).tap()
    }

    func testUnsupportedDeviceOffersTheScreenshotRoute() {
        let app = launch(fakeCapture: false)
        XCTAssertTrue(element(app, "lens.input").waitForExistence(timeout: 10))
        let notice = reveal(app, "screenLens.unavailable")
        XCTAssertTrue(notice.exists)
        XCTAssertFalse(element(app, "screenLens.start").exists, "No Start where capture can't run")
        // The screenshot route stays: Photos and Files are offered.
        XCTAssertTrue(element(app, "lens.image.photos").exists)
        XCTAssertTrue(element(app, "lens.image.files").exists)
    }

    func testStartCaptureFindAndDelete() {
        let app = launch(fakeCapture: true)
        tap(app, "screenLens.start")
        // Live: a visible status, Capture and Stop.
        XCTAssertTrue(reveal(app, "screenLens.status").exists)
        XCTAssertTrue(element(app, "screenLens.stop").exists)
        tap(app, "screenLens.capture")
        // After the countdown one frame is read and capture stops.
        let highlight = element(app, "screenLens.highlight")
        XCTAssertTrue(highlight.waitForExistence(timeout: 20), "No Lens results")
        XCTAssertFalse(element(app, "screenLens.status").exists, "Capture stopped after the frame")
        let labels = app.descendants(matching: .any).matching(identifier: "screenLens.highlight")
            .allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
        XCTAssertTrue(labels.contains("199"), "Highlights: \(labels)")
        // Recommended actions for the chosen finding, nothing run on its own.
        XCTAssertTrue(revealEither(app, "action.convertCurrency", "lens.image.confirm"),
                      "A price offers money actions, or asks to confirm a possible match")

        tap(app, "screenLens.clear")
        XCTAssertFalse(element(app, "screenLens.highlight").waitForExistence(timeout: 2))
        XCTAssertTrue(reveal(app, "screenLens.start").exists)
    }

    func testStopEndsCapture() {
        let app = launch(fakeCapture: true)
        tap(app, "screenLens.start")
        XCTAssertTrue(reveal(app, "screenLens.status").exists)
        tap(app, "screenLens.stop")
        XCTAssertTrue(reveal(app, "screenLens.message").exists)
        XCTAssertFalse(element(app, "screenLens.status").exists)
        XCTAssertTrue(element(app, "screenLens.start").exists)
    }

    func testCaptureSurvivesLeavingTheLensScreen() {
        let app = launch(fakeCapture: true)
        tap(app, "screenLens.start")
        XCTAssertTrue(reveal(app, "screenLens.status").exists)
        // Going to the Home Screen and back keeps the same capture.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(reveal(app, "screenLens.status").exists)
        tap(app, "screenLens.stop")
    }
}
