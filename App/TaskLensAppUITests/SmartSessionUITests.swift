import XCTest

/// Smart sessions on the real app: create, capture, search, sort, rename,
/// favorite, archive, Resume, persistence and delete.
final class SmartSessionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func makeApp(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-TaskLensUITestStore"]
        if reset { app.launchArguments.append("-TaskLensResetStore") }
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openWorkspace(_ app: XCUIApplication, name: String, create: Bool) {
        let tab = app.tabBars.buttons["Workspaces"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        if create {
            element(app, "workspaces.add").tap()
            let field = element(app, "workspaceEditor.name")
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(name)
            element(app, "workspaceEditor.save").tap()
        }
        let row = element(app, "workspaceRow.\(name)")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    /// Rows are buttons, so their text is part of a combined label.
    private func text(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func startSession(_ app: XCUIApplication) {
        let start = element(app, "workspaceDetail.startSession")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(element(app, "session.menu").waitForExistence(timeout: 10)
                      || element(app, "quickCapture.field").waitForExistence(timeout: 2), "Session should open")
    }

    private func capture(_ app: XCUIApplication, _ value: String) {
        let field = element(app, "quickCapture.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(value)
        element(app, "quickCapture.save").tap()
        XCTAssertTrue(text(app, value).waitForExistence(timeout: 5), "\(value) should be in the session")
    }

    private func sessionMenu(_ app: XCUIApplication, _ identifier: String, fallbackLabel: String) {
        let menu = element(app, "session.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let item = element(app, identifier)
        if item.waitForExistence(timeout: 3) {
            item.tap()
        } else {
            app.buttons[fallbackLabel].firstMatch.tap()
        }
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.count > 0 {
            app.navigationBars.firstMatch.tap()
        }
    }

    // MARK: Tests

    func testSessionWorkflowAndResume() {
        let app = makeApp(reset: true)
        app.launch()
        openWorkspace(app, name: "Trip", create: true)
        startSession(app)

        capture(app, "Hotel booking 120")
        capture(app, "What time is check in?")
        dismissKeyboard(app)

        // Sort by type groups questions apart.
        let sort = element(app, "session.sort")
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        sort.buttons["Type"].tap()
        XCTAssertTrue(element(app, "session.group.question").waitForExistence(timeout: 5))
        sort.buttons["Recent"].tap()

        // Search inside the session.
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 2) { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("hotel")
        XCTAssertTrue(text(app, "Hotel booking 120").waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, "What time is check in?").waitForNonExistence(timeout: 5))
        // iOS 26 search fields have no Cancel button: clear the text instead.
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "hotel".count))
        XCTAssertTrue(text(app, "What time is check in?").waitForExistence(timeout: 5))

        // Rename.
        sessionMenu(app, "session.rename", fallbackLabel: "Rename")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeText("Hotels")
        alert.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Hotels"].waitForExistence(timeout: 5))

        // Favorite, then archive: Resume appears.
        sessionMenu(app, "session.favorite", fallbackLabel: "Add to Favorites")
        sessionMenu(app, "session.archive", fallbackLabel: "Archive")
        let resume = element(app, "session.resume")
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "An archived session offers Resume")
        XCTAssertFalse(element(app, "quickCapture.field").exists, "An archived session takes no new items")

        // Resume brings back the session and its recent context.
        resume.tap()
        XCTAssertTrue(element(app, "session.pickUp").waitForExistence(timeout: 5)
                      || text(app, "Pick Up Where You Left Off").waitForExistence(timeout: 2))
        XCTAssertTrue(element(app, "quickCapture.field").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "session.resume").exists)
    }

    func testSessionPersistsAcrossRelaunchAndCanBeDeleted() {
        let app = makeApp(reset: true)
        app.launch()
        openWorkspace(app, name: "Study", create: true)
        startSession(app)
        capture(app, "Chapter 3 summary")
        dismissKeyboard(app)
        sessionMenu(app, "session.rename", fallbackLabel: "Rename")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("Exam")
        alert.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Exam"].waitForExistence(timeout: 5))
        app.terminate()

        let relaunched = makeApp(reset: false)
        relaunched.launch()
        openWorkspace(relaunched, name: "Study", create: false)
        let row = element(relaunched, "sessionRow")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The session should survive a relaunch")
        row.tap()
        XCTAssertTrue(relaunched.navigationBars["Exam"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(relaunched, "Chapter 3 summary").waitForExistence(timeout: 5))

        sessionMenu(relaunched, "session.delete", fallbackLabel: "Delete Session")
        let confirm = relaunched.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete must ask for confirmation")
        confirm.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(element(relaunched, "sessionRow").waitForNonExistence(timeout: 5))
    }
}
