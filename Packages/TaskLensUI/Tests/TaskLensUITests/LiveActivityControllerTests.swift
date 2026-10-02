import Foundation
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
@testable import LiveActivitiesFeature
@testable import WidgetsFeature

/// Stands in for ActivityKit: remembers what is "on screen".
@MainActor
final class FakeLiveActivityClient: LiveActivityClient {
    var areActivitiesEnabled = true
    /// Simulates iOS refusing to start (app in the background, or too many activities).
    var refusesToStart = false
    private(set) var shown: [SessionID: SessionActivityContent] = [:]
    private(set) var started: [SessionID] = []
    private(set) var updated: [SessionID] = []
    private(set) var ended: [SessionID] = []

    struct Refused: Error {}

    func running() -> [SessionID: SessionActivityContent] { shown }

    func start(_ request: SessionActivityRequest) throws {
        if refusesToStart { throw Refused() }
        shown[request.sessionID] = request.content
        started.append(request.sessionID)
    }

    func update(_ request: SessionActivityRequest) async {
        shown[request.sessionID] = request.content
        updated.append(request.sessionID)
    }

    func end(_ sessionID: SessionID) async {
        shown[sessionID] = nil
        ended.append(sessionID)
    }

    /// An activity left on the Lock Screen by an earlier run of the app.
    func leftOver(_ sessionID: SessionID, content: SessionActivityContent) {
        shown[sessionID] = content
    }
}

@MainActor
final class Counter {
    var value = 0
}

@MainActor
@Suite("Live Activity controller")
struct LiveActivityControllerTests {
    let repositories = Repositories.inMemory()
    let clock = ManualDateProvider(Date(timeIntervalSinceReferenceDate: 50_000))
    let client = FakeLiveActivityClient()

    var workspaces: WorkspaceService {
        WorkspaceService(
            workspaces: repositories.workspaces, sessions: repositories.sessions, contextItems: repositories.contextItems,
            documents: repositories.documents, notes: repositories.notes, actionRecords: repositories.actionRecords,
            clock: clock, logger: .disabled()
        )
    }

    var sessions: SessionService {
        SessionService(workspaces: repositories.workspaces, sessions: repositories.sessions, clock: clock, logger: .disabled())
    }

    var capture: CaptureService {
        CaptureService(sessions: repositories.sessions, contextItems: repositories.contextItems, clock: clock, logger: .disabled())
    }

    func controller() -> LiveActivityController {
        LiveActivityController(
            service: SessionActivityService(workspaces: workspaces, sessions: sessions, capture: capture, clock: clock),
            client: client,
            logger: .disabled()
        )
    }

    @Test func startUpdateAndEndFollowTheSession() async throws {
        let controller = controller()
        let workspace = try await workspaces.create(WorkspaceDraft(name: "Research", kind: .research))
        let session = try await sessions.start(in: workspace.id)

        await controller.refresh()
        #expect(client.started == [session.id])
        #expect(client.shown[session.id]?.items == 0)

        _ = try await capture.capture(.url(URL(string: "https://apple.com")!), source: .browser, into: session.id)
        await controller.refresh()
        #expect(client.updated == [session.id])
        #expect(client.shown[session.id]?.links == 1)

        // Nothing changed: no needless update.
        await controller.refresh()
        #expect(client.updated == [session.id])

        _ = try await sessions.end(session.id)
        await controller.refresh()
        #expect(client.ended == [session.id])
        #expect(client.shown.isEmpty)
    }

    @Test func focusTimerSwitchesToTheTimerPresentation() async throws {
        let controller = controller()
        let workspace = try await workspaces.create(WorkspaceDraft(name: "Study", kind: .study))
        let session = try await sessions.start(in: workspace.id)
        await controller.refresh()

        _ = try await sessions.setFocus(session.id, minutes: 25)
        await controller.refresh()
        #expect(client.shown[session.id]?.mode == .timer)

        await controller.setProcessing(SessionProcessing(title: "Reading", progress: 0.5), for: session.id)
        #expect(client.shown[session.id]?.mode == .processing)
        await controller.setProcessing(nil, for: session.id)
        #expect(client.shown[session.id]?.mode == .timer)
    }

    @Test func severalSessionsGetTheirOwnActivities() async throws {
        let controller = controller()
        let first = try await workspaces.create(WorkspaceDraft(name: "A", kind: .research))
        let second = try await workspaces.create(WorkspaceDraft(name: "B", kind: .shopping))
        let a = try await sessions.start(in: first.id)
        clock.advance(by: 5)
        let b = try await sessions.start(in: second.id)

        await controller.refresh()
        #expect(Set(client.shown.keys) == [a.id, b.id])

        // Starting another session in the same workspace pauses `a`: its activity ends.
        clock.advance(by: 5)
        let c = try await sessions.start(in: first.id)
        await controller.refresh()
        #expect(Set(client.shown.keys) == [b.id, c.id])
        #expect(client.ended == [a.id])
    }

    @Test func relaunchCleansUpLeftOverActivities() async throws {
        // The app was closed (or the phone restarted) while activities were showing.
        let stale = SessionID()
        client.leftOver(stale, content: SessionActivityContent(startedAt: clock.now()))
        let workspace = try await workspaces.create(WorkspaceDraft(name: "W"))
        let session = try await sessions.start(in: workspace.id)
        client.leftOver(session.id, content: SessionActivityContent(startedAt: session.startedAt))

        await controller().refresh()
        #expect(client.ended == [stale])
        #expect(client.started.isEmpty)
        #expect(Set(client.shown.keys) == [session.id])
    }

    @Test func disabledOrRefusedActivitiesNeverBreakTheApp() async throws {
        let controller = controller()
        let workspace = try await workspaces.create(WorkspaceDraft(name: "W"))
        let session = try await sessions.start(in: workspace.id)

        client.areActivitiesEnabled = false
        await controller.refresh()
        #expect(client.started.isEmpty)
        #expect(!controller.isAvailable)

        client.areActivitiesEnabled = true
        client.refusesToStart = true
        await controller.refresh()
        #expect(client.started.isEmpty)
        #expect(controller.lastError != nil)

        // Back in the foreground, the next refresh starts it.
        client.refusesToStart = false
        await controller.refresh()
        #expect(client.started == [session.id])
    }

    @Test func followRefreshesOnStoreChanges() async throws {
        let signal = StoreChangeSignal()
        let observed = repositories.observingSessions(signal)
        let observedSessions = SessionService(workspaces: observed.workspaces, sessions: observed.sessions, clock: clock, logger: .disabled())
        let controller = controller()
        let refreshed = Counter()
        let task = Task { @MainActor in
            await controller.follow(signal) { refreshed.value += 1 }
        }
        let workspace = try await workspaces.create(WorkspaceDraft(name: "W"))
        let session = try await observedSessions.start(in: workspace.id)

        for _ in 0..<50 where client.started.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        #expect(client.started == [session.id])
        #expect(refreshed.value >= 1)
    }

    @Test func attributesCarryTheSession() {
        let id = SessionID()
        let attributes = SessionActivityAttributes(sessionID: id, kind: .research, workspaceName: "Thesis")
        #expect(attributes.sessionID == id)
        #expect(attributes.kind == .research)
    }
}
