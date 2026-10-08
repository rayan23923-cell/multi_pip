import UIKit
import XCTest

/// A9.5.3: Import PDF on the PowerPoint failure screen. The system file picker
/// can't be driven from a UI test, so the app takes scripted picks
/// (`TASKLENS_FALLBACK_PDFS`) in its place; each picked file then goes through
/// the real import, library and PDF presentation. "Sample Deck" fails to render;
/// "Notes Deck" is a real deck with speaker notes, which iOS refuses.
final class PDFFallbackUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A real PDF with `pages` pages, as a pick: "<file name>:<base64>".
    private func pdfPick(_ name: String, pages: Int) -> String {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 792, height: 612)).pdfData { context in
            for page in 1...pages {
                context.beginPage()
                "\(name) \(page)".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 32)])
            }
        }
        return "\(name).pdf:\(data.base64EncodedString())"
    }

    private func launch(picks: [String]) throws -> XCUIApplication {
        let bundle = Bundle(for: PDFFallbackUITests.self)
        let notes = try XCTUnwrap(bundle.url(forResource: "notes", withExtension: "pptx")
            ?? bundle.url(forResource: "notes", withExtension: "pptx", subdirectory: "Fixtures"))
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-TaskLensUITestStore",
                               "-TaskLensResetStore", "-TaskLensSeedDocuments", "-TaskLensSeedPowerPoint"]
        app.launchEnvironment["TASKLENS_SEED_PPTX_NOTES"] = try Data(contentsOf: notes).base64EncodedString()
        app.launchEnvironment["TASKLENS_FALLBACK_PDFS"] = picks.joined(separator: ";")
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.identified(identifier)
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

    private func goToSlide(_ app: XCUIApplication, _ number: Int) {
        tap(app, "presentation.counter")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Go to Slide should open")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("\(number)")
        alert.buttons["OK"].tap()
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
    }

    // MARK: Speaker notes

    /// Notes failure → Import PDF, cancelled → the screen stays → an invalid
    /// file → rejected, nothing added → a valid PDF → it presents. The reader
    /// keeps its page, and after the app quits the PDF is in the library and
    /// its presentation reopens on the slide it was left on.
    func testSpeakerNotesFailureImportsAPDFAfterCancelAndInvalidFile() throws {
        let broken = "Broken Export.pdf:" + Data("not a pdf".utf8).base64EncodedString()
        let app = try launch(picks: ["cancel", broken, pdfPick("Notes Export", pages: 12)])
        tap(app, "commandCenter.documents")

        // The PDF reader is on page 2 before anything else happens.
        tap(app, "documentRow.Sample Report")
        waitFor(app, "pdf.pageLabel", label: "Page 1 of 3")
        tap(app, "pdf.nextPage")
        waitFor(app, "pdf.pageLabel", label: "Page 2 of 3")
        back(app)

        tap(app, "documentRow.Notes Deck")
        waitFor(app, "presentation.failure.title", label: "Speaker Notes aren't supported", timeout: 120)

        // 1. Picker cancelled: the failure screen stays, with both actions.
        tap(app, "presentation.failure.importPDF")
        XCTAssertTrue(element(app, "presentation.failure.title").waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2), "Cancelling is not an error")
        XCTAssertTrue(element(app, "presentation.failure.importPDF").exists)
        XCTAssertTrue(element(app, "presentation.failure.cancel").exists)

        // 2. An invalid file: the library's error, then the failure screen again.
        tap(app, "presentation.failure.importPDF")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "The import error is shown")
        XCTAssertTrue(alert.staticTexts["This file could not be opened."].exists, "Alert reads: \(alert.label)")
        alert.buttons["OK"].tap()
        waitFor(app, "presentation.failure.title", label: "Speaker Notes aren't supported")
        XCTAssertFalse(element(app, "presentation.counter").exists, "No broken presentation")

        // 3. A valid PDF: it opens as an ordinary PDF presentation.
        tap(app, "presentation.failure.importPDF")
        waitFor(app, "presentation.counter", label: "Slide 1 of 12", timeout: 30)
        XCTAssertFalse(element(app, "presentation.error").exists)
        goToSlide(app, 12)
        waitFor(app, "presentation.counter", label: "Slide 12 of 12")
        tap(app, "presentation.previous")
        waitFor(app, "presentation.counter", label: "Slide 11 of 12")

        // Back goes to the library, which lists the PDF and not the invalid file.
        back(app)
        XCTAssertTrue(element(app, "documentRow.Notes Export").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "documentRow.Broken Export").exists, "No library item for the invalid file")
        XCTAssertTrue(element(app, "documentRow.Notes Deck").exists, "The PowerPoint file stays")

        // The reader is still on page 2.
        tap(app, "documentRow.Sample Report")
        waitFor(app, "pdf.pageLabel", label: "Page 2 of 3")

        // Quit and start again on the same data.
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-TaskLensUITestStore"]
        relaunched.launch()
        tap(relaunched, "commandCenter.documents")
        // An ordinary PDF: it opens in the reader, on its own first page.
        tap(relaunched, "documentRow.Notes Export")
        waitFor(relaunched, "pdf.pageLabel", label: "Page 1 of 12")
        tap(relaunched, "pdf.menu")
        tap(relaunched, "pdf.present")
        waitFor(relaunched, "presentation.counter", label: "Slide 11 of 12", timeout: 20)
    }

    // MARK: Generic failure, auto play and several fallbacks

    /// Rendering fails → Import PDF → the PDF presents and auto plays. The same
    /// failing deck again → another PDF, independent of the first.
    func testGenericFailureImportsIndependentPDFs() throws {
        let app = try launch(picks: [pdfPick("Export A", pages: 3), pdfPick("Export B", pages: 5)])
        tap(app, "commandCenter.documents")

        tap(app, "documentRow.Sample Deck")
        waitFor(app, "presentation.failure.title", label: "Couldn't display this presentation", timeout: 60)
        tap(app, "presentation.failure.importPDF")
        waitFor(app, "presentation.counter", label: "Slide 1 of 3", timeout: 30)
        tap(app, "presentation.next")
        waitFor(app, "presentation.counter", label: "Slide 2 of 3")

        // Auto play: start, pause, resume, stop.
        waitFor(app, "presentation.autoPlay", label: "Start Auto Play")
        tap(app, "presentation.autoPlay")
        waitFor(app, "presentation.autoPlay", label: "Pause Auto Play")
        tap(app, "presentation.autoPlay")
        waitFor(app, "presentation.autoPlay", label: "Resume Auto Play")
        tap(app, "presentation.autoPlay")
        waitFor(app, "presentation.autoPlay", label: "Pause Auto Play")
        tap(app, "presentation.autoPlayStop")
        waitFor(app, "presentation.autoPlay", label: "Start Auto Play")
        waitFor(app, "presentation.counter", label: "Slide 2 of 3")
        back(app)

        // The same deck still fails; a second PDF is its own document and presentation.
        tap(app, "documentRow.Sample Deck")
        waitFor(app, "presentation.failure.title", label: "Couldn't display this presentation", timeout: 60)
        tap(app, "presentation.failure.importPDF")
        waitFor(app, "presentation.counter", label: "Slide 1 of 5", timeout: 30)
        back(app)

        XCTAssertTrue(element(app, "documentRow.Export A").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "documentRow.Export B").exists)
        tap(app, "documentRow.Export A")
        tap(app, "pdf.menu")
        tap(app, "pdf.present")
        waitFor(app, "presentation.counter", label: "Slide 2 of 3", timeout: 20)
    }
}
