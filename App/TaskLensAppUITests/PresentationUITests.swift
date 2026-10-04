import XCTest

/// Presenting a PDF and a set of images from the document library.
final class PresentationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(presentationImages: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-TaskLensUITestStore", "-TaskLensResetStore", "-TaskLensSeedDocuments"]
        if presentationImages { app.launchArguments.append("-TaskLensSeedPresentationImages") }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 10,
                     file: StaticString = #filePath, line: UInt = #line) {
        let target = element(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(identifier) not found", file: file, line: line)
        target.tap()
    }

    private func waitFor(_ app: XCUIApplication, _ identifier: String, label: String, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) {
        let ok = app.waitForLabel(identifier, timeout: timeout) { $0 == label }
        if !ok { app.printScreen(missing: "\(identifier) = \(label)") }
        XCTAssertTrue(ok, "\(identifier) should read '\(label)', reads '\(element(app, identifier).label)'", file: file, line: line)
    }

    private func waitFor(_ app: XCUIApplication, slideValue expected: String, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) {
        let slide = element(app, "presentation.slide")
        let predicate = NSPredicate(format: "value == %@", expected)
        let found = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: slide)], timeout: timeout) == .completed
        XCTAssertTrue(found, "The slide should show '\(expected)', shows '\(slide.value ?? "")'", file: file, line: line)
    }

    func testPresentPDFNavigatesWithinBoundsAndKeepsTheReadingPage() {
        let app = launch()
        tap(app, "commandCenter.documents")
        tap(app, "documentRow.Sample Report")
        waitFor(app, "pdf.pageLabel", label: "Page 1 of 3")
        // The reader is on page 2.
        tap(app, "pdf.nextPage")
        waitFor(app, "pdf.pageLabel", label: "Page 2 of 3")

        tap(app, "pdf.menu")
        tap(app, "pdf.present")
        // Presenting starts at the first slide, not at the reading page.
        waitFor(app, "presentation.counter", label: "Slide 1 of 3")
        XCTAssertTrue(element(app, "presentation.slide").exists)
        XCTAssertFalse(element(app, "presentation.previous").isEnabled, "Previous is off on the first slide")

        tap(app, "presentation.next")
        waitFor(app, "presentation.counter", label: "Slide 2 of 3")
        tap(app, "presentation.next")
        waitFor(app, "presentation.counter", label: "Slide 3 of 3")
        XCTAssertFalse(element(app, "presentation.next").isEnabled, "Next is off on the last slide; it does not wrap")
        tap(app, "presentation.previous")
        waitFor(app, "presentation.counter", label: "Slide 2 of 3")

        // Go to Slide from the counter.
        tap(app, "presentation.counter")
        // Text fields inside an alert are reached through the alert, not by identifier.
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Go to Slide should open")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("1")
        alert.buttons["OK"].tap()
        waitFor(app, "presentation.counter", label: "Slide 1 of 3")

        // Tapping the slide hides the controls; tapping again brings them back.
        tap(app, "presentation.slide")
        XCTAssertTrue(element(app, "presentation.counter").waitForNonExistence(timeout: 5), "Controls should hide")
        tap(app, "presentation.slide")
        XCTAssertTrue(element(app, "presentation.counter").waitForExistence(timeout: 5), "Controls should come back")

        // Leaving and reopening the PDF: the reader is still on page 2.
        app.navigationBars.buttons.firstMatch.tap()
        waitFor(app, "pdf.pageLabel", label: "Page 2 of 3")
        app.navigationBars.buttons.firstMatch.tap()
        tap(app, "documentRow.Sample Report")
        waitFor(app, "pdf.pageLabel", label: "Page 2 of 3")
    }

    /// Control for the test above: the reader's own page after visiting another
    /// screen (Lens) instead of the presentation.
    func testReaderKeepsItsPageAfterVisitingLens() {
        let app = launch()
        tap(app, "commandCenter.documents")
        tap(app, "documentRow.Sample Report")
        waitFor(app, "pdf.pageLabel", label: "Page 1 of 3")
        tap(app, "pdf.nextPage")
        waitFor(app, "pdf.pageLabel", label: "Page 2 of 3")

        tap(app, "pdf.menu")
        tap(app, "pdf.lens")
        XCTAssertTrue(element(app, "pdf.pageLabel").waitForNonExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        waitFor(app, "pdf.pageLabel", label: "Page 2 of 3")
        app.navigationBars.buttons.firstMatch.tap()
        tap(app, "documentRow.Sample Report")
        waitFor(app, "pdf.pageLabel", label: "Page 2 of 3")
    }

    func testPresentImagesInLibraryOrder() {
        let app = launch(presentationImages: true)
        tap(app, "commandCenter.documents")
        XCTAssertTrue(element(app, "documentRow.Slide 3").waitForExistence(timeout: 10))

        // The library lists the newest first: Slide 3, 2, 1, then Sample Image.
        tap(app, "documents.presentImages")
        waitFor(app, "presentation.counter", label: "Slide 1 of 4")
        waitFor(app, slideValue: "Slide 3")
        XCTAssertFalse(element(app, "presentation.slideFailed").exists)

        tap(app, "presentation.next")
        waitFor(app, "presentation.counter", label: "Slide 2 of 4")
        waitFor(app, slideValue: "Slide 2")
        tap(app, "presentation.next")
        tap(app, "presentation.next")
        waitFor(app, "presentation.counter", label: "Slide 4 of 4")
        waitFor(app, slideValue: "Sample Image")
        XCTAssertFalse(element(app, "presentation.next").isEnabled)
        tap(app, "presentation.previous")
        waitFor(app, "presentation.counter", label: "Slide 3 of 4")
        waitFor(app, slideValue: "Slide 1")
    }

    // MARK: Auto play

    /// Chooses the 5-second interval from the toolbar menu.
    private func chooseFiveSeconds(_ app: XCUIApplication) {
        tap(app, "presentation.interval")
        let item = element(app, "presentation.interval.5")
        if item.waitForExistence(timeout: 5) {
            item.tap()
        } else {
            let byLabel = app.buttons["5 seconds"]
            XCTAssertTrue(byLabel.waitForExistence(timeout: 5), "The 5 seconds item should be in the menu")
            byLabel.tap()
        }
    }

    /// The counter stays on `label` for `seconds`, longer than one interval.
    private func assertStays(_ app: XCUIApplication, on label: String, for seconds: TimeInterval,
                             file: StaticString = #filePath, line: UInt = #line) {
        let moved = app.waitForLabel("presentation.counter", timeout: seconds) { $0 != label }
        XCTAssertFalse(moved, "The slide should not move, reads '\(element(app, "presentation.counter").label)'", file: file, line: line)
    }

    func testAutoPlayAdvancesPausesResumesStopsAndEndsOnTheLastSlide() {
        let app = launch(presentationImages: true)
        tap(app, "commandCenter.documents")
        tap(app, "documents.presentImages")
        waitFor(app, "presentation.counter", label: "Slide 1 of 4")
        chooseFiveSeconds(app)
        waitFor(app, "presentation.autoPlay", label: "Start Auto Play")

        // Play: one slide every 5 seconds.
        tap(app, "presentation.autoPlay")
        waitFor(app, "presentation.autoPlay", label: "Pause Auto Play")
        waitFor(app, "presentation.counter", label: "Slide 2 of 4", timeout: 12)

        // Pause: nothing moves.
        tap(app, "presentation.autoPlay")
        waitFor(app, "presentation.autoPlay", label: "Resume Auto Play")
        let paused = element(app, "presentation.counter").label
        assertStays(app, on: paused, for: 8)

        // Resume continues from the same slide.
        tap(app, "presentation.autoPlay")
        let next = paused == "Slide 2 of 4" ? "Slide 3 of 4" : "Slide 4 of 4"
        waitFor(app, "presentation.counter", label: next, timeout: 12)

        // Stop: playback ends and the slide stays.
        tap(app, "presentation.autoPlayStop")
        waitFor(app, "presentation.autoPlay", label: "Start Auto Play")
        XCTAssertFalse(element(app, "presentation.autoPlayStop").exists)
        let stopped = element(app, "presentation.counter").label
        assertStays(app, on: stopped, for: 8)

        // Play to the end: it stops on the last slide and does not loop.
        tap(app, "presentation.autoPlay")
        waitFor(app, "presentation.counter", label: "Slide 4 of 4", timeout: 25)
        waitFor(app, "presentation.autoPlay", label: "Start Auto Play", timeout: 12)
        waitFor(app, slideValue: "Sample Image")
        assertStays(app, on: "Slide 4 of 4", for: 8)
    }

    func testAutoPlayPausesInTheBackgroundAndStopsWhenLeaving() {
        let app = launch(presentationImages: true)
        tap(app, "commandCenter.documents")
        tap(app, "documents.presentImages")
        waitFor(app, "presentation.counter", label: "Slide 1 of 4")
        chooseFiveSeconds(app)
        tap(app, "presentation.autoPlay")
        waitFor(app, "presentation.autoPlay", label: "Pause Auto Play")

        // Background: playback pauses and nothing moves while away.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5))
        sleep(8)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitFor(app, "presentation.autoPlay", label: "Resume Auto Play")
        let shown = element(app, "presentation.counter").label
        assertStays(app, on: shown, for: 8)

        // Leaving ends playback; reopening starts fresh, without an old countdown.
        tap(app, "presentation.autoPlay")
        waitFor(app, "presentation.autoPlay", label: "Pause Auto Play")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "documents.presentImages").waitForExistence(timeout: 10))
        tap(app, "documents.presentImages")
        waitFor(app, "presentation.counter", label: "Slide 1 of 4")
        waitFor(app, "presentation.autoPlay", label: "Start Auto Play")
        assertStays(app, on: "Slide 1 of 4", for: 12)
    }

    func testPresentationRotatesToLandscape() {
        let app = launch(presentationImages: true)
        tap(app, "commandCenter.documents")
        tap(app, "documents.presentImages")
        waitFor(app, "presentation.counter", label: "Slide 1 of 4")

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        tap(app, "presentation.next")
        waitFor(app, "presentation.counter", label: "Slide 2 of 4")
        waitFor(app, slideValue: "Slide 2")
        let slide = element(app, "presentation.slide").frame
        XCTAssertGreaterThan(slide.width, slide.height, "The slide uses the landscape width")
    }
}
