import XCTest

extension XCUIApplication {
    /// The first element with this accessibility identifier.
    func identified(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Lists are lazy: rows below the fold don't exist until scrolled to.
    /// Waits briefly, then swipes up until the element exists and can be
    /// tapped. Prints what is on screen when it never appears, so a CI log
    /// shows why.
    @discardableResult
    func reveal(_ identifier: String, timeout: TimeInterval = 10,
                file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = identified(identifier)
        if target.waitForExistence(timeout: min(timeout, 4)) { return target }
        // Only scroll when the element isn't there: a swipe on a screen that
        // already shows it can dismiss the keyboard or move the list away.
        for _ in 0..<10 {
            swipeUp()
            if target.waitForExistence(timeout: 1) { break }
        }
        if !target.waitForExistence(timeout: max(timeout - 4, 1)) {
            printScreen(missing: identifier)
            XCTFail("\(identifier) not found", file: file, line: line)
            return target
        }
        // Rows created by scrolling can sit under the tab bar; one more swipe.
        if !target.isHittable { swipeUp() }
        return target
    }

    func revealAndTap(_ identifier: String, timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line) {
        let target = reveal(identifier, timeout: timeout, file: file, line: line)
        if target.exists { target.tap() }
    }

    /// Polls the element's label. (XCTNSPredicateExpectation on an element's
    /// label can time out on a busy runner even when the label already matches.)
    func waitForLabel(_ identifier: String, timeout: TimeInterval, matching: (String) -> Bool) -> Bool {
        let target = identified(identifier)
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if target.exists, matching(target.label) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < end
        return target.exists && matching(target.label)
    }

    /// After a relaunch: the workspace row, or — when it's missing — what the
    /// store looks like (Settings shows where data is kept) before failing.
    func openSavedWorkspace(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = identified("workspaceRow.\(name)")
        if !row.waitForExistence(timeout: 8) {
            printScreen(missing: "workspaceRow.\(name) after relaunch")
            // Leave the tab and come back, which loads the list again.
            tabBars.buttons.element(boundBy: 0).tap()
            tabBars.buttons.element(boundBy: 1).tap()
            if !row.waitForExistence(timeout: 8) {
                tabBars.buttons.element(boundBy: 2).tap()
                let texts = staticTexts.allElementsBoundByIndex.prefix(40).map { $0.label }.joined(separator: " | ")
                print("MISSING workspaceRow.\(name) — settings: \(texts)")
                XCTFail("workspaceRow.\(name) not found after relaunch", file: file, line: line)
                return
            }
            print("MISSING workspaceRow.\(name) — appeared after reloading the list")
        }
        row.tap()
    }

    /// One line per identified element on screen, for the CI summary.
    func printScreen(missing identifier: String) {
        let titles = navigationBars.allElementsBoundByIndex.map { $0.identifier }.joined(separator: ", ")
        let ids = descendants(matching: .any).allElementsBoundByIndex
            .map { $0.identifier }.filter { !$0.isEmpty }
        print("MISSING \(identifier) — screen: [\(titles)] alerts: \(alerts.count) sheets: \(sheets.count)")
        print("MISSING \(identifier) — ids: \(Array(Set(ids)).sorted().prefix(60).joined(separator: " "))")
    }
}
