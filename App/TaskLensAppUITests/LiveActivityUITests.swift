import XCTest

/// The session controls behind the Live Activity. The Live Activity itself is
/// drawn by iOS on the Lock Screen / Dynamic Island, which XCUITest cannot
/// inspect; its logic is covered by the package tests.
final class LiveActivityUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Menu items lose identifiers on some iOS versions; fall back to the label.
    private func tapMenuItem(_ app: XCUIApplication, _ identifier: String, label: String) {
        let item = element(app, identifier)
        if item.waitForExistence(timeout: 3) {
            item.tap()
        } else {
            let byLabel = app.buttons[label].firstMatch
            XCTAssertTrue(byLabel.waitForExistence(timeout: 3), "\(label) not found")
            byLabel.tap()
        }
    }

    private func menuItemExists(_ app: XCUIApplication, _ identifier: String, label: String) -> Bool {
        element(app, identifier).waitForExistence(timeout: 2) || app.buttons[label].firstMatch.waitForExistence(timeout: 1)
    }

    func testFocusTimerStartsAndStopsAndTheAppKeepsWorking() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-TaskLensUITestStore", "-TaskLensResetStore"]
        app.launch()

        let tab = app.tabBars.buttons["Workspaces"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        element(app, "workspaces.add").tap()
        let field = element(app, "workspaceEditor.name")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Focus")
        element(app, "workspaceEditor.save").tap()
        let row = element(app, "workspaceRow.Focus")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let start = element(app, "workspaceDetail.startSession")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let menu = element(app, "session.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Session should open")

        menu.tap()
        tapMenuItem(app, "session.focus", label: "Focus Timer")
        tapMenuItem(app, "session.focus.25", label: "25 minutes")

        menu.tap()
        tapMenuItem(app, "session.focus", label: "Focus Timer")
        XCTAssertTrue(menuItemExists(app, "session.focus.stop", label: "Stop Focus Timer"), "Focus timer should be running")
        tapMenuItem(app, "session.focus.stop", label: "Stop Focus Timer")

        menu.tap()
        tapMenuItem(app, "session.focus", label: "Focus Timer")
        XCTAssertFalse(menuItemExists(app, "session.focus.stop", label: "Stop Focus Timer"), "Focus timer should be stopped")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()

        // Going to the background and back (where Live Activities start and
        // update) leaves the session usable.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(element(app, "session.menu").waitForExistence(timeout: 10))
    }
}
