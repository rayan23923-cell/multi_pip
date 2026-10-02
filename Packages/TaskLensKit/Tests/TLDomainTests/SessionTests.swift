import Foundation
import Testing
@testable import TLDomain
import TLFoundation

@Suite("Session state machine")
struct SessionTests {
    private func makeSession() -> Session {
        Session(workspaceID: WorkspaceID(), startedAt: Fixtures.date)
    }

    @Test func startsActive() {
        let session = makeSession()
        #expect(session.isActive)
        #expect(session.lastActivityAt == session.startedAt)
        #expect(session.endedAt == nil)
    }

    @Test func pauseAndResume() throws {
        var session = makeSession()
        try session.pause(at: Fixtures.date.addingTimeInterval(10))
        #expect(session.state == .paused)
        try session.resume(at: Fixtures.date.addingTimeInterval(20))
        #expect(session.state == .active)
        #expect(session.lastActivityAt == Fixtures.date.addingTimeInterval(20))
    }

    @Test func endedSessionRejectsTransitions() throws {
        var session = makeSession()
        try session.end(at: Fixtures.date.addingTimeInterval(5))
        #expect(throws: TaskLensError.invalidState(.sessionEnded)) { try session.resume(at: Fixtures.date) }
        #expect(throws: TaskLensError.invalidState(.sessionEnded)) { try session.pause(at: Fixtures.date) }
        #expect(throws: TaskLensError.invalidState(.sessionEnded)) { try session.end(at: Fixtures.date) }
        #expect(throws: TaskLensError.invalidState(.sessionEnded)) { try session.recordActivity(at: Fixtures.date) }
    }

    @Test func activityNeverMovesBackwards() throws {
        var session = makeSession()
        try session.recordActivity(at: Fixtures.date.addingTimeInterval(100))
        try session.recordActivity(at: Fixtures.date.addingTimeInterval(50))
        #expect(session.lastActivityAt == Fixtures.date.addingTimeInterval(100))
    }
}
