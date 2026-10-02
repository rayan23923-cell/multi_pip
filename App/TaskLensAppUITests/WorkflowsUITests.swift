import XCTest

/// Workflows on the real app: create, run, duplicate, turn off, delete, and
/// the confirmation an AI workflow asks for.
final class WorkflowsUITests: XCTestCase {
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

    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 10) {
        let target = element(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(identifier) not found")
        target.tap()
    }

    private func openWorkflows(_ app: XCUIApplication) {
        tap(app, "commandCenter.workflows")
        XCTAssertTrue(element(app, "workflows.empty").waitForExistence(timeout: 5))
    }

    func testCreateRunDuplicateAndDelete() {
        let app = launch()
        openWorkflows(app)

        tap(app, "workflows.add")
        tap(app, "workflows.new")
        let name = element(app, "workflowEditor.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        // Return closes the keyboard, which would cover Add Step.
        name.typeText("Keep text\n")
        // The first tap can land while the keyboard is closing; try again
        // until the step menu is open. Menu items can come without their
        // identifiers or as menu items rather than buttons, so match labels too.
        let saveStep = element(app, "workflowEditor.add.save")
        let ocrStep = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Read text (OCR)'")).firstMatch
        let addStep = element(app, "workflowEditor.addStep")
        for attempt in 0..<3 {
            XCTAssertTrue(addStep.waitForExistence(timeout: 5))
            if attempt == 0 {
                addStep.tap()
            } else {
                // Near the leading edge, on the label's text.
                addStep.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            }
            if saveStep.waitForExistence(timeout: 3) || ocrStep.exists { break }
            print("MISSING step menu — attempt \(attempt), addStep hittable \(addStep.isHittable) frame \(addStep.frame), menus \(app.menus.count) menuItems \(app.menuItems.count) keyboards \(app.keyboards.count)")
        }
        if saveStep.exists {
            saveStep.tap()
        } else {
            app.printScreen(missing: "workflowEditor.add.save")
            XCTAssertTrue(ocrStep.exists, "The step menu did not open")
            // The menu's Save step, not the editor's Save button.
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Save' AND identifier != 'workflowEditor.save'"))
                .firstMatch.tap()
        }
        tap(app, "workflowEditor.save")

        let row = element(app, "workflows.row.Keep text")
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // Run it on typed text.
        row.staticTexts["Keep text"].tap()
        let input = element(app, "workflows.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Remember the milk")
        tap(app, "workflows.runButton")
        XCTAssertTrue(element(app, "workflows.result.saved").waitForExistence(timeout: 10))
        app.navigationBars.buttons["Done"].firstMatch.tap()

        // Duplicate from the context menu: the copy starts turned off.
        row.press(forDuration: 1.2)
        tap(app, "workflows.duplicate")
        XCTAssertTrue(element(app, "workflows.row.Keep text copy").waitForExistence(timeout: 5))

        // Delete the original.
        row.press(forDuration: 1.2)
        tap(app, "workflows.delete")
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    func testAIWorkflowAsksBeforeRunning() {
        let app = launch()
        openWorkflows(app)
        tap(app, "workflows.add")
        tap(app, "workflows.template.1")

        let row = element(app, "workflows.row.Summarize a link")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.staticTexts["Summarize a link"].tap()
        let input = element(app, "workflows.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("https://swift.org")
        tap(app, "workflows.runButton")

        // Nothing runs until the user confirms.
        let confirm = element(app, "workflows.confirmRun")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "workflows.result.step").exists)
        confirm.tap()
        XCTAssertTrue(element(app, "workflows.result.step").waitForExistence(timeout: 10))
    }
}
