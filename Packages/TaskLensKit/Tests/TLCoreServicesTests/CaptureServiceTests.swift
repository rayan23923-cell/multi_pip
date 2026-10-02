import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

@Suite("CaptureService")
struct CaptureServiceTests {
    @Test func captureIntoSessionSetsWorkspaceAndActivity() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)
        env.clock.advance(by: 30)

        let item = try await env.capture.capture(.text("$125"), source: .clipboard, into: session.id)

        #expect(item.sessionID == session.id)
        #expect(item.workspaceID == workspace.id)
        #expect(item.source == .clipboard)
        #expect(item.type == .text)
        #expect(try await env.sessions.session(id: session.id).lastActivityAt == env.clock.now())
        #expect(try await env.capture.items(in: session.id).map(\.id) == [item.id])
    }

    @Test func captureWithoutSessionGoesToInbox() async throws {
        let env = TestEnvironment()
        let item = try await env.capture.capture(.url(URL(string: "https://apple.com")!), source: .shareExtension)
        #expect(item.sessionID == nil)
        #expect(try await env.capture.inboxItems().map(\.id) == [item.id])
    }

    @Test func rejectsInvalidContent() async throws {
        let env = TestEnvironment()
        await #expect(throws: TaskLensError.validationFailed(.emptyContent)) {
            try await env.capture.capture(.text(" \n "), source: .manualEntry)
        }
        await #expect(throws: TaskLensError.validationFailed(.contentTooLarge)) {
            try await env.capture.capture(
                .text(String(repeating: "x", count: ContextItem.maximumTextLength + 1)),
                source: .manualEntry
            )
        }
        await #expect(throws: TaskLensError.validationFailed(.invalidURL)) {
            try await env.capture.capture(.url(URL(string: "no-scheme")!), source: .manualEntry)
        }
    }

    @Test func rejectsCaptureIntoEndedSession() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)
        try await env.sessions.end(session.id)
        await #expect(throws: TaskLensError.invalidState(.sessionEnded)) {
            try await env.capture.capture(.text("late"), source: .manualEntry, into: session.id)
        }
    }

    @Test func duplicatesWithinWindowAreMerged() async throws {
        let env = TestEnvironment()
        let first = try await env.capture.capture(.text("same"), source: .clipboard)
        env.clock.advance(by: 1)
        let second = try await env.capture.capture(.text("same"), source: .clipboard)
        #expect(first.id == second.id)

        env.clock.advance(by: CaptureService.defaultDuplicateWindow + 1)
        let third = try await env.capture.capture(.text("same"), source: .clipboard)
        #expect(third.id != first.id)
        #expect(try await env.capture.inboxItems().count == 2)
    }

    @Test func attachesDetectedEntities() async throws {
        let entity = DetectedEntity(type: .phoneNumber, confidence: .high, value: .phoneNumber("07701234567"))
        let env = TestEnvironment(detector: StubDetector(entities: [entity]))
        let item = try await env.capture.capture(.text("call 07701234567"), source: .manualEntry)
        #expect(item.entities == [entity])
    }

    @Test func detectorFailureDoesNotLoseContent() async throws {
        let env = TestEnvironment(detector: FailingDetector())
        let item = try await env.capture.capture(.text("keep me"), source: .manualEntry)
        #expect(item.entities.isEmpty)
        #expect(try await env.capture.item(id: item.id) == item)
    }

    @Test func moveBetweenSessionAndInbox() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "W")
        let session = try await env.sessions.start(in: workspace.id)
        let item = try await env.capture.capture(.text("x"), source: .manualEntry)

        let moved = try await env.capture.move(item.id, to: session.id)
        #expect(moved.sessionID == session.id)
        #expect(moved.workspaceID == workspace.id)

        let back = try await env.capture.move(item.id, to: nil)
        #expect(back.sessionID == nil)
        #expect(back.workspaceID == nil)
    }

    @Test func recentItemsAreNewestFirstAndLimited() async throws {
        let env = TestEnvironment()
        var ids: [ContextItemID] = []
        for index in 0..<4 {
            ids.append(try await env.capture.capture(.text("item \(index)"), source: .manualEntry).id)
            env.clock.advance(by: 1)
        }
        #expect(try await env.capture.recentItems(limit: 2).map(\.id) == [ids[3], ids[2]])
        #expect(try await env.capture.recentItems(limit: -1).isEmpty)
    }
}
