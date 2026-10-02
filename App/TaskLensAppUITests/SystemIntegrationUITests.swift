import XCTest

/// tasklens:// links, as widgets, App Shortcuts and Live Activities open them.
final class SystemIntegrationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-TaskLensUITestStore", "-TaskLensResetStore"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testDeepLinksOpenTools() throws {
        let app = launch()

        app.open(try XCTUnwrap(URL(string: "tasklens://clipboard")))
        XCTAssertTrue(element(app, "clipboard.paste").waitForExistence(timeout: 10), "Clipboard did not open")

        app.open(try XCTUnwrap(URL(string: "tasklens://calculator")))
        XCTAssertTrue(element(app, "calculator.display").waitForExistence(timeout: 10), "Calculator did not open")

        app.open(try XCTUnwrap(URL(string: "tasklens://notes")))
        XCTAssertTrue(element(app, "notes.new").waitForExistence(timeout: 10), "Notes did not open")
    }

    func testSendToTaskLensLinkAnalyzesText() throws {
        let app = launch()
        app.open(try XCTUnwrap(URL(string: "tasklens://lens?text=https%3A%2F%2Fapple.com")))
        let input = element(app, "lens.input")
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Lens did not open")
        XCTAssertEqual(input.value as? String, "https://apple.com")
        XCTAssertTrue(element(app, "lens.detectedType").waitForExistence(timeout: 5), "Lens did not analyze the text")
    }

    func testUnknownLinksKeepTheCurrentScreen() throws {
        let app = launch()
        app.open(try XCTUnwrap(URL(string: "tasklens://calculator")))
        XCTAssertTrue(element(app, "calculator.display").waitForExistence(timeout: 10))

        // Through the system, as a tapped link arrives. (XCUIApplication.open
        // can start the app again with the link, which resets the screen.)
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "tasklens://session/not-a-session")))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirm = springboard.buttons["Open"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let kept = element(app, "calculator.display").waitForExistence(timeout: 5)
        if !kept { app.printScreen(missing: "calculator.display after an invalid link (state \(app.state.rawValue))") }
        XCTAssertTrue(kept, "An invalid link changed the screen")
    }
}
