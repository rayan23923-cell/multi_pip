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
        if !target.waitForExistence(timeout: min(timeout, 4)) {
            for _ in 0..<10 {
                swipeUp()
                if target.waitForExistence(timeout: 1) { break }
            }
        }
        if !target.waitForExistence(timeout: max(timeout - 4, 1)) {
            printScreen(missing: identifier)
            XCTFail("\(identifier) not found", file: file, line: line)
            return target
        }
        for _ in 0..<5 where !target.isHittable {
            swipeUp()
        }
        return target
    }

    func revealAndTap(_ identifier: String, timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line) {
        let target = reveal(identifier, timeout: timeout, file: file, line: line)
        if target.exists { target.tap() }
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
