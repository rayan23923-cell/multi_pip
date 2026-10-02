import Foundation
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation

@Suite("Session Live Activity planning")
struct SessionActivityTests {
    let env = TestEnvironment()

    var service: SessionActivityService {
        SessionActivityService(workspaces: env.workspaces, sessions: env.sessions, capture: env.capture, clock: env.clock)
    }

    func research() async throws -> (Workspace, Session) {
        let workspace = try await env.workspaces.create(WorkspaceDraft(name: "Thesis", kind: .research))
        let session = try await env.sessions.start(in: workspace.id)
        return (workspace, session)
    }

    @Test func contentCountsWhatTheSessionCollected() async throws {
        let (_, session) = try await research()
        _ = try await env.capture.capture(.url(URL(string: "https://apple.com")!), source: .browser, into: session.id)
        _ = try await env.capture.capture(.url(URL(string: "https://swift.org")!), source: .browser, into: session.id)
        _ = try await env.capture.capture(.text("Idea"), source: .notes, into: session.id)
        _ = try await env.capture.capture(.text("Plain"), source: .manualEntry, into: session.id)

        let wanted = try await service.wanted()
        let request = try #require(wanted.first)
        #expect(request.sessionID == session.id)
        #expect(request.kind == .research)
        #expect(request.workspaceName == "Thesis")
        #expect(request.content.mode == .session)
        #expect(request.content.links == 2)
        #expect(request.content.notes == 1)
        #expect(request.content.items == 4)
        #expect(request.content.startedAt == session.startedAt)
        #expect(request.staleDate == env.clock.now().addingTimeInterval(SessionActivityPlanner.staleAfter))
    }

    @Test func modesFollowFocusProcessingAndImportantItems() async throws {
        let (_, session) = try await research()
        let item = try await env.capture.capture(.text("Write the abstract\nmore"), source: .manualEntry, into: session.id)
        _ = try await env.sessionContent.setImportant(item.id, true)

        var request = try #require(try await service.wanted().first)
        #expect(request.content.mode == .task)
        #expect(request.content.taskTitle == "Write the abstract")

        let focused = try await env.sessions.setFocus(session.id, minutes: 25)
        request = try #require(try await service.wanted().first)
        #expect(request.content.mode == .timer)
        #expect(request.content.focusEndsAt == focused.focusEndsAt)
        #expect(request.staleDate == focused.focusEndsAt)

        request = try #require(try await service.wanted(processing: [session.id: SessionProcessing(title: "Reading PDF", progress: 1.7)]).first)
        #expect(request.content.mode == .processing)
        #expect(request.content.progress == 1)

        // After the timer runs out the activity goes back to the task.
        env.clock.advance(by: 26 * 60)
        request = try #require(try await service.wanted().first)
        #expect(request.content.mode == .task)
    }

    @Test func focusTimerValidation() async throws {
        let (_, session) = try await research()
        await #expect(throws: TaskLensError.validationFailed(.outOfRange)) {
            try await env.sessions.setFocus(session.id, minutes: 0)
        }
        await #expect(throws: TaskLensError.validationFailed(.outOfRange)) {
            try await env.sessions.setFocus(session.id, minutes: SessionService.maximumFocusMinutes + 1)
        }
        _ = try await env.sessions.setFocus(session.id, minutes: 15)
        #expect(try await env.sessions.setFocus(session.id, minutes: nil).focusEndsAt == nil)

        _ = try await env.sessions.setFocus(session.id, minutes: 15)
        let ended = try await env.sessions.end(session.id)
        #expect(ended.focusEndsAt == nil)
        await #expect(throws: TaskLensError.invalidState(.sessionEnded)) {
            try await env.sessions.setFocus(session.id, minutes: 15)
        }
    }

    @Test func onlyActiveSessionsUpToTheLimit() async throws {
        var ids: [SessionID] = []
        for index in 0..<(SessionActivityPlanner.maximumActivities + 2) {
            env.clock.advance(by: 10)
            let workspace = try await env.workspaces.create(WorkspaceDraft(name: "W\(index)", kind: .work))
            ids.append(try await env.sessions.start(in: workspace.id).id)
        }
        _ = try await env.sessions.pause(ids.last!)

        let wanted = try await service.wanted().map(\.sessionID)
        #expect(wanted.count == SessionActivityPlanner.maximumActivities)
        #expect(!wanted.contains(ids.last!))
        // Most recent activity first.
        #expect(wanted.first == ids[ids.count - 2])
    }

    @Test func changesStartUpdateAndEnd() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let a = SessionID(), b = SessionID(), gone = SessionID()
        let content = SessionActivityContent(startedAt: now, items: 1)
        var changed = content
        changed.items = 2
        let wanted = [
            SessionActivityRequest(sessionID: a, kind: .research, workspaceName: "A", content: content, staleDate: now),
            SessionActivityRequest(sessionID: b, kind: .shopping, workspaceName: "B", content: changed, staleDate: now),
        ]

        // First run: both start.
        #expect(SessionActivityPlanner.changes(wanted: wanted, running: [:]) == wanted.map(SessionActivityChange.start))

        // Later: `a` is unchanged, `b` updates, `gone` (left over after the app
        // was closed, or its session ended) ends.
        let running = [a: content, b: content, gone: content]
        #expect(SessionActivityPlanner.changes(wanted: wanted, running: running) == [.end(gone), .update(wanted[1])])

        // Nothing wanted: everything ends.
        #expect(Set(SessionActivityPlanner.changes(wanted: [], running: running)) == [.end(a), .end(b), .end(gone)])
    }

    @Test func endedOrDeletedSessionsAreNotWanted() async throws {
        let (workspace, session) = try await research()
        #expect(try await service.wanted().count == 1)
        _ = try await env.sessions.end(session.id)
        #expect(try await service.wanted().isEmpty)

        let second = try await env.sessions.start(in: workspace.id)
        #expect(try await service.wanted().map(\.sessionID) == [second.id])
        try await env.workspaces.delete(workspace.id)
        #expect(try await service.wanted().isEmpty)
    }

    @Test func contentSurvivesEncoding() throws {
        let content = SessionActivityContent(
            mode: .timer, title: "Trip", startedAt: Date(timeIntervalSinceReferenceDate: 10),
            links: 7, notes: 3, documents: 2, items: 12, focusEndsAt: Date(timeIntervalSinceReferenceDate: 1_510)
        )
        let data = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(SessionActivityContent.self, from: data) == content)
    }

    @Test func storeChangesAreSignalled() async throws {
        let signal = StoreChangeSignal()
        let repositories = Repositories.inMemory().observingSessions(signal)
        let sessions = SessionService(workspaces: repositories.workspaces, sessions: repositories.sessions, clock: env.clock, logger: .disabled())
        let workspaces = WorkspaceService(
            workspaces: repositories.workspaces, sessions: repositories.sessions, contextItems: repositories.contextItems,
            documents: repositories.documents, notes: repositories.notes, actionRecords: repositories.actionRecords,
            clock: env.clock, logger: .disabled()
        )
        let workspace = try await workspaces.create(WorkspaceDraft(name: "W"))
        _ = try await sessions.start(in: workspace.id)

        var iterator = signal.changes.makeAsyncIterator()
        // Several writes collapse into one pending signal.
        #expect(await iterator.next() != nil)
    }
}
