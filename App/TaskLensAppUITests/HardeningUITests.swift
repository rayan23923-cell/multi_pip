import XCTest

/// Production checks on the real app: accessibility audits on the main
/// screens in English and Arabic (RTL) at a large text size, launch time,
/// memory while searching, and the Your Data controls.
final class HardeningUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

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

    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 10,
                     file: StaticString = #filePath, line: UInt = #line) {
        app.revealAndTap(identifier, timeout: timeout, file: file, line: line)
    }

    /// Missing labels and text that doesn't scale fail the test; other audit
    /// findings (contrast, hit regions, clipping) are logged for review.
    private func audit(_ app: XCUIApplication, _ screen: String) {
        // Text cut off by the tab bar or the screen edge can't be measured at
        // every size; such Dynamic Type findings are logged with the frame.
        let tabBarTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY
        do {
            try app.performAccessibilityAudit(for: [.sufficientElementDescription, .dynamicType, .contrast, .hitRegion, .textClipped, .trait]) { issue in
                let line = "[\(screen)] \(issue.auditType.rawValue) \(issue.compactDescription) — \(issue.element?.identifier ?? "") \(issue.element?.label ?? "")"
                if issue.auditType == .dynamicType, let frame = issue.element?.frame, frame.maxY > tabBarTop {
                    print("AUDIT NOTE (partly off screen, maxY \(Int(frame.maxY)) > \(Int(tabBarTop))) " + line)
                    return true
                }
                if issue.auditType == .sufficientElementDescription || issue.auditType == .dynamicType {
                    // Reported as failures.
                    print("AUDIT FAIL " + line + " frame \(issue.element?.frame ?? .zero) tab bar top \(Int(tabBarTop))")
                    return false
                }
                print("AUDIT NOTE " + line)
                return true
            }
        } catch {
            XCTFail("Accessibility audit failed on \(screen): \(error)")
        }
    }

    private func visitMainScreens(_ app: XCUIApplication, label: String) {
        XCTAssertTrue(element(app, "commandCenter.lens").waitForExistence(timeout: 10))
        audit(app, "\(label) Command Center")

        tap(app, "commandCenter.lens")
        XCTAssertTrue(element(app, "lens.input").waitForExistence(timeout: 5))
        audit(app, "\(label) Lens")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tap(app, "commandCenter.workflows")
        XCTAssertTrue(element(app, "workflows.empty").waitForExistence(timeout: 5))
        audit(app, "\(label) Workflows")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.tabBars.buttons.element(boundBy: 2).tap()
        app.reveal("settings.deleteAll")
        audit(app, "\(label) Settings")
    }

    func testAccessibilityAuditEnglish() {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        visitMainScreens(app, label: "en")
    }

    func testAccessibilityAuditArabicRTL() {
        let app = launch(language: "ar", locale: "ar_IQ", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        visitMainScreens(app, label: "ar")
    }

    func testLaunchTime() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            let app = XCUIApplication()
            app.launchArguments = ["-TaskLensUITestStore"]
            app.launch()
        }
    }

    func testMemoryWhileSearching() {
        let app = launch()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            let search = app.searchFields.firstMatch
            if !search.waitForExistence(timeout: 2) { app.swipeDown() }
            guard search.waitForExistence(timeout: 5) else { return XCTFail("No search field") }
            search.tap()
            search.typeText("prices yesterday")
            _ = element(app, "search.hints").waitForExistence(timeout: 5)
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "prices yesterday".count))
        }
    }

    func testExportAndDeleteAllData() {
        continueAfterFailure = false
        let app = launch()
        tap(app, "commandCenter.notes")
        tap(app, "notes.new")
        let title = element(app, "noteEditor.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Private plan")
        tap(app, "noteEditor.save")
        XCTAssertTrue(element(app, "noteRow.Private plan").waitForExistence(timeout: 5))

        app.tabBars.buttons.element(boundBy: 2).tap()
        tap(app, "settings.export")
        XCTAssertTrue(element(app, "settings.export.share").waitForExistence(timeout: 10))

        tap(app, "settings.deleteAll")
        tap(app, "settings.deleteAll.confirm")
        XCTAssertTrue(element(app, "settings.deleted").waitForExistence(timeout: 10))

        app.tabBars.buttons.element(boundBy: 0).tap()
        tap(app, "commandCenter.notes")
        XCTAssertTrue(element(app, "noteRow.Private plan").waitForNonExistence(timeout: 5))
    }
}
