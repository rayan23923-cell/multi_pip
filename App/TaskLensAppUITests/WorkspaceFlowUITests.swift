import XCTest

/// End-to-end flows on the real app, against an isolated test store.
final class WorkspaceFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func makeApp(language: String = "en", locale: String = "en_US", reset: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale] + extra + ["-TaskLensUITestStore"]
        if reset {
            app.launchArguments.append("-TaskLensResetStore")
        }
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openWorkspacesTab(_ app: XCUIApplication, label: String = "Workspaces") {
        let tab = app.tabBars.buttons[label]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Workspaces tab not found")
        tab.tap()
    }

    private func createWorkspace(_ app: XCUIApplication, name: String) {
        let add = element(app, "workspaces.add")
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let field = element(app, "workspaceEditor.name")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        element(app, "workspaceEditor.save").tap()
        XCTAssertTrue(element(app, "workspaceRow.\(name)").waitForExistence(timeout: 5), "Row for \(name) missing")
    }

    private func openMenuItem(_ app: XCUIApplication, identifier: String, fallbackLabel: String) {
        let menu = element(app, "workspaceDetail.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let item = element(app, identifier)
        if item.waitForExistence(timeout: 3) {
            item.tap()
        } else {
            app.buttons[fallbackLabel].firstMatch.tap()
        }
    }

    // MARK: Tests

    func testCreateWorkspacePersistsAcrossRelaunch() {
        let app = makeApp(reset: true)
        app.launch()
        openWorkspacesTab(app)
        createWorkspace(app, name: "Thesis")
        app.terminate()

        let relaunched = makeApp(reset: false)
        relaunched.launch()
        openWorkspacesTab(relaunched)
        XCTAssertTrue(element(relaunched, "workspaceRow.Thesis").waitForExistence(timeout: 10),
                      "Workspace should still exist after relaunch")
    }

    func testEditWorkspaceName() {
        let app = makeApp(reset: true)
        app.launch()
        openWorkspacesTab(app)
        createWorkspace(app, name: "Draft")
        element(app, "workspaceRow.Draft").tap()

        openMenuItem(app, identifier: "workspaceDetail.edit", fallbackLabel: "Edit")
        let field = element(app, "workspaceEditor.name")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(" Final")
        element(app, "workspaceEditor.save").tap()

        XCTAssertTrue(app.navigationBars["Draft Final"].waitForExistence(timeout: 5)
                      || app.staticTexts["Draft Final"].waitForExistence(timeout: 2))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "workspaceRow.Draft Final").waitForExistence(timeout: 5))
    }

    func testDeleteWorkspaceAsksForConfirmation() {
        let app = makeApp(reset: true)
        app.launch()
        openWorkspacesTab(app)
        createWorkspace(app, name: "Temporary")
        element(app, "workspaceRow.Temporary").tap()

        openMenuItem(app, identifier: "workspaceDetail.delete", fallbackLabel: "Delete")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Delete must ask for confirmation")
        // iOS 26 alerts can expose the same button twice in the hierarchy.
        alert.buttons["Delete"].firstMatch.tap()

        let row = element(app, "workspaceRow.Temporary")
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    func testCommandCenterQuickActionCreatesWorkspace() {
        let app = makeApp(reset: true)
        app.launch()
        let newWorkspace = element(app, "commandCenter.newWorkspace")
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 10))
        newWorkspace.tap()
        let field = element(app, "workspaceEditor.name")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Groceries")
        element(app, "workspaceEditor.save").tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
    }

    func testArabicLocalizationAndRightToLeftLayout() {
        let app = makeApp(language: "ar", locale: "ar_IQ", reset: true)
        app.launch()

        let commandCenter = app.tabBars.buttons["مركز الأوامر"]
        let workspaces = app.tabBars.buttons["مساحات العمل"]
        let settings = app.tabBars.buttons["الإعدادات"]
        XCTAssertTrue(commandCenter.waitForExistence(timeout: 10), "Arabic tab titles expected")
        XCTAssertTrue(workspaces.exists)
        XCTAssertTrue(settings.exists)

        // Right-to-left: the first tab sits on the right.
        XCTAssertGreaterThan(commandCenter.frame.midX, settings.frame.midX)

        workspaces.tap()
        XCTAssertTrue(app.navigationBars["مساحات العمل"].waitForExistence(timeout: 5))
        element(app, "workspaces.add").tap()
        XCTAssertTrue(app.navigationBars["مساحة عمل جديدة"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["إلغاء"].exists)
    }

    func testLargestAccessibilityTextSizeStillUsable() {
        let app = makeApp(reset: true, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.launch()
        let newWorkspace = element(app, "commandCenter.newWorkspace")
        XCTAssertTrue(newWorkspace.waitForExistence(timeout: 10))
        if !newWorkspace.isHittable {
            app.swipeUp()
        }
        newWorkspace.tap()
        let field = element(app, "workspaceEditor.name")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Big")
        element(app, "workspaceEditor.save").tap()
        XCTAssertTrue(app.navigationBars["Big"].waitForExistence(timeout: 5))
    }
}
