import Foundation
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation

@Suite("Workspace management")
struct WorkspaceManagementTests {
    @Test func createFromDraftKeepsKindAndTools() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(
            WorkspaceDraft(name: " Thesis ", kind: .study, tools: [.notes, .notes, .lens])
        )
        #expect(workspace.name == "Thesis")
        #expect(workspace.kind == .study)
        #expect(workspace.tools == [.notes, .lens])
        #expect(workspace.symbolName == WorkspaceKind.study.defaultSymbolName)
    }

    @Test func updateEditsEveryField() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "Old", kind: .work)
        env.clock.advance(by: 30)
        var draft = WorkspaceDraft(workspace)
        draft.name = "New"
        draft.kind = .developer
        draft.symbolName = "hammer"
        draft.color = .pink
        draft.tools = [.browser]
        draft.settings.resumesLastSession = true

        let updated = try await env.workspaces.update(workspace.id, with: draft)

        #expect(updated.name == "New")
        #expect(updated.kind == .developer)
        #expect(updated.symbolName == "hammer")
        #expect(updated.color == .pink)
        #expect(updated.tools == [.browser])
        #expect(updated.settings.resumesLastSession)
        #expect(updated.updatedAt == env.clock.now())
        #expect(updated.createdAt == workspace.createdAt)
    }

    @Test func updateRejectsEmptyName() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "Keep")
        var draft = WorkspaceDraft(workspace)
        draft.name = " "
        await #expect(throws: TaskLensError.validationFailed(.emptyName)) {
            try await env.workspaces.update(workspace.id, with: draft)
        }
        #expect(try await env.workspaces.workspace(id: workspace.id).name == "Keep")
    }

    @Test func duplicateCopiesConfigurationOnlyAndSitsAfterOriginal() async throws {
        let env = TestEnvironment()
        let first = try await env.workspaces.create(name: "A", kind: .shopping)
        let last = try await env.workspaces.create(name: "C")
        try await env.workspaces.setFavorite(first.id, true)
        try await env.sessions.start(in: first.id)

        let copy = try await env.workspaces.duplicate(first.id, name: "A copy")

        #expect(copy.id != first.id)
        #expect(copy.kind == .shopping)
        #expect(copy.tools == first.tools)
        #expect(copy.isFavorite == false)
        #expect(try await env.sessions.sessions(in: copy.id).isEmpty)
        #expect(try await env.workspaces.list().map(\.id) == [first.id, copy.id, last.id])
    }

    @Test func reorderPersistsNewOrder() async throws {
        let env = TestEnvironment()
        let a = try await env.workspaces.create(name: "A")
        let b = try await env.workspaces.create(name: "B")
        let c = try await env.workspaces.create(name: "C")

        try await env.workspaces.reorder([c.id, a.id, b.id])
        #expect(try await env.workspaces.list().map(\.id) == [c.id, a.id, b.id])

        // Partial lists keep the remaining workspaces after the listed ones.
        try await env.workspaces.reorder([b.id])
        #expect(try await env.workspaces.list().map(\.id) == [b.id, c.id, a.id])
    }

    @Test func favoritesAndRecentlyOpened() async throws {
        let env = TestEnvironment()
        let a = try await env.workspaces.create(name: "A")
        let b = try await env.workspaces.create(name: "B")
        try await env.workspaces.create(name: "Never opened")

        try await env.workspaces.setFavorite(b.id, true)
        #expect(try await env.workspaces.favorites().map(\.id) == [b.id])

        try await env.workspaces.markOpened(a.id)
        env.clock.advance(by: 5)
        let opened = try await env.workspaces.markOpened(b.id)
        #expect(opened.lastOpenedAt == env.clock.now())
        #expect(try await env.workspaces.recentlyOpened(limit: 5).map(\.id) == [b.id, a.id])
        #expect(try await env.workspaces.recentlyOpened(limit: 1).map(\.id) == [b.id])
    }

    @Test func openingResumesLastPausedSessionWhenEnabled() async throws {
        let env = TestEnvironment()
        var draft = WorkspaceDraft(name: "Study", kind: .study)
        draft.settings.resumesLastSession = true
        let workspace = try await env.workspaces.create(draft)
        let session = try await env.sessions.start(in: workspace.id)
        try await env.sessions.pause(session.id)

        try await env.workspaces.markOpened(workspace.id)

        #expect(try await env.sessions.session(id: session.id).isActive)
    }

    @Test func openingDoesNotResumeWhenDisabled() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)
        try await env.sessions.pause(session.id)

        try await env.workspaces.markOpened(workspace.id)

        #expect(try await env.sessions.session(id: session.id).state == .paused)
    }

    @Test func sessionsUseWorkspaceDefaultKind() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "Dev", kind: .developer)
        let session = try await env.sessions.start(in: workspace.id)
        #expect(session.kind == .developer)
        let explicit = try await env.sessions.start(in: workspace.id, kind: .research)
        #expect(explicit.kind == .research)
    }

    @Test func recentSessionsExcludeActiveOnes() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let ended = try await env.sessions.start(in: workspace.id)
        try await env.sessions.end(ended.id)
        env.clock.advance(by: 1)
        let active = try await env.sessions.start(in: workspace.id)
        #expect(try await env.sessions.recentSessions(limit: 10).map(\.id) == [ended.id])
        #expect(try await env.sessions.activeSessions().map(\.id) == [active.id])
    }
}

@Suite("Persistence across launches")
struct PersistenceAcrossLaunchesTests {
    private func services(at location: StoreLocation, clock: ManualDateProvider) throws -> (WorkspaceService, SessionService) {
        let repositories = try Repositories.fileBacked(at: location, logger: .disabled())
        let workspaces = WorkspaceService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            contextItems: repositories.contextItems,
            documents: repositories.documents,
            notes: repositories.notes,
            clock: clock,
            logger: .disabled()
        )
        let sessions = SessionService(workspaces: repositories.workspaces, sessions: repositories.sessions, clock: clock, logger: .disabled())
        return (workspaces, sessions)
    }

    @Test func workspaceChangesSurviveReopen() async throws {
        let location = StoreLocation(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskLensReopen-\(UUID().uuidString)", isDirectory: true))
        let clock = ManualDateProvider(Date(timeIntervalSinceReferenceDate: 100))

        // First launch: create, edit, favorite, reorder, duplicate, delete.
        let (firstWorkspaces, firstSessions) = try services(at: location, clock: clock)
        let study = try await firstWorkspaces.create(name: "Study", kind: .study)
        let shop = try await firstWorkspaces.create(name: "Shop", kind: .shopping)
        let doomed = try await firstWorkspaces.create(name: "Delete me")
        var draft = WorkspaceDraft(study)
        draft.name = "Thesis"
        try await firstWorkspaces.update(study.id, with: draft)
        try await firstWorkspaces.setFavorite(shop.id, true)
        try await firstWorkspaces.reorder([shop.id, study.id])
        let copy = try await firstWorkspaces.duplicate(shop.id, name: "Shop copy")
        try await firstWorkspaces.delete(doomed.id)
        let session = try await firstSessions.start(in: study.id)

        // Second launch: fresh repositories over the same files.
        let (reopenedWorkspaces, reopenedSessions) = try services(at: location, clock: clock)
        let workspaces = try await reopenedWorkspaces.list()
        #expect(workspaces.map(\.name) == ["Shop", "Shop copy", "Thesis"])
        #expect(workspaces.map(\.id) == [shop.id, copy.id, study.id])
        #expect(workspaces.first?.isFavorite == true)
        #expect(workspaces.last?.kind == .study)
        #expect(try await reopenedSessions.session(id: session.id).workspaceID == study.id)
    }
}
