import Foundation
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation

private let base = Date(timeIntervalSinceReferenceDate: 1_000)

private func item(
    _ content: ContextContent,
    source: ContextSource = .manualEntry,
    entities: [DetectedEntity] = [],
    metadata: Metadata = [:],
    at offset: TimeInterval
) -> ContextItem {
    ContextItem(source: source, content: content, entities: entities, metadata: metadata, createdAt: base.addingTimeInterval(offset))
}

private func price(_ amount: Decimal) -> DetectedEntity {
    DetectedEntity(type: .currencyAmount, confidence: .high, value: .currency(amount: amount, currencyCode: "USD"), matchedText: "$\(amount)")
}

private let pdf = ContextContent.file(FileReference(relativePath: "a/paper.pdf", originalFilename: "Paper.pdf", contentType: "com.adobe.pdf", kind: .pdf))
private let photo = ContextContent.file(FileReference(relativePath: "a/photo.jpg", contentType: "public.jpeg", kind: .image))

@Suite("Session content rules")
struct SessionContentRulesTests {
    @Test func kindsComeFromSourceThenContent() {
        #expect(SessionContent.kind(of: item(.text("x"), source: .notes, at: 0)) == .note)
        #expect(SessionContent.kind(of: item(.text("2+2"), source: .calculator, at: 0)) == .calculation)
        #expect(SessionContent.kind(of: item(.text("copied"), source: .clipboard, at: 0)) == .clipboard)
        #expect(SessionContent.kind(of: item(.url(URL(string: "https://apple.com")!), at: 0)) == .link)
        #expect(SessionContent.kind(of: item(pdf, at: 0)) == .document)
        #expect(SessionContent.kind(of: item(photo, at: 0)) == .image)
        #expect(SessionContent.kind(of: item(.text("What is entropy?"), at: 0)) == .question)
        #expect(SessionContent.kind(of: item(.text("ما هي الطاقة؟"), at: 0)) == .question)
        #expect(SessionContent.kind(of: item(.text("https://apple.com"), at: 0)) == .link)
        let code = DetectedEntity(type: .code, confidence: .high, value: .text("let x = 1"))
        #expect(SessionContent.kind(of: item(.text("let x = 1"), entities: [code], at: 0)) == .code)
        #expect(SessionContent.kind(of: item(.text("plain words"), at: 0)) == .text)
    }

    @Test func recentSortIsNewestFirst() {
        let old = item(.text("old"), at: 0), new = item(.text("new"), at: 10)
        #expect(SessionContent.sorted([old, new], by: .recent).map(\.id) == [new.id, old.id])
    }

    @Test func typeSortPutsTheSessionsFocusFirst() {
        let note = item(.text("n"), source: .notes, at: 30)
        let link = item(.url(URL(string: "https://a.com")!), at: 20)
        let document = item(pdf, at: 10)
        let study = SessionContent.sorted([link, note, document], by: .type, sessionKind: .study)
        #expect(study.map(\.id) == [document.id, note.id, link.id])
        let developer = SessionContent.sorted([document, note, link], by: .type, sessionKind: .developer)
        #expect(developer.first?.id == link.id)
    }

    @Test func importanceFollowsTheKindOfSession() {
        let product = item(.text("Headphones $125"), entities: [price(125)], at: 0)
        let thought = item(.text("Remember to compare"), at: 10)
        let shopping = SessionContent.sorted([thought, product], by: .importance, sessionKind: .shopping)
        #expect(shopping.first?.id == product.id)
        #expect(SessionContent.importance(of: product, in: .shopping) > SessionContent.importance(of: product, in: .general))
    }

    @Test func markedItemsComeFirst() {
        let document = item(pdf, at: 0)
        let marked = item(.text("key point"), metadata: [SessionContent.importantKey: .bool(true)], at: -100)
        let sorted = SessionContent.sorted([document, marked], by: .importance, sessionKind: .research)
        #expect(sorted.map(\.id) == [marked.id, document.id])
        #expect(SessionContent.isImportant(marked))
    }

    @Test func sortingIsDeterministic() {
        let items = (0..<6).map { item(.text("same \($0)"), at: 0) }
        let once = SessionContent.sorted(items, by: .importance)
        #expect(SessionContent.sorted(items.reversed(), by: .importance).map(\.id) == once.map(\.id))
    }

    @Test func searchFoldsCaseDiacriticsAndDigits() {
        let arabic = item(.text("مَدرسة القرية"), at: 0)
        let number = item(.text("Room 42"), at: 1)
        let file = item(pdf, at: 2)
        let link = item(.url(URL(string: "https://swift.org/docs")!), at: 3)
        let calculation = item(.text("12*3"), source: .calculator, metadata: ["result": .string("36")], at: 4)
        let all = [arabic, number, file, link, calculation]
        #expect(SessionContent.search(all, for: "مدرسة").map(\.id) == [arabic.id])
        #expect(SessionContent.search(all, for: "٤٢").map(\.id) == [number.id])
        #expect(SessionContent.search(all, for: "paper").map(\.id) == [file.id])
        #expect(SessionContent.search(all, for: "SWIFT.org").map(\.id) == [link.id])
        #expect(SessionContent.search(all, for: "36").map(\.id) == [calculation.id])
        #expect(SessionContent.search(all, for: "  ").count == all.count)
        #expect(SessionContent.search(all, for: "missing").isEmpty)
    }

    @Test func countsPerKind() {
        let counts = SessionContent.counts([item(pdf, at: 0), item(pdf, at: 1), item(.text("x"), source: .notes, at: 2)])
        #expect(counts == [.document: 2, .note: 1])
    }
}

@Suite("Smart sessions")
struct SmartSessionTests {
    @Test func favoriteArchiveAndUnarchive() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)

        #expect(try await env.sessions.setFavorite(session.id, true).isFavorite)
        let archived = try await env.sessions.archive(session.id)
        #expect(archived.isArchived && archived.isEnded)
        #expect(try await env.sessions.recentSessions(limit: 10).isEmpty)
        #expect(try await env.sessions.activeSessions().isEmpty)

        let restored = try await env.sessions.unarchive(session.id)
        #expect(!restored.isArchived && restored.isFavorite)
        #expect(try await env.sessions.recentSessions(limit: 10).map(\.id) == [session.id])
        #expect(try await env.sessions.setFavorite(session.id, false).isFavorite == false)
    }

    @Test func resumeReopensAnArchivedSessionWithRecentContext() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id, kind: .research)
        for index in 0..<7 {
            env.clock.advance(by: 10)
            try await env.capture.capture(.text("note \(index)"), source: .manualEntry, into: session.id)
        }
        let state = SessionResumeState(tool: .browser, url: URL(string: "https://swift.org"), updatedAt: env.clock.now())
        try await env.sessionContent.recordToolState(state, in: workspace.id)
        let other = try await env.sessions.start(in: workspace.id)
        try await env.sessions.archive(session.id)

        env.clock.advance(by: 60)
        let resumption = try await env.sessionContent.resume(session.id)
        #expect(resumption.session.isActive)
        #expect(!resumption.session.isArchived)
        #expect(resumption.session.lastActivityAt == env.clock.now())
        #expect(resumption.workspace.id == workspace.id)
        #expect(resumption.items.count == 7)
        #expect(resumption.recentContext.count == SessionContentService.recentContextLimit)
        #expect(resumption.recentContext.first?.content == .text("note 6"))
        #expect(resumption.resumeState == state)
        // Only one active session per workspace.
        #expect(try await env.sessions.session(id: other.id).state == .paused)
    }

    @Test func resumingAnActiveSessionKeepsItActive() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)
        env.clock.advance(by: 5)
        let resumption = try await env.sessionContent.resume(session.id)
        #expect(resumption.session.isActive)
        #expect(resumption.session.lastActivityAt == env.clock.now())
        #expect(resumption.resumeState == nil)
    }

    @Test func toolStateGoesToTheActiveSession() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        #expect(try await env.sessionContent.recordToolState(
            SessionResumeState(tool: .notes, updatedAt: env.clock.now()), in: workspace.id
        ) == nil)

        let session = try await env.sessions.start(in: workspace.id)
        let recorder = ToolStateRecorder(service: env.sessionContent, clock: env.clock)
        let document = DocumentID()
        await recorder.record(.documents, in: workspace.id, documentID: document, page: 3)
        let stored = try await env.sessions.session(id: session.id)
        #expect(stored.resumeState?.tool == .documents)
        #expect(stored.resumeState?.documentID == document)
        #expect(stored.resumeState?.page == 3)
    }

    @Test func actionsAreRecordedNewestFirst() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)
        try await env.sessionContent.record(.copy, outcome: .completed, detail: "x", in: session.id)
        env.clock.advance(by: 1)
        try await env.sessionContent.record(.call, outcome: .handedOff, detail: String(repeating: "9", count: 500), in: session.id)
        let actions = try await env.sessionContent.actions(in: session.id)
        #expect(actions.map(\.actionType) == [.call, .copy])
        #expect(actions.first?.detail?.count == ActionRecord.maximumDetailLength)
        await #expect(throws: TaskLensError.self) {
            try await env.sessionContent.record(.copy, outcome: .completed, in: SessionID())
        }
    }

    @Test func markingImportantPersists() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)
        let captured = try await env.capture.capture(.text("key"), source: .manualEntry, into: session.id)
        #expect(SessionContent.isImportant(try await env.sessionContent.setImportant(captured.id, true)))
        #expect(SessionContent.isImportant(try #require(try await env.sessionContent.items(in: session.id).first)))
        #expect(!SessionContent.isImportant(try await env.sessionContent.setImportant(captured.id, false)))
    }

    @Test func deleteRemovesItemsAndActionsButKeepsNotes() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)
        let keep = try await env.sessions.start(in: workspace.id)
        let captured = try await env.capture.capture(.text("in session"), source: .manualEntry, into: session.id)
        let kept = try await env.capture.capture(.text("other session"), source: .manualEntry, into: keep.id)
        try await env.sessionContent.record(.copy, outcome: .completed, in: session.id)
        let note = Note(workspaceID: workspace.id, sessionID: session.id, body: "mine", linkedItemIDs: [captured.id, kept.id], createdAt: env.clock.now())
        try await env.repositories.notes.upsert(note)

        try await env.sessionContent.delete(session.id)

        #expect(try await env.repositories.sessions.fetchAll().map(\.id) == [keep.id])
        #expect(try await env.repositories.contextItems.fetchAll().map(\.id) == [kept.id])
        #expect(try await env.repositories.actionRecords.fetchAll().isEmpty)
        let storedNote = try await env.repositories.notes.require(id: note.id)
        #expect(storedNote.sessionID == nil)
        #expect(storedNote.linkedItemIDs == [kept.id])
    }

    @Test func deletingTheWorkspaceRemovesActionHistory() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)
        try await env.sessionContent.record(.copy, outcome: .completed, in: session.id)
        try await env.workspaces.delete(workspace.id)
        #expect(try await env.repositories.actionRecords.fetchAll().isEmpty)
    }
}

@Suite("Smart session persistence")
struct SmartSessionPersistenceTests {
    @Test func sessionsItemsAndActionsSurviveARelaunch() async throws {
        let location = StoreLocation(rootURL: TemporaryDirectory.make())
        let clock = ManualDateProvider(base)
        let first = try Repositories.fileBacked(at: location, logger: .disabled())
        let sessions = SessionService(workspaces: first.workspaces, sessions: first.sessions, clock: clock, logger: .disabled())
        let content = SessionContentService(
            workspaces: first.workspaces, sessions: first.sessions, contextItems: first.contextItems,
            notes: first.notes, actionRecords: first.actionRecords, clock: clock, logger: .disabled()
        )
        let workspace = Workspace(name: "Research", createdAt: base)
        try await first.workspaces.upsert(workspace)
        let session = try await sessions.start(in: workspace.id, kind: .research)
        try await sessions.rename(session.id, to: "Thesis")
        try await sessions.setFavorite(session.id, true)
        let captured = ContextItem(sessionID: session.id, workspaceID: workspace.id, source: .manualEntry, content: .text("source"), createdAt: base)
        try await first.contextItems.upsert(captured)
        try await content.setImportant(captured.id, true)
        try await content.record(.copy, outcome: .completed, detail: "source", itemID: captured.id, in: session.id)
        let state = SessionResumeState(tool: .documents, documentID: DocumentID(), page: 4, updatedAt: base)
        try await content.recordToolState(state, in: workspace.id)
        try await sessions.archive(session.id)

        let second = try Repositories.fileBacked(at: location, logger: .disabled())
        let reloaded = SessionContentService(
            workspaces: second.workspaces, sessions: second.sessions, contextItems: second.contextItems,
            notes: second.notes, actionRecords: second.actionRecords, clock: clock, logger: .disabled()
        )
        let overview = try await reloaded.overview(of: session.id)
        #expect(overview.session.title == "Thesis")
        #expect(overview.session.isFavorite)
        #expect(overview.session.isArchived)
        #expect(overview.session.resumeState == state)
        #expect(overview.items.map(\.id) == [captured.id])
        #expect(SessionContent.isImportant(try #require(overview.items.first)))
        #expect(overview.actions.map(\.actionType) == [.copy])
        #expect(overview.actions.first?.itemID == captured.id)

        let resumed = try await reloaded.resume(session.id)
        #expect(resumed.session.isActive)
        #expect(resumed.resumeState == state)
    }

    @Test func sessionsSavedBeforeSmartSessionsStillLoad() throws {
        let workspaceID = WorkspaceID()
        let session = Session(workspaceID: workspaceID, title: "Old", kind: .study, startedAt: base)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        for key in ["favoritedAt", "archivedAt", "resumeState"] { object[key] = nil }
        let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.id == session.id)
        #expect(!decoded.isFavorite && !decoded.isArchived && decoded.resumeState == nil)
    }
}
