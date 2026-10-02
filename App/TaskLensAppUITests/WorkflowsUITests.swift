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
        // until the step menu is open.
        let saveStep = element(app, "workflowEditor.add.save")
        let ocrStep = app.buttons["Read text (OCR)"].firstMatch
        for _ in 0..<3 {
            tap(app, "workflowEditor.addStep")
            if saveStep.waitForExistence(timeout: 3) || ocrStep.exists { break }
        }
        if saveStep.exists {
            saveStep.tap()
        } else {
            // Menu items lose identifiers on some iOS versions; the step list
            // ends with Save, so take the last "Save" after the OCR item.
            app.printScreen(missing: "workflowEditor.add.save")
            let saves = app.buttons.matching(NSPredicate(format: "label == 'Save'"))
            XCTAssertTrue(ocrStep.exists, "The step menu did not open")
            saves.element(boundBy: saves.count - 1).tap()
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
