import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

@Suite("SessionService")
struct SessionServiceTests {
    @Test func onlyOneActiveSessionPerWorkspace() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let other = try await env.workspaces.create(name: "Other")

        let first = try await env.sessions.start(in: workspace.id, kind: .research)
        let elsewhere = try await env.sessions.start(in: other.id)
        env.clock.advance(by: 1)
        let second = try await env.sessions.start(in: workspace.id)

        #expect(try await env.sessions.session(id: first.id).state == .paused)
        #expect(try await env.sessions.activeSession(in: workspace.id)?.id == second.id)
        #expect(try await env.sessions.session(id: elsewhere.id).isActive)

        env.clock.advance(by: 1)
        try await env.sessions.resume(first.id)
        #expect(try await env.sessions.session(id: second.id).state == .paused)
        #expect(try await env.sessions.activeSession(in: workspace.id)?.id == first.id)
    }

    @Test func startRequiresExistingWorkspace() async throws {
        let env = TestEnvironment()
        let missing = WorkspaceID()
        await #expect(throws: TaskLensError.notFound(entity: "workspace", id: missing.uuidString)) {
            try await env.sessions.start(in: missing)
        }
    }

    @Test func titlesAreTrimmedAndEmptyBecomesNil() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let titled = try await env.sessions.start(in: workspace.id, title: "  Flights  ")
        let untitled = try await env.sessions.start(in: workspace.id, title: "   ")
        #expect(titled.title == "Flights")
        #expect(untitled.title == nil)
    }

    @Test func endedSessionCannotResume() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)
        let ended = try await env.sessions.end(session.id)
        #expect(ended.isEnded)
        await #expect(throws: TaskLensError.invalidState(.sessionEnded)) {
            try await env.sessions.resume(session.id)
        }
    }

    @Test func listsMostRecentlyActiveFirst() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let older = try await env.sessions.start(in: workspace.id)
        env.clock.advance(by: 10)
        let newer = try await env.sessions.start(in: workspace.id)
        #expect(try await env.sessions.sessions(in: workspace.id).map(\.id) == [newer.id, older.id])

        env.clock.advance(by: 10)
        try await env.sessions.recordActivity(older.id)
        #expect(try await env.sessions.sessions(in: workspace.id).map(\.id) == [older.id, newer.id])
    }
}
