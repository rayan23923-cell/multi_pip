import XCTest

/// Not a check: walks the main screens and saves a PNG of each, for reviews
/// and the App Store screenshot plan. Runs only from the Screenshots workflow,
/// which sets TASKLENS_SCREENSHOT_DIR (passed as TEST_RUNNER_TASKLENS_SCREENSHOT_DIR).
final class ScreenshotTour: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let path = ProcessInfo.processInfo.environment["TASKLENS_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Screenshots run only from the Screenshots workflow")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
    }

    // MARK: Helpers

    private func launch(language: String = "en", locale: String = "en_US", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "-TaskLensUITestStore", "-TaskLensResetStore", "-TaskLensAINotEligible"] + extra
        app.launch()
        _ = app.identified("commandCenter.lens").waitForExistence(timeout: 15)
        return app
    }

    private func shot(_ name: String) {
        // Let animations and keyboards settle.
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        let data = XCUIScreen.main.screenshot().pngRepresentation
        do {
            try data.write(to: directory.appendingPathComponent("\(name).png"))
        } catch {
            XCTFail("Could not save \(name): \(error)")
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.exists { button.tap() }
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.count > 0 { app.navigationBars.firstMatch.tap() }
    }

    private func type(_ app: XCUIApplication, _ identifier: String, _ text: String) {
        let field = app.reveal(identifier)
        guard field.exists else { return }
        field.tap()
        field.typeText(text)
    }

    private func analyze(_ app: XCUIApplication, _ text: String) {
        app.revealAndTap("commandCenter.lens")
        type(app, "lens.input", text)
        app.revealAndTap("lens.analyze")
        _ = app.identified("lens.detectedType").waitForExistence(timeout: 10)
    }

    private func createNote(_ app: XCUIApplication, title: String, body: String) {
        app.revealAndTap("notes.new")
        type(app, "noteEditor.title", title)
        type(app, "noteEditor.body", body)
        app.revealAndTap("noteEditor.save")
    }

    // MARK: Tour

    func test01CommandCenterAndLens() {
        let app = launch()
        shot("01-command-center")

        analyze(app, "+964 770 123 4567")
        shot("02-lens-phone")
        back(app)

        analyze(app, "$125")
        shot("03-lens-currency")
        app.revealAndTap("action.convertCurrency")
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            alert.textFields.firstMatch.tap()
            alert.textFields.firstMatch.typeText("1310")
            shot("04-lens-convert-rate")
            let convert = alert.buttons.matching(identifier: "actions.convert.confirm").firstMatch
            if convert.exists { convert.tap() } else { alert.buttons["Convert"].firstMatch.tap() }
            _ = app.identified("calculator.display").waitForExistence(timeout: 5)
            shot("05-calculator-converted")
        }
    }

    func test02WorkspaceSessionAndSearch() {
        let app = launch()
        app.tabBars.buttons.element(boundBy: 1).tap()
        app.revealAndTap("workspaces.add")
        type(app, "workspaceEditor.name", "Research")
        shot("06-workspace-editor")
        app.revealAndTap("workspaceEditor.save")
        _ = app.identified("workspaceRow.Research").waitForExistence(timeout: 5)
        shot("07-workspaces")

        app.revealAndTap("workspaceRow.Research")
        shot("08-workspace-detail")
        app.revealAndTap("workspaceDetail.startSession")
        for value in ["https://developer.apple.com/documentation/vision", "+964 770 123 4567",
                      "Read chapter 4 before Monday", "What time is the review?"] {
            type(app, "quickCapture.field", value)
            app.revealAndTap("quickCapture.save")
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }
        dismissKeyboard(app)
        shot("09-session")

        app.tabBars.buttons.element(boundBy: 0).tap()
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 2) { app.swipeDown() }
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("chapter")
            _ = app.identified("search.hit").waitForExistence(timeout: 5)
            shot("10-smart-search")
        }
    }

    func test03Tools() {
        let app = launch(extra: ["-TaskLensSeedDocuments"])
        app.revealAndTap("commandCenter.notes")
        createNote(app, title: "Flutter state", body: "Use providers for shared state.")
        createNote(app, title: "Trip plan", body: "Hotel check in at 3 PM.")
        shot("11-notes")
        back(app)

        app.revealAndTap("commandCenter.calculator")
        for key in ["1", "2", "5", "multiply", "4", "equals"] {
            app.revealAndTap("calculator.key.\(key)", timeout: 3)
        }
        shot("12-calculator")
        back(app)

        app.revealAndTap("commandCenter.clipboard")
        shot("13-clipboard")
        back(app)

        app.revealAndTap("commandCenter.browser")
        shot("14-browser")
        back(app)

        app.revealAndTap("commandCenter.documents")
        shot("15-documents")
        app.revealAndTap("documentRow.Sample Report")
        _ = app.identified("pdf.pageLabel").waitForExistence(timeout: 10)
        shot("16-pdf-viewer")
        back(app)
        app.revealAndTap("documentRow.Sample Image")
        _ = app.identified("image.view").waitForExistence(timeout: 10)
        app.revealAndTap("image.recognizeText")
        _ = app.identified("lens.image.reading").waitForNonExistence(timeout: 30)
        shot("17-lens-image-results")
    }

    func test04PiPWorkflowsSettings() {
        let app = launch()
        app.revealAndTap("commandCenter.pip")
        shot("18-pip")
        back(app)

        app.revealAndTap("commandCenter.workflows")
        app.revealAndTap("workflows.add")
        app.revealAndTap("workflows.template.1")
        _ = app.identified("workflows.row.Summarize a link").waitForExistence(timeout: 5)
        shot("19-workflows")
        back(app)

        app.tabBars.buttons.element(boundBy: 2).tap()
        shot("20-settings")
        app.swipeUp()
        shot("21-settings-your-data")
    }

    func test05ShareSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-TaskLensUITestStore", "-TaskLensResetStore", "-TaskLensShareHarness"]
        app.launch()
        _ = app.identified("share.item.0.type").waitForExistence(timeout: 20)
        shot("22-share-sheet")
    }

    func test06ArabicRightToLeft() {
        let app = launch(language: "ar", locale: "ar_IQ")
        shot("23-ar-command-center")
        analyze(app, "+964 770 123 4567")
        shot("24-ar-lens")
        back(app)
        app.tabBars.buttons.element(boundBy: 2).tap()
        shot("25-ar-settings")
    }

    func test07DarkMode() {
        XCUIDevice.shared.appearance = .dark
        let app = launch()
        shot("26-dark-command-center")
        analyze(app, "$125")
        shot("27-dark-lens")
        back(app)
        app.tabBars.buttons.element(boundBy: 1).tap()
        shot("28-dark-workspaces")
    }
}
