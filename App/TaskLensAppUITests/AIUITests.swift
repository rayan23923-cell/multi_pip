import XCTest

/// Optional AI in Lens: unavailable on this simulator by default (Lens still
/// works), a stand-in on-device provider for the full flow, and offline.
final class AIUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-TaskLensUITestStore", "-TaskLensResetStore"] + extra
        app.launch()
        return app
    }

    private func openLens(_ app: XCUIApplication, text: String) {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        app.open(URL(string: "tasklens://lens?text=\(encoded)")!)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func reveal(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 10) -> XCUIElement {
        let target = element(app, identifier)
        var swipes = 0
        while !(target.exists && target.isHittable) && swipes < 8 {
            if target.waitForExistence(timeout: swipes == 0 ? timeout : 1), target.isHittable { break }
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(target.exists, "\(identifier) not found")
        return target
    }

    func testWithoutAILensStillWorks() {
        let app = launch()
        openLens(app, text: "Call 0771 234 5678")
        // Deterministic actions come first and don't depend on AI.
        XCTAssertTrue(element(app, "action.call").waitForExistence(timeout: 10))
        // This simulator has no Apple Intelligence and no server is set up.
        XCTAssertTrue(reveal(app, "ai.unavailable").exists)
        XCTAssertFalse(element(app, "ai.send").exists)
    }

    func testSendShowsDisclosureAnswerAndAsksBeforeSensitiveActions() {
        let app = launch(["-TaskLensAIFake"])
        openLens(app, text: "Meeting with Sara tomorrow")
        XCTAssertTrue(reveal(app, "ai.disclosure").label.contains("characters"))
        reveal(app, "ai.send").tap()
        let answer = reveal(app, "ai.answer")
        XCTAssertTrue(answer.label.contains("Summary"), "Answer: \(answer.label)")
        // Nothing ran on its own; the AI's Create Note suggestion is offered.
        XCTAssertTrue(reveal(app, "action.createNote").exists)

        reveal(app, "ai.clear").tap()
        XCTAssertFalse(element(app, "ai.answer").waitForExistence(timeout: 2))
    }

    func testOfflineOffersRetryAndKeepsActions() {
        let app = launch(["-TaskLensAIOffline"])
        openLens(app, text: "https://example.com/flutter")
        XCTAssertTrue(element(app, "action.openURL").waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(app, "ai.unavailable").label.contains("internet"))
        reveal(app, "ai.retry").tap()
        XCTAssertTrue(reveal(app, "ai.unavailable").exists)
    }

    func testSettingsShowPrivacyAndDeleteHistory() {
        let app = launch(["-TaskLensAIFake"])
        openLens(app, text: "Exam on Monday")
        reveal(app, "ai.send").tap()
        XCTAssertTrue(reveal(app, "ai.answer").exists)

        app.tabBars.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(reveal(app, "ai.settings.enabled").exists)
        let delete = reveal(app, "ai.history.delete")
        XCTAssertTrue(delete.isEnabled, "One request is in history")
        delete.tap()
        let confirm = element(app, "ai.history.deleteConfirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == false"),
                                                 object: element(app, "ai.history.delete"))
        XCTAssertEqual(XCTWaiter().wait(for: [disabled], timeout: 5), .completed, "History should be empty")
    }
}
