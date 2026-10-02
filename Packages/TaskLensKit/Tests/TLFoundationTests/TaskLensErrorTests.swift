import Foundation
import Testing
@testable import TLFoundation

@Suite("TaskLensError")
struct TaskLensErrorTests {
    @Test func localizationKeysAreStable() {
        #expect(TaskLensError.notFound(entity: "note", id: "1").localizationKey == "error.notFound")
        #expect(TaskLensError.validationFailed(.emptyName).localizationKey == "error.validation.emptyName")
        #expect(TaskLensError.invalidState(.sessionEnded).localizationKey == "error.state.sessionEnded")
    }

    @Test func allLocalizationKeysCoverEveryCase() {
        let keys = Set(TaskLensError.allLocalizationKeys)
        let produced: [TaskLensError] = [
            .notFound(entity: "x", id: "y"),
            .persistenceFailed(operation: .write, details: ""),
            .unsupportedContent(type: "x"),
            .unavailable(feature: "x"),
        ]
            + ValidationFailure.allCases.map { .validationFailed($0) }
            + InvalidStateReason.allCases.map { .invalidState($0) }
        for error in produced {
            #expect(keys.contains(error.localizationKey))
        }
        #expect(keys.count == TaskLensError.allLocalizationKeys.count)
    }

    @Test func manualClockAdvances() {
        let clock = ManualDateProvider(Date(timeIntervalSinceReferenceDate: 100))
        clock.advance(by: 5)
        #expect(clock.now() == Date(timeIntervalSinceReferenceDate: 105))
    }
}
