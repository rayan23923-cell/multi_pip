import XCTest

/// Phase 18 end-to-end scenarios that no other suite covers in one flow.
/// Each test name starts with its scenario number from the QA report.
final class FinalQAUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func makeApp(reset: Bool = true, language: String = "en", locale: String = "en_US", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-TaskLensUITestStore"] + extra
        if reset { app.launchArguments.append("-TaskLensResetStore") }
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func text(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 10) {
        let target = element(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(identifier) not found")
        target.tap()
    }

    private func waitForLabel(_ app: XCUIApplication, _ identifier: String, containing expected: String, timeout: TimeInterval = 10) {
        let target = element(app, identifier)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", expected), object: target)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
                       "\(identifier) label is '\(target.label)', expected '\(expected)'")
    }

    private func openWorkspace(_ app: XCUIApplication, name: String, create: Bool) {
        let tab = app.tabBars.buttons.element(boundBy: 1)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        if create {
            tap(app, "workspaces.add")
            let field = element(app, "workspaceEditor.name")
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(name)
            tap(app, "workspaceEditor.save")
        }
        tap(app, "workspaceRow.\(name)")
    }

    private func startSession(_ app: XCUIApplication) {
        tap(app, "workspaceDetail.startSession")
        XCTAssertTrue(element(app, "quickCapture.field").waitForExistence(timeout: 10), "Session should open")
    }

    private func capture(_ app: XCUIApplication, _ value: String) {
        let field = element(app, "quickCapture.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(value)
        tap(app, "quickCapture.save")
        XCTAssertTrue(text(app, value).waitForExistence(timeout: 5), "\(value) should be in the session")
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.count > 0 { app.navigationBars.firstMatch.tap() }
    }

    private func analyzeInLens(_ app: XCUIApplication, _ value: String) {
        tap(app, "commandCenter.lens")
        let input = element(app, "lens.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(value)
        tap(app, "lens.analyze")
    }

    // MARK: Scenario 3: price → detect → convert → calculate → save

    func testQA03CurrencyDetectConvertCalculateSave() {
        let app = makeApp()
        app.launch()
        // An active session receives what the calculator saves.
        openWorkspace(app, name: "Trip", create: true)
        startSession(app)
        dismissKeyboard(app)

        app.tabBars.buttons.element(boundBy: 0).tap()
        analyzeInLens(app, "$25")
        waitForLabel(app, "lens.detectedType", containing: "Money")
        tap(app, "action.convertCurrency")

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Convert asks for the user's rate")
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'USD'")).firstMatch.exists)
        let rate = alert.textFields.firstMatch
        rate.tap()
        rate.typeText("1310")
        alert.buttons["Convert"].tap()
        waitForLabel(app, "calculator.display", containing: "32750")

        for key in ["multiply", "2", "equals"] { tap(app, "calculator.key.\(key)", timeout: 3) }
        waitForLabel(app, "calculator.display", containing: "65500")
        tap(app, "calculator.menu")
        // Menu items lose identifiers on some iOS versions; fall back to the label.
        let save = element(app, "calculator.save")
        if save.waitForExistence(timeout: 3) { save.tap() } else { app.buttons["Save to Session"].firstMatch.tap() }
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 5))

        // The result is in the session.
        app.tabBars.buttons.element(boundBy: 1).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app, "sessionRow")
        XCTAssertTrue(text(app, "65500").waitForExistence(timeout: 5)
                      || text(app, "65,500").waitForExistence(timeout: 2), "The saved calculation should be in the session")
    }

    func testQA03InvalidRateIsExplained() {
        let app = makeApp()
        app.launch()
        analyzeInLens(app, "€40")
        tap(app, "action.convertCurrency")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("0")
        alert.buttons["Convert"].tap()
        XCTAssertTrue(text(app, "rate above zero").waitForExistence(timeout: 5), "A zero rate must be refused, not guessed")
    }

    // MARK: Scenarios 6, 8 and 15: research session, background, termination, resume

    func testQA06ResearchSessionSurvivesBackgroundAndTermination() {
        let app = makeApp()
        app.launch()
        openWorkspace(app, name: "Research", create: true)
        startSession(app)
        capture(app, "https://developer.apple.com/documentation/vision")
        capture(app, "+964 770 123 4567")
        capture(app, "Read chapter 4 before Monday")
        dismissKeyboard(app)

        // Background and back (Live Activities start and update here).
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        app.activate()
        XCTAssertTrue(element(app, "quickCapture.field").waitForExistence(timeout: 10), "The session is still open after the background")
        XCTAssertTrue(text(app, "Read chapter 4").exists)

        // The system ends the app; everything is on disk.
        app.terminate()
        let relaunched = makeApp(reset: false)
        relaunched.launch()
        openWorkspace(relaunched, name: "Research", create: false)
        tap(relaunched, "sessionRow")
        XCTAssertTrue(text(relaunched, "developer.apple.com").waitForExistence(timeout: 5))
        XCTAssertTrue(text(relaunched, "770").exists)
        XCTAssertTrue(text(relaunched, "Read chapter 4").exists)
        XCTAssertTrue(element(relaunched, "quickCapture.field").exists, "The session is still active and takes new items")
    }

    // MARK: Scenario 13: dark mode

    func testQA13DarkModeMainScreens() {
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        let app = makeApp()
        app.launch()
        XCTAssertTrue(element(app, "commandCenter.lens").waitForExistence(timeout: 10))
        auditContrast(app, "dark Command Center")

        analyzeInLens(app, "+964 770 123 4567")
        XCTAssertTrue(element(app, "action.call").waitForExistence(timeout: 5))
        auditContrast(app, "dark Lens")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.tabBars.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(element(app, "settings.deleteAll").waitForExistence(timeout: 5))
        auditContrast(app, "dark Settings")
    }

    /// Unlabeled elements fail; contrast findings are listed for the report.
    private func auditContrast(_ app: XCUIApplication, _ screen: String) {
        do {
            try app.performAccessibilityAudit(for: [.contrast, .sufficientElementDescription]) { issue in
                let line = "[\(screen)] \(issue.compactDescription) — \(issue.element?.identifier ?? "") \(issue.element?.label ?? "")"
                if issue.auditType == .sufficientElementDescription {
                    print("AUDIT FAIL " + line)
                    return false
                }
                print("AUDIT NOTE " + line)
                return true
            }
        } catch {
            XCTFail("Audit failed on \(screen): \(error)")
        }
    }

    // MARK: Scenario 14: low memory

    func testQA14MemoryWarningKeepsDataAndSearch() {
        let app = makeApp()
        app.launch()
        tap(app, "commandCenter.notes")
        tap(app, "notes.new")
        let title = element(app, "noteEditor.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Flutter state notes")
        tap(app, "noteEditor.save")
        XCTAssertTrue(element(app, "noteRow.Flutter state notes").waitForExistence(timeout: 5))
        app.terminate()

        // iOS's low-memory notification arrives right after launch.
        let warned = makeApp(reset: false, extra: ["-TaskLensMemoryWarning"])
        warned.launch()
        XCTAssertTrue(element(warned, "commandCenter.lens").waitForExistence(timeout: 10))
        sleep(2)
        XCTAssertEqual(warned.state, .runningForeground, "The app must survive a memory warning")

        let search = warned.searchFields.firstMatch
        if !search.waitForExistence(timeout: 2) { warned.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("flutter")
        XCTAssertTrue(element(warned, "search.hit").waitForExistence(timeout: 10), "Search works after caches were dropped")
    }
}
