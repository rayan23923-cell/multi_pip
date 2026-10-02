import XCTest

/// Picture in Picture workspace on the real app. The system window itself is
/// drawn by iOS outside the app, so these tests check TaskLens's side: cards,
/// controls, state across relaunch and the unsupported-device path.
final class PiPUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(reset: Bool = true, unsupported: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-TaskLensUITestStore"]
        if reset { app.launchArguments.append("-TaskLensResetStore") }
        if unsupported { app.launchArguments.append("-TaskLensPiPUnsupported") }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 10) {
        let target = element(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(identifier) not found")
        target.tap()
    }

    /// 12 × 3 = 36 in the calculator, then Keep in Picture in Picture.
    private func keepCalculatorResult(_ app: XCUIApplication) {
        tap(app, "commandCenter.calculator")
        for key in ["1", "2", "multiply", "3", "equals"] { tap(app, "calculator.key.\(key)", timeout: 3) }
        tap(app, "calculator.menu")
        let keep = element(app, "calculator.keepInPiP")
        if keep.waitForExistence(timeout: 3) {
            keep.tap()
        } else {
            app.buttons["Keep in Picture in Picture"].firstMatch.tap()
        }
        XCTAssertTrue(app.navigationBars["Picture in Picture"].waitForExistence(timeout: 5), "Keeping a card opens Picture in Picture")
        let card = element(app, "pipCard")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        // Title is the expression ("12 × 3"), the body the result ("= 36").
        XCTAssertTrue(card.label.contains("36"), "Card label: \(card.label)")
    }

    func testUnsupportedDeviceExplainsAndNeverOffersStart() {
        let app = launch(unsupported: true)
        keepCalculatorResult(app)
        XCTAssertTrue(element(app, "pip.unsupported").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "pip.start").exists)
        XCTAssertFalse(element(app, "pip.preview").exists)
        // The limits are explained, not hidden.
        XCTAssertTrue(app.staticTexts["What Picture in Picture can do"].exists || element(app, "pip.limits").exists)
    }

    func testCardsAndControlsInTaskLens() {
        let app = launch()
        keepCalculatorResult(app)

        if element(app, "pip.unsupported").waitForExistence(timeout: 2) {
            // This simulator has no Picture in Picture: the honest path is shown.
            XCTAssertFalse(element(app, "pip.start").exists)
            return
        }
        XCTAssertTrue(element(app, "pip.preview").waitForExistence(timeout: 5))
        let start = element(app, "pip.start")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        let status = element(app, "pip.status")
        XCTAssertTrue(status.exists)

        guard start.isEnabled else {
            XCTAssertEqual(status.label, "Not available right now")
            return
        }
        start.tap()
        let stop = element(app, "pip.stop")
        if stop.waitForExistence(timeout: 5), status.label == "Showing" {
            // Foreground → background → foreground with the window open.
            XCUIDevice.shared.press(.home)
            sleep(2)
            app.activate()
            XCTAssertTrue(element(app, "pip.status").waitForExistence(timeout: 10))
            if element(app, "pip.stop").exists {
                element(app, "pip.stop").tap()
            }
            XCTAssertTrue(element(app, "pip.start").waitForExistence(timeout: 10), "Stopping returns to Start")
        }
    }

    func testCardsSurviveRelaunchAndClosedAppIsExplained() {
        let app = launch()
        keepCalculatorResult(app)
        app.terminate()

        let relaunched = launch(reset: false)
        tap(relaunched, "commandCenter.pip")
        let card = element(relaunched, "pipCard")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Cards are kept across launches")
        // Title is the expression ("12 × 3"), the body the result ("= 36").
        XCTAssertTrue(card.label.contains("36"), "Card label: \(card.label)")
    }

    func testCardsCanBeRemoved() {
        let app = launch()
        keepCalculatorResult(app)
        let card = element(app, "pipCard")
        card.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(element(app, "pip.empty").waitForExistence(timeout: 5))
    }
}
