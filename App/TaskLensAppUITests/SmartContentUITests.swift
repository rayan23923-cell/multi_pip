import UIKit
import XCTest

/// Phase 5: Lens and Smart Clipboard analysis, suggested actions, and the
/// share sheet (driven in-app through the share harness, plus the real
/// extension from Safari when the system share sheet can be reached).
final class SmartContentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(language: String = "en", locale: String = "en_US", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "-TaskLensUITestStore", "-TaskLensResetStore"] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 10) {
        let target = element(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(identifier) not found")
        if !target.isHittable { scrollTo(app, target) }
        target.tap()
    }

    private func scrollTo(_ app: XCUIApplication, _ target: XCUIElement) {
        for _ in 0..<8 where !target.isHittable {
            app.swipeUp()
        }
    }

    /// Lists are lazy: rows below the fold do not exist until scrolled to.
    private func scrollUntilExists(_ app: XCUIApplication, _ identifier: String) {
        let target = element(app, identifier)
        for _ in 0..<10 where !target.exists {
            app.swipeUp()
        }
        XCTAssertTrue(target.waitForExistence(timeout: 3), "\(identifier) not found after scrolling")
    }

    private func waitForLabel(_ app: XCUIApplication, _ identifier: String, containing expected: String, timeout: TimeInterval = 10) {
        let target = element(app, identifier)
        let predicate = NSPredicate(format: "label CONTAINS %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: target)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
                       "\(identifier) label is '\(target.label)', expected to contain '\(expected)'")
    }

    private func analyzeInLens(_ app: XCUIApplication, _ text: String) {
        tap(app, "commandCenter.lens")
        let input = element(app, "lens.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(text)
        tap(app, "lens.analyze")
    }

    private func dismissAlert(_ app: XCUIApplication, expecting text: String) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Expected an alert")
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists,
                      "Alert should mention '\(text)'")
        alert.buttons.firstMatch.tap()
    }

    // MARK: Lens

    func testLensDetectsPhoneAndSuggestsCallMessageSave() {
        let app = launch()
        analyzeInLens(app, "+964 770 123 4567")
        waitForLabel(app, "lens.detectedType", containing: "Phone Number")
        XCTAssertTrue(element(app, "action.call").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "action.sendMessage").exists)
        tap(app, "action.saveToSession")
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 5))
    }

    func testLensDatePlaceholdersSayComingLater() {
        let app = launch()
        analyzeInLens(app, "2026-10-05")
        waitForLabel(app, "lens.detectedType", containing: "Date")
        tap(app, "action.createReminder")
        dismissAlert(app, expecting: "later update")
        XCTAssertTrue(element(app, "action.addToCalendar").exists)
    }

    func testLensNumberOpensCalculatorWithValue() {
        let app = launch()
        analyzeInLens(app, "1,250")
        waitForLabel(app, "lens.detectedType", containing: "Number")
        tap(app, "action.calculate")
        waitForLabel(app, "calculator.display", containing: "1250")
    }

    func testLensTextAndUnknownContent() {
        let app = launch()
        analyzeInLens(app, "Meet the design team about the new layout")
        waitForLabel(app, "lens.detectedType", containing: "Text")
        XCTAssertTrue(element(app, "action.translate").waitForExistence(timeout: 5))
        // Summarize is not built yet, so it waits behind More.
        XCTAssertFalse(element(app, "action.summarize").exists)
        tap(app, "actions.more")
        tap(app, "action.summarize")
        dismissAlert(app, expecting: "later update")
    }

    // MARK: Action card

    func testActionCardRecommendsThreeAndKeepsTheRestUnderMore() {
        let app = launch()
        analyzeInLens(app, "$125")
        waitForLabel(app, "lens.detectedType", containing: "Amount of Money")
        waitForLabel(app, "analysis.value", containing: "125")
        XCTAssertTrue(element(app, "action.convertCurrency").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "action.calculate").exists)
        XCTAssertTrue(element(app, "action.saveToSession").exists)
        XCTAssertFalse(element(app, "action.copy").exists)
        tap(app, "actions.more")
        XCTAssertTrue(element(app, "action.copy").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "action.share").exists)
    }

    func testCreateNoteFromLensOpensTheEditorWithTheText() {
        let app = launch()
        analyzeInLens(app, "Buy milk and eggs on the way home")
        tap(app, "action.createNote")
        let body = element(app, "noteEditor.body")
        XCTAssertTrue(body.waitForExistence(timeout: 10), "Note editor did not open")
        XCTAssertTrue((body.value as? String ?? "").contains("Buy milk"), "Body is '\(body.value ?? "")'")
        tap(app, "noteEditor.save")
        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Buy milk")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "Saved note not listed")
    }

    func testSearchFromLensSearchesSavedContent() {
        let app = launch()
        analyzeInLens(app, "Quarterly budget review")
        tap(app, "action.search")
        let shown = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Quarterly budget review", "Quarterly budget review"))
            .firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 10), "Command Center is not searching for the text")
        XCTAssertFalse(element(app, "lens.input").exists)
    }

    func testCalendarActionOpensTheSystemEditor() {
        let app = launch()
        analyzeInLens(app, "2026-10-05")
        tap(app, "action.addToCalendar")
        // The editor runs outside the app; the app must stay up and get its screen back on Cancel.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 10) { cancel.tap() }
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(element(app, "lens.detectedType").waitForExistence(timeout: 10))
    }

    func testLensInArabic() {
        let app = launch(language: "ar", locale: "ar_IQ")
        analyzeInLens(app, "0770 123 4567")
        waitForLabel(app, "lens.detectedType", containing: "رقم هاتف")
        XCTAssertTrue(element(app, "action.call").waitForExistence(timeout: 5))
    }

    // MARK: Smart Clipboard

    func testClipboardPasteShowsAnalysis() throws {
        UIPasteboard.general.string = "https://example.com/offer"
        let app = launch()
        tap(app, "commandCenter.clipboard")

        let paste = app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "System Paste button missing")
        paste.tap()
        // A synthesized tap may still be treated as a paste request on some systems.
        let allow = app.alerts.buttons["Allow Paste"].firstMatch
        if allow.waitForExistence(timeout: 2) { allow.tap() }

        let detail = element(app, "clipboardDetail.done")
        guard detail.waitForExistence(timeout: 10) else {
            throw XCTSkip("The system did not deliver pasteboard content to the Paste button in this environment")
        }
        waitForLabel(app, "analysis.detectedType", containing: "Link")
        XCTAssertTrue(element(app, "action.openURL").exists)
        detail.tap()
        XCTAssertTrue(element(app, "clipboardRow.url").waitForExistence(timeout: 5))
    }

    // MARK: Share sheet

    func testShareSheetShowsEachItemAndSavesSupportedOnes() {
        let app = launch(extra: ["-TaskLensShareHarness"])
        waitForLabel(app, "share.item.0.type", containing: "Phone Number", timeout: 20)
        waitForLabel(app, "share.item.1.type", containing: "Link")

        // In the extension, actions that leave the app point to TaskLens instead.
        tap(app, "action.call")
        dismissAlert(app, expecting: "Open TaskLens")

        scrollUntilExists(app, "share.item.2.type")
        waitForLabel(app, "share.item.2.type", containing: "PDF")
        scrollUntilExists(app, "share.item.3.type")
        waitForLabel(app, "share.item.3.type", containing: "Image")
        scrollUntilExists(app, "share.item.4.unsupported")
        waitForLabel(app, "share.item.4.unsupported", containing: "Not Supported")

        tap(app, "share.save")
        // Four supported items reach the outbox, then the app saves all four.
        waitForLabel(app, "harness.outcome", containing: "saved 4 delivered 4", timeout: 20)
    }

    func testShareSheetCancel() {
        let app = launch(extra: ["-TaskLensShareHarness"])
        XCTAssertTrue(element(app, "share.item.0.type").waitForExistence(timeout: 20))
        tap(app, "share.cancel")
        waitForLabel(app, "harness.outcome", containing: "cancelled")
    }

    func testShareSheetInArabic() {
        let app = launch(language: "ar", locale: "ar_IQ", extra: ["-TaskLensShareHarness"])
        waitForLabel(app, "share.item.0.type", containing: "رقم هاتف", timeout: 20)
        XCTAssertTrue(app.buttons["إلغاء"].exists)
        XCTAssertTrue(app.buttons["حفظ"].exists)
    }

    /// The real extension process, opened from Safari's share sheet. System UI
    /// changes between iOS versions, so the test skips (not fails) when it
    /// cannot find Safari's share sheet or the TaskLens entry in it.
    func testRealShareExtensionFromSafari() throws {
        // Install and register the app (and its extension) first.
        let app = launch()
        XCTAssertTrue(element(app, "commandCenter.lens").waitForExistence(timeout: 10))
        app.terminate()

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        XCUIDevice.shared.system.open(URL(string: "https://example.com")!)
        _ = safari.wait(for: .runningForeground, timeout: 10)

        var share = safari.buttons["ShareButton"].firstMatch
        if !share.waitForExistence(timeout: 10) {
            let more = safari.buttons.matching(NSPredicate(format: "label == 'More' OR identifier == 'MoreButton'")).firstMatch
            if more.waitForExistence(timeout: 3) { more.tap() }
            share = safari.buttons.matching(NSPredicate(format: "label == 'Share' OR identifier == 'ShareButton'")).firstMatch
        }
        guard share.waitForExistence(timeout: 5) else { throw XCTSkip("Safari share button not found") }
        share.tap()

        let entry = safari.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'TaskLens'")).firstMatch
        if !entry.waitForExistence(timeout: 5) {
            // Newly installed extensions can sit at the end of the app row.
            safari.collectionViews.firstMatch.swipeLeft()
        }
        guard entry.waitForExistence(timeout: 5) else { throw XCTSkip("TaskLens not listed in Safari's share sheet") }
        entry.tap()

        // The extension's own UI, running in its own process inside Safari's sheet.
        let typeRow = safari.descendants(matching: .any).matching(identifier: "share.item.0.type").firstMatch
        XCTAssertTrue(typeRow.waitForExistence(timeout: 20), "Share extension UI did not appear")
        XCTAssertTrue(typeRow.label.contains("Link"), "Shared page should be a link, got '\(typeRow.label)'")
        let save = safari.descendants(matching: .any).matching(identifier: "share.save").firstMatch
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(typeRow.waitForNonExistence(timeout: 15), "Extension should close after saving")
    }
}
