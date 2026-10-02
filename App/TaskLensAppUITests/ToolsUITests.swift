import XCTest

/// End-to-end flows for the productivity tools, against an isolated test store.
final class ToolsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(language: String = "en", locale: String = "en_US", seedDocuments: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "-TaskLensUITestStore", "-TaskLensResetStore"]
        if seedDocuments { app.launchArguments.append("-TaskLensSeedDocuments") }
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

    private func press(_ app: XCUIApplication, keys: [String]) {
        for key in keys { tap(app, "calculator.key.\(key)", timeout: 3) }
    }

    private func label(_ app: XCUIApplication, _ identifier: String) -> String {
        let target = element(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(identifier) not found")
        return target.label
    }

    private func waitForLabel(_ app: XCUIApplication, _ identifier: String, _ expected: String, timeout: TimeInterval = 5) {
        let target = element(app, identifier)
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: target)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
                       "\(identifier) label is '\(target.label)', expected '\(expected)'")
    }

    private func createNote(_ app: XCUIApplication, title: String, body: String) {
        tap(app, "notes.new")
        let titleField = element(app, "noteEditor.title")
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        let bodyField = element(app, "noteEditor.body")
        bodyField.tap()
        bodyField.typeText(body)
        tap(app, "noteEditor.save")
        XCTAssertTrue(element(app, "noteRow.\(title)").waitForExistence(timeout: 5), "Note \(title) missing")
    }

    // MARK: Notes

    func testNotesCreateSearchPinAndDelete() {
        let app = launch()
        tap(app, "commandCenter.notes")
        createNote(app, title: "Groceries", body: "Milk and eggs")
        createNote(app, title: "Meeting", body: "Budget review")

        // Search matches the body.
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 2) {
            app.swipeDown()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("eggs")
        XCTAssertTrue(element(app, "noteRow.Groceries").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "noteRow.Meeting").waitForNonExistence(timeout: 5))
        // iOS 26 search bars may have no "Cancel" button; clearing the text ends the search either way.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
        } else {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "\n")
        }

        // Pin from the context menu.
        let meeting = element(app, "noteRow.Meeting")
        XCTAssertTrue(meeting.waitForExistence(timeout: 5))
        meeting.press(forDuration: 1.2)
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        XCTAssertTrue(app.staticTexts["Pinned"].firstMatch.waitForExistence(timeout: 5)
                      || app.staticTexts["PINNED"].firstMatch.waitForExistence(timeout: 2))

        // Delete asks for confirmation.
        let groceries = element(app, "noteRow.Groceries")
        groceries.press(forDuration: 1.2)
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(element(app, "noteRow.Groceries").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, "noteRow.Meeting").exists)
    }

    // MARK: Calculator

    func testCalculatorComputesPercentAndKeepsHistory() {
        let app = launch()
        tap(app, "commandCenter.calculator")
        press(app, keys: ["1", "2", "add", "3", "0", "equals"])
        waitForLabel(app, "calculator.display", "42")

        press(app, keys: ["clear", "5", "0", "add", "1", "0", "percent", "equals"])
        waitForLabel(app, "calculator.display", "55")

        press(app, keys: ["clear", "8", "divide", "0", "equals"])
        waitForLabel(app, "calculator.display", "Cannot divide by zero")

        tap(app, "calculator.history")
        let rows = app.descendants(matching: .any).matching(identifier: "calculator.historyRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2)
        rows.firstMatch.tap()
        waitForLabel(app, "calculator.display", "55")
    }

    // MARK: Browser

    func testBrowserValidatesAddressAndManagesTabs() {
        let app = launch()
        tap(app, "commandCenter.browser")
        let address = element(app, "browser.address")
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("not a site\n")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Invalid address must be reported")
        alert.buttons.firstMatch.tap()

        address.tap()
        tap(app, "browser.clear", timeout: 3)
        address.typeText("example.com\n")
        // The web view may report the loaded page with a trailing slash.
        let predicate = NSPredicate(format: "value BEGINSWITH %@", "https://example.com")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: address)], timeout: 10), .completed,
                       "Address is '\(address.value as? String ?? "nil")', alert shown: \(app.alerts.firstMatch.exists)")

        tap(app, "browser.tabs")
        tap(app, "browser.newTab")
        XCTAssertEqual(element(app, "browser.tabs").value as? String, "2")
    }

    // MARK: Documents

    func testDocumentViewersOpenSearchAndPage() {
        let app = launch(seedDocuments: true)
        tap(app, "commandCenter.documents")

        tap(app, "documentRow.Sample Report")
        waitForLabel(app, "pdf.pageLabel", "Page 1 of 3", timeout: 10)
        tap(app, "pdf.nextPage")
        waitForLabel(app, "pdf.pageLabel", "Page 2 of 3")
        tap(app, "pdf.previousPage")
        waitForLabel(app, "pdf.pageLabel", "Page 1 of 3")

        tap(app, "pdf.search")
        let field = element(app, "pdf.searchField")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("invoice\n")
        waitForLabel(app, "pdf.matchLabel", "1 of 1")
        waitForLabel(app, "pdf.pageLabel", "Page 2 of 3")
        app.navigationBars.buttons.firstMatch.tap()

        tap(app, "documentRow.Sample Notes")
        let text = element(app, "text.content")
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(text.label.contains("budget review"))
        app.navigationBars.buttons.firstMatch.tap()

        tap(app, "documentRow.Sample Image")
        XCTAssertTrue(element(app, "image.view").waitForExistence(timeout: 10))
        tap(app, "image.recognizeText")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "OCR entry point explains it comes later")
        app.alerts.firstMatch.buttons.firstMatch.tap()
    }

    // MARK: Localization

    func testArabicToolsKeepCalculatorLeftToRight() {
        let app = launch(language: "ar", locale: "ar_SA")
        let calculator = element(app, "commandCenter.calculator")
        XCTAssertTrue(calculator.waitForExistence(timeout: 10))
        XCTAssertEqual(calculator.label, "الآلة الحاسبة")
        XCTAssertEqual(element(app, "commandCenter.notes").label, "الملاحظات")
        calculator.tap()

        let seven = element(app, "calculator.key.7")
        let nine = element(app, "calculator.key.9")
        XCTAssertTrue(seven.waitForExistence(timeout: 5))
        XCTAssertLessThan(seven.frame.midX, nine.frame.midX, "Keypad stays left to right in Arabic")
        press(app, keys: ["9", "multiply", "7", "equals"])
        waitForLabel(app, "calculator.display", "63")
        XCTAssertTrue(app.navigationBars["الآلة الحاسبة"].exists)
    }
}
