import XCTest

/// A9.5.2: the screen shown when a PowerPoint file can't be presented. Uses the
/// app's real import, cache, renderer and classification: "Sample Deck" is a
/// package with no slides (rendering fails), and "Notes Deck" is a real deck
/// with speaker notes, which iOS refuses.
final class PowerPointFailureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(language: String = "en", locale: String = "en_US", extra: [String] = []) throws -> XCUIApplication {
        let bundle = Bundle(for: PowerPointFailureUITests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "notes", withExtension: "pptx")
            ?? bundle.url(forResource: "notes", withExtension: "pptx", subdirectory: "Fixtures"))
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-TaskLensUITestStore",
                               "-TaskLensResetStore", "-TaskLensSeedDocuments", "-TaskLensSeedPowerPoint"] + extra
        app.launchEnvironment["TASKLENS_SEED_PPTX_NOTES"] = try Data(contentsOf: url).base64EncodedString()
        // Import PDF takes these picks instead of the system file picker (A9.5.3).
        app.launchEnvironment["TASKLENS_FALLBACK_PDFS"] = "cancel"
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

    private func waitFor(_ app: XCUIApplication, _ identifier: String, label: String, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) {
        let ok = app.waitForLabel(identifier, timeout: timeout) { $0 == label }
        if !ok { app.printScreen(missing: "\(identifier) = \(label)") }
        XCTAssertTrue(ok, "\(identifier) should read '\(label)', reads '\(element(app, identifier).label)'", file: file, line: line)
    }

    /// The failure screen's text never carries technical detail.
    private func assertPlainLanguage(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let text = [element(app, "presentation.failure.title").label, element(app, "presentation.failure.message").label]
            .joined(separator: " ")
        for word in ["912", "WebKit", "XML", "ZIP", "OfficeImport", "cache", "/", "Error", "error"] {
            XCTAssertFalse(text.contains(word), "'\(word)' in: \(text)", file: file, line: line)
        }
    }

    private func assertActions(_ app: XCUIApplication, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        for action in ["retry", "importPDF", "cancel"] {
            XCTAssertEqual(element(app, "presentation.failure.\(action)").exists, expected.contains(action),
                           "presentation.failure.\(action)", file: file, line: line)
        }
    }

    // MARK: Generic failure

    /// Rendering fails: Try Again runs the same pipeline again, Import PDF with
    /// the picker cancelled keeps the screen, Cancel goes back. The PDF reader keeps its page.
    func testGenericFailureRetriesCallsImportAndCancels() throws {
        let app = try launch()
        tap(app, "commandCenter.documents")
        // The PDF reader is on page 2 before the PowerPoint file fails.
        tap(app, "documentRow.Sample Report")
        waitFor(app, "pdf.pageLabel", label: "Page 1 of 3")
        tap(app, "pdf.nextPage")
        waitFor(app, "pdf.pageLabel", label: "Page 2 of 3")
        app.navigationBars.buttons.firstMatch.tap()

        tap(app, "documentRow.Sample Deck")
        waitFor(app, "presentation.failure.title", label: "Couldn't display this presentation", timeout: 60)
        XCTAssertTrue(element(app, "presentation.error").exists)
        XCTAssertTrue(element(app, "presentation.failure.message").label.contains("export it as a PDF"))
        assertActions(app, ["retry", "importPDF", "cancel"])
        assertPlainLanguage(app)
        XCTAssertFalse(element(app, "presentation.counter").exists, "No empty presentation")

        // Try Again: the same render again; it fails the same way and comes back here.
        tap(app, "presentation.failure.retry")
        waitFor(app, "presentation.failure.title", label: "Couldn't display this presentation", timeout: 60)
        assertActions(app, ["retry", "importPDF", "cancel"])

        // Import PDF with the picker cancelled: the screen stays.
        tap(app, "presentation.failure.importPDF")
        XCTAssertTrue(element(app, "presentation.failure.title").waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)

        // Cancel: back to the library, nothing left on screen.
        tap(app, "presentation.failure.cancel")
        XCTAssertTrue(element(app, "documentRow.Sample Deck").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "presentation.error").waitForNonExistence(timeout: 5))
        XCTAssertFalse(element(app, "presentation.loading").exists)

        // The PDF reader is still on page 2.
        tap(app, "documentRow.Sample Report")
        waitFor(app, "pdf.pageLabel", label: "Page 2 of 3")
    }

    // MARK: Speaker notes

    func testSpeakerNotesFailureOffersPDFAndPassesTheAudit() throws {
        let app = try launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        tap(app, "commandCenter.documents")
        tap(app, "documentRow.Notes Deck")
        waitFor(app, "presentation.failure.title", label: "Speaker Notes aren't supported", timeout: 120)
        XCTAssertTrue(element(app, "presentation.failure.message").label.contains("Export the presentation as a PDF"))
        assertActions(app, ["importPDF", "cancel"])
        assertPlainLanguage(app)
        XCTAssertEqual(element(app, "presentation.failure.importPDF").label, "Import PDF")
        audit(app, "en notes failure")

        tap(app, "presentation.failure.cancel")
        XCTAssertTrue(element(app, "documentRow.Notes Deck").waitForExistence(timeout: 10))
    }

    func testSpeakerNotesFailureInArabic() throws {
        let app = try launch(language: "ar", locale: "ar_SA",
                             extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        tap(app, "commandCenter.documents")
        tap(app, "documentRow.Notes Deck")
        waitFor(app, "presentation.failure.title", label: "ملاحظات المتحدث غير مدعومة", timeout: 120)
        XCTAssertEqual(element(app, "presentation.failure.importPDF").label, "استيراد PDF")
        XCTAssertEqual(element(app, "presentation.failure.cancel").label, "إلغاء")
        audit(app, "ar notes failure")
    }

    // MARK: Accessibility

    /// Missing labels and text that doesn't scale fail; other findings are logged.
    private func audit(_ app: XCUIApplication, _ screen: String) {
        do {
            try app.performAccessibilityAudit(for: [.sufficientElementDescription, .dynamicType, .contrast, .hitRegion, .textClipped, .trait]) { issue in
                let line = "[\(screen)] \(issue.auditType.rawValue) \(issue.compactDescription) — \(issue.element?.identifier ?? "") \(issue.element?.label ?? "")"
                if issue.auditType == .sufficientElementDescription || issue.auditType == .dynamicType {
                    print("AUDIT FAIL " + line + " frame \(issue.element?.frame ?? .zero)")
                    return false
                }
                print("AUDIT NOTE " + line)
                return true
            }
        } catch {
            XCTFail("Accessibility audit failed on \(screen): \(error)")
        }
    }
}
