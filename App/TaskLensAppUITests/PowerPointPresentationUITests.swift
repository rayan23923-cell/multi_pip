import XCTest

/// A9.3: an imported PowerPoint file opens from the library into the existing
/// presentation screen, from the slide images rendered on the device.
final class PowerPointPresentationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Imports `Fixtures/presentation-20.pptx` twice, as "Slides A" and "Slides B".
    private func launch() throws -> XCUIApplication {
        let bundle = Bundle(for: PowerPointPresentationUITests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "presentation-20", withExtension: "pptx")
            ?? bundle.url(forResource: "presentation-20", withExtension: "pptx", subdirectory: "Fixtures"))
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-TaskLensUITestStore",
                               "-TaskLensResetStore", "-TaskLensSeedDocuments", "-TaskLensSeedPowerPoint"]
        app.launchEnvironment["TASKLENS_SEED_PPTX"] = try Data(contentsOf: url).base64EncodedString()
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

    private func waitFor(_ app: XCUIApplication, slideValue expected: String, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) {
        let slide = element(app, "presentation.slide")
        let predicate = NSPredicate(format: "value == %@", expected)
        let found = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: slide)], timeout: timeout) == .completed
        XCTAssertTrue(found, "The slide should show '\(expected)', shows '\(slide.value ?? "")'", file: file, line: line)
    }

    /// Opens a deck from the library. The first open renders its slides.
    private func open(_ app: XCUIApplication, _ title: String, expecting counter: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        tap(app, "documentRow.\(title)", file: file, line: line)
        waitFor(app, "presentation.counter", label: counter, timeout: 120, file: file, line: line)
        waitFor(app, slideValue: title, file: file, line: line)
        XCTAssertFalse(element(app, "presentation.slideFailed").exists, "The slide image is shown", file: file, line: line)
        XCTAssertFalse(element(app, "pdf.pageLabel").exists, "Not the PDF reader", file: file, line: line)
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "presentation.counter").waitForNonExistence(timeout: 10))
    }

    private func goToSlide(_ app: XCUIApplication, _ number: Int, file: StaticString = #filePath, line: UInt = #line) {
        tap(app, "presentation.counter", file: file, line: line)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Go to Slide should open", file: file, line: line)
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        field.tap()
        field.typeText(String(number))
        alert.buttons["OK"].tap()
        waitFor(app, "presentation.counter", label: "Slide \(number) of 20", file: file, line: line)
    }

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

    private func assertStays(_ app: XCUIApplication, on label: String, for seconds: TimeInterval,
                             file: StaticString = #filePath, line: UInt = #line) {
        let moved = app.waitForLabel("presentation.counter", timeout: seconds) { $0 != label }
        XCTAssertFalse(moved, "The slide should not move, reads '\(element(app, "presentation.counter").label)'", file: file, line: line)
    }

    func testPowerPointPresentsNavigatesPlaysAndReopens() throws {
        let app = try launch()
        tap(app, "commandCenter.documents")
        XCTAssertTrue(element(app, "documentRow.Slides A").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "documentRow.Slides A").label.contains("PowerPoint Presentation"))
        open(app, "Slides A", expecting: "Slide 1 of 20")

        // Navigation, bounds and Go to Slide.
        XCTAssertFalse(element(app, "presentation.previous").isEnabled, "Previous is off on the first slide")
        tap(app, "presentation.next")
        waitFor(app, "presentation.counter", label: "Slide 2 of 20")
        tap(app, "presentation.previous")
        waitFor(app, "presentation.counter", label: "Slide 1 of 20")
        goToSlide(app, 20)
        XCTAssertFalse(element(app, "presentation.next").isEnabled, "Next is off on the last slide; no wrap-around")
        goToSlide(app, 8)

        // Rotation keeps the slide.
        XCUIDevice.shared.orientation = .landscapeLeft
        waitFor(app, "presentation.counter", label: "Slide 8 of 20")
        let landscape = element(app, "presentation.slide").frame
        XCTAssertGreaterThan(landscape.width, landscape.height, "The slide uses the landscape width")
        XCUIDevice.shared.orientation = .portrait
        waitFor(app, "presentation.counter", label: "Slide 8 of 20")
        XCTAssertFalse(element(app, "presentation.slideFailed").exists)

        // Background and foreground keep the slide.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        waitFor(app, "presentation.counter", label: "Slide 8 of 20")

        // Auto Play: play, pause, resume, stop.
        chooseFiveSeconds(app)
        tap(app, "presentation.autoPlay")
        waitFor(app, "presentation.autoPlay", label: "Pause Auto Play")
        waitFor(app, "presentation.counter", label: "Slide 9 of 20", timeout: 12)
        tap(app, "presentation.autoPlay")
        waitFor(app, "presentation.autoPlay", label: "Resume Auto Play")
        let paused = element(app, "presentation.counter").label
        assertStays(app, on: paused, for: 7)
        tap(app, "presentation.autoPlay")
        waitFor(app, "presentation.autoPlay", label: "Pause Auto Play")
        XCTAssertTrue(app.waitForLabel("presentation.counter", timeout: 12) { $0 != paused }, "Resume moves on")
        tap(app, "presentation.autoPlayStop")
        waitFor(app, "presentation.autoPlay", label: "Start Auto Play")
        let stopped = element(app, "presentation.counter").label
        assertStays(app, on: stopped, for: 7)

        // Reopening returns to the same slide, from the images already rendered.
        back(app)
        open(app, "Slides A", expecting: stopped)
        goToSlide(app, 5)
        back(app)

        // A second deck keeps its own slide.
        open(app, "Slides B", expecting: "Slide 1 of 20")
        goToSlide(app, 9)
        back(app)
        open(app, "Slides A", expecting: "Slide 5 of 20")
        back(app)
        open(app, "Slides B", expecting: "Slide 9 of 20")
    }
}
