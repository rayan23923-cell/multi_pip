import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

@Suite("WorkspaceService")
struct WorkspaceServiceTests {
    @Test func createTrimsNameAndOrdersByCreation() async throws {
        let env = TestEnvironment()
        let first = try await env.workspaces.create(name: "  Work  ")
        let second = try await env.workspaces.create(name: "Home", color: .green)
        #expect(first.name == "Work")
        #expect(second.sortOrder == first.sortOrder + 1)
        #expect(try await env.workspaces.list().map(\.id) == [first.id, second.id])
    }

    @Test func rejectsInvalidNames() async throws {
        let env = TestEnvironment()
        await #expect(throws: TaskLensError.validationFailed(.emptyName)) {
            try await env.workspaces.create(name: "   ")
        }
        await #expect(throws: TaskLensError.validationFailed(.nameTooLong)) {
            try await env.workspaces.create(name: String(repeating: "a", count: Workspace.maximumNameLength + 1))
        }
    }

    @Test func renameUpdatesTimestamp() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "Old")
        env.clock.advance(by: 60)
        let renamed = try await env.workspaces.rename(workspace.id, to: "New")
        #expect(renamed.name == "New")
        #expect(renamed.updatedAt == workspace.createdAt.addingTimeInterval(60))
    }

    @Test func archivingHidesWorkspaceAndPausesSessions() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "Trip")
        let session = try await env.sessions.start(in: workspace.id)

        try await env.workspaces.setArchived(workspace.id, true)

        #expect(try await env.workspaces.list().isEmpty)
        #expect(try await env.workspaces.list(includeArchived: true).count == 1)
        #expect(try await env.sessions.session(id: session.id).state == .paused)
        await #expect(throws: TaskLensError.invalidState(.workspaceArchived)) {
            try await env.sessions.start(in: workspace.id)
        }
    }

    @Test func deleteCascadesToOwnedData() async throws {
        let env = TestEnvironment()
        let keep = try await env.workspaces.create(name: "Keep")
        let doomed = try await env.workspaces.create(name: "Delete")
        let doomedSession = try await env.sessions.start(in: doomed.id)
        let keptSession = try await env.sessions.start(in: keep.id)

        try await env.capture.capture(.text("a"), source: .manualEntry, into: doomedSession.id)
        let keptItem = try await env.capture.capture(.text("b"), source: .manualEntry, into: keptSession.id)
        let inboxItem = try await env.capture.capture(.text("c"), source: .manualEntry)
        try await env.notes.create(body: "doomed note", workspaceID: doomed.id)
        let keptNote = try await env.notes.create(body: "kept note", workspaceID: keep.id)

        try await env.workspaces.delete(doomed.id)

        #expect(try await env.workspaces.list().map(\.id) == [keep.id])
        #expect(try await env.repositories.sessions.fetchAll().map(\.id) == [keptSession.id])
        #expect(Set(try await env.repositories.contextItems.fetchAll().map(\.id)) == [keptItem.id, inboxItem.id])
        #expect(try await env.repositories.notes.fetchAll().map(\.id) == [keptNote.id])
    }

    @Test func deletingUnknownWorkspaceThrows() async throws {
        let env = TestEnvironment()
        let id = WorkspaceID()
        await #expect(throws: TaskLensError.notFound(entity: "workspace", id: id.uuidString)) {
            try await env.workspaces.delete(id)
        }
    }
}
