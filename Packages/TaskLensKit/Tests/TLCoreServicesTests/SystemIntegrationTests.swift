import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

@Suite("System actions (Siri, Shortcuts, widgets)")
struct SystemActionsTests {
    let env = TestEnvironment()

    var actions: SystemActions {
        SystemActions(workspaces: env.workspaces, sessions: env.sessions, capture: env.capture, notes: env.notes)
    }

    @Test func startWorkspaceCreatesOnceThenReuses() async throws {
        let first = try await actions.startWorkspace(kind: .research, name: "Research")
        env.clock.advance(by: 60)
        let second = try await actions.startWorkspace(kind: .research, name: "Other name")

        #expect(first.id == second.id)
        #expect(second.name == "Research")
        #expect(second.lastOpenedAt == env.clock.now())
        #expect(try await env.workspaces.list().count == 1)
    }

    @Test func startWorkspacePicksTheMostRecentOfItsKind() async throws {
        let older = try await env.workspaces.create(WorkspaceDraft(name: "Old", kind: .shopping))
        env.clock.advance(by: 10)
        let newer = try await env.workspaces.create(WorkspaceDraft(name: "New", kind: .shopping))
        _ = try await env.workspaces.create(WorkspaceDraft(name: "Study", kind: .study))
        env.clock.advance(by: 10)
        _ = try await env.workspaces.markOpened(older.id)
        env.clock.advance(by: 10)
        _ = try await env.workspaces.markOpened(newer.id)

        let started = try await actions.startWorkspace(kind: .shopping, name: "Shopping")
        #expect(started.id == newer.id)
    }

    @Test func startSessionUsesTheWorkspaceDefaultKind() async throws {
        let workspace = try await actions.startWorkspace(kind: .shopping, name: "Shop")
        let session = try await actions.startSession(in: workspace.id)
        #expect(session.kind == .shopping)
        #expect(session.isActive)

        let research = try await actions.startSession(in: workspace.id, kind: .research)
        #expect(research.kind == .research)
    }

    @Test func saveGoesToTheActiveSessionOrTheInbox() async throws {
        let inboxed = try await actions.save("https://apple.com")
        #expect(inboxed.destination == .inbox)
        #expect(inboxed.item.sessionID == nil)
        #expect(inboxed.item.source == .appIntent)

        let workspace = try await actions.startWorkspace(kind: .research, name: "Research")
        let session = try await actions.startSession(in: workspace.id)
        let saved = try await actions.save("Read chapter 3")
        guard case .session(let target) = saved.destination else {
            Issue.record("Expected a session")
            return
        }
        #expect(target.id == session.id)
        #expect(try await env.capture.items(in: session.id).map(\.id) == [saved.item.id])
    }

    @Test func saveToAnEndedSessionFallsBackToTheInbox() async throws {
        let workspace = try await actions.startWorkspace(kind: .work, name: "Work")
        let session = try await actions.startSession(in: workspace.id)
        _ = try await env.sessions.end(session.id)

        let saved = try await actions.save("Note", into: session.id)
        #expect(saved.destination == .inbox)
    }

    @Test func saveToShoppingSessionReusesOrCreates() async throws {
        let created = try await actions.sessionForSaving(kind: .shopping, workspaceName: "Shopping")
        #expect(created.kind == .shopping)
        let workspace = try await env.workspaces.workspace(id: created.workspaceID)
        #expect(workspace.kind == .shopping)

        env.clock.advance(by: 5)
        let again = try await actions.sessionForSaving(kind: .shopping, workspaceName: "Shopping")
        #expect(again.id == created.id)
        #expect(try await env.workspaces.list().count == 1)

        let saved = try await actions.save("$19.99", into: again.id)
        #expect(saved.destination == .session(try await env.sessions.session(id: again.id)))
    }

    @Test func sessionOfKindFindsOpenSessionsOnly() async throws {
        #expect(try await actions.session(ofKind: .study) == nil)
        let workspace = try await actions.startWorkspace(kind: .study, name: "Study")
        let session = try await actions.startSession(in: workspace.id)
        #expect(try await actions.session(ofKind: .study)?.id == session.id)
        _ = try await env.sessions.end(session.id)
        #expect(try await actions.session(ofKind: .study) == nil)
    }

    @Test func createNoteSplitsTitleAndBody() async throws {
        let note = try await actions.createNote("Groceries\nMilk\nEggs")
        #expect(note.title == "Groceries")
        #expect(note.body == "Milk\nEggs")

        let single = try await actions.createNote("  Call the bank  ")
        #expect(single.title.isEmpty)
        #expect(single.body == "Call the bank")

        await #expect(throws: TaskLensError.validationFailed(.emptyContent)) {
            try await actions.createNote("   \n ")
        }
    }

    @Test func createNoteLinksTheActiveSession() async throws {
        let workspace = try await actions.startWorkspace(kind: .research, name: "Research")
        let session = try await actions.startSession(in: workspace.id)
        let note = try await actions.createNote("Idea")
        #expect(note.sessionID == session.id)
        #expect(note.workspaceID == workspace.id)
    }

    @Test func calculateUsesTheCalculatorRules() throws {
        #expect(try actions.calculate("12*3+4").result == 40)
        #expect(try actions.calculate("١٢ × ٣").result == 36)
        #expect(try actions.calculate("10 ÷ 4").result == Decimal(string: "2.5"))
        #expect(try actions.calculate("-5+2").result == -3)
        #expect(throws: TaskLensError.validationFailed(.invalidExpression)) { try actions.calculate("two plus two") }
        #expect(throws: TaskLensError.validationFailed(.invalidExpression)) { try actions.calculate("") }
        #expect(throws: TaskLensError.validationFailed(.invalidExpression)) { try actions.calculate("5/0") }
    }

    @Test func convertUsesTheGivenRateAndRounds() throws {
        #expect(try actions.convert(100, rate: Decimal(string: "0.92")!) == 92)
        #expect(try actions.convert(Decimal(string: "10.5")!, rate: Decimal(string: "1.23456")!) == Decimal(string: "12.9629"))
        #expect(throws: TaskLensError.validationFailed(.invalidExpression)) { try actions.convert(10, rate: 0) }
        #expect(throws: TaskLensError.validationFailed(.invalidExpression)) { try actions.convert(10, rate: -1) }
    }
}

@Suite("Widget snapshot")
struct WidgetSnapshotTests {
    let env = TestEnvironment()

    func make() async throws -> WidgetSnapshot {
        try await WidgetSnapshot.make(workspaces: env.workspaces, sessions: env.sessions, capture: env.capture, now: env.clock.now())
    }

    @Test func emptyStoreGivesAnEmptySnapshot() async throws {
        let snapshot = try await make()
        #expect(snapshot.isEmpty)
        #expect(snapshot.featuredWorkspace == nil)
        #expect(snapshot.version == WidgetSnapshot.currentVersion)
    }

    @Test func activeSessionsComeFirstThenRecentActivity() async throws {
        let research = try await env.workspaces.create(WorkspaceDraft(name: "Research", kind: .research))
        let shop = try await env.workspaces.create(WorkspaceDraft(name: "Shop", kind: .shopping))
        let old = try await env.sessions.start(in: research.id, title: "Old")
        env.clock.advance(by: 60)
        _ = try await env.sessions.end(old.id)
        env.clock.advance(by: 60)
        let active = try await env.sessions.start(in: shop.id, title: "Active")
        _ = try await env.capture.capture(.text("$5"), source: .manualEntry, into: active.id)
        _ = try await env.capture.capture(.text("$7"), source: .manualEntry, into: active.id)
        env.clock.advance(by: 60)
        let paused = try await env.sessions.start(in: research.id, title: "Paused")
        _ = try await env.sessions.pause(paused.id)
        env.clock.advance(by: 60)
        _ = try await env.workspaces.markOpened(shop.id)

        let snapshot = try await make()
        #expect(snapshot.sessions.map(\.title) == ["Active", "Paused", "Old"])
        #expect(snapshot.sessions[0].itemCount == 2)
        #expect(snapshot.sessions[0].workspaceName == "Shop")
        #expect(snapshot.featuredWorkspace?.id == shop.id)
        #expect(snapshot.featuredWorkspace?.activeSessionCount == 1)
        #expect(snapshot.workspaces.map(\.id) == [shop.id, research.id])
    }

    @Test func archivedSessionsAndExtrasAreLeftOut() async throws {
        let workspace = try await env.workspaces.create(WorkspaceDraft(name: "Work", kind: .work))
        var ids: [SessionID] = []
        for index in 0..<6 {
            env.clock.advance(by: 10)
            ids.append(try await env.sessions.start(in: workspace.id, title: "S\(index)").id)
        }
        _ = try await env.sessions.archive(ids[5])
        for index in 0..<5 {
            _ = try await env.workspaces.create(WorkspaceDraft(name: "W\(index)", kind: .custom))
        }

        let snapshot = try await make()
        #expect(snapshot.sessions.count == WidgetSnapshot.maximumSessions)
        #expect(!snapshot.sessions.map(\.id).contains(ids[5]))
        #expect(snapshot.workspaces.count == WidgetSnapshot.maximumWorkspaces)
    }

    @Test func storeRoundTripsAndToleratesBadFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)

        #expect(store.read() == .empty)

        let snapshot = WidgetSnapshot(
            generatedAt: Date(timeIntervalSinceReferenceDate: 500),
            sessions: [.init(id: SessionID(), title: "Trip", kind: .shopping, state: .active,
                             workspaceName: "Shop", itemCount: 3, lastActivityAt: Date(timeIntervalSinceReferenceDate: 400))]
        )
        try store.write(snapshot)
        #expect(store.read() == snapshot)

        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.read() == .empty)

        var future = snapshot
        future.version = WidgetSnapshot.currentVersion + 1
        try JSONEncoder().encode(future).write(to: store.fileURL)
        #expect(store.read() == .empty)
    }

    @Test func noAppGroupMeansNoStore() {
        #expect(WidgetSnapshotStore.shared(appGroupIdentifier: nil) == nil)
        #expect(WidgetSnapshotStore.shared(appGroupIdentifier: "") == nil)
    }
}
