import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

@Suite("NoteService")
struct NoteServiceTests {
    @Test func createUpdateAndOrder() async throws {
        let env = TestEnvironment()
        let workspace = WorkspaceID()
        let first = try await env.notes.create(title: " A ", body: "one", workspaceID: workspace)
        env.clock.advance(by: 5)
        let second = try await env.notes.create(body: "two", workspaceID: workspace)
        #expect(first.title == "A")
        #expect(try await env.notes.notes(in: workspace).map(\.id) == [second.id, first.id])

        env.clock.advance(by: 5)
        try await env.notes.setPinned(first.id, true)
        #expect(try await env.notes.notes(in: workspace).map(\.id) == [first.id, second.id])

        let updated = try await env.notes.update(second.id, title: "B", body: "edited")
        #expect(updated.body == "edited")
        #expect(updated.updatedAt == env.clock.now())
    }

    @Test func rejectsEmptyNotes() async throws {
        let env = TestEnvironment()
        await #expect(throws: TaskLensError.validationFailed(.emptyContent)) {
            try await env.notes.create(title: " ", body: "\n")
        }
    }

    @Test func unfiledNotesAreSeparate() async throws {
        let env = TestEnvironment()
        let unfiled = try await env.notes.create(body: "loose")
        try await env.notes.create(body: "filed", workspaceID: WorkspaceID())
        #expect(try await env.notes.notes(in: nil).map(\.id) == [unfiled.id])
    }
}

@Suite("ClipboardService")
struct ClipboardServiceTests {
    @Test func repeatedPasteRefreshesInsteadOfDuplicating() async throws {
        let env = TestEnvironment()
        let clipboard = env.clipboard()
        let first = try await clipboard.record(.text("0770 123 4567"), offeredTypes: ["public.utf8-plain-text"])
        env.clock.advance(by: 10)
        let again = try await clipboard.record(.text("0770 123 4567"))
        #expect(again.id == first.id)
        #expect(again.capturedAt == env.clock.now())
        #expect(again.offeredTypes == ["public.utf8-plain-text"])
        #expect(try await clipboard.history().count == 1)
    }

    @Test func historyIsBounded() async throws {
        let env = TestEnvironment()
        let clipboard = env.clipboard(historyLimit: 3)
        for index in 0..<5 {
            try await clipboard.record(.text("entry \(index)"))
            env.clock.advance(by: 1)
        }
        let history = try await clipboard.history()
        #expect(history.map(\.content) == [.text("entry 4"), .text("entry 3"), .text("entry 2")])
    }

    @Test func promoteCreatesContextItem() async throws {
        let env = TestEnvironment()
        let clipboard = env.clipboard()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)
        let entry = try await clipboard.record(.url(URL(string: "https://example.com")!))

        let item = try await clipboard.promote(entry.id, to: session.id)

        #expect(item.source == .clipboard)
        #expect(item.sessionID == session.id)
        #expect(try await clipboard.history().first?.promotedItemID == item.id)
    }

    @Test func clearRemovesEverything() async throws {
        let env = TestEnvironment()
        let clipboard = env.clipboard()
        try await clipboard.record(.text("a"))
        env.clock.advance(by: 1)
        try await clipboard.record(.text("b"))
        try await clipboard.clear()
        #expect(try await clipboard.history().isEmpty)
    }
}
