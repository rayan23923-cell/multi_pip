import Foundation
import Testing
import CommandCenterFeature
import SessionsFeature
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import TLLocalization
import WorkspacesFeature

@MainActor
struct Services {
    let repositories = Repositories.inMemory()
    let clock = ManualDateProvider(Date(timeIntervalSinceReferenceDate: 5_000))

    var workspaces: WorkspaceService {
        WorkspaceService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            contextItems: repositories.contextItems,
            documents: repositories.documents,
            notes: repositories.notes,
            clock: clock,
            logger: .disabled()
        )
    }

    var sessions: SessionService {
        SessionService(workspaces: repositories.workspaces, sessions: repositories.sessions, clock: clock, logger: .disabled())
    }

    var capture: CaptureService {
        CaptureService(sessions: repositories.sessions, contextItems: repositories.contextItems, clock: clock, logger: .disabled())
    }
}

@MainActor
@Suite("Feature view models")
struct FeatureModelTests {
    @Test func workspaceListCreatesAndReportsErrors() async {
        let services = Services()
        let model = WorkspaceListModel(service: services.workspaces)

        #expect(await model.create(name: "Study", color: .green))
        #expect(model.workspaces.map(\.name) == ["Study"])
        #expect(model.hasLoaded)

        #expect(await model.create(name: "  ", color: .blue) == false)
        #expect(model.errorMessage == L10n.string(.errorValidationEmptyName))
    }

    @Test func workspaceDetailStartsSessions() async throws {
        let services = Services()
        let workspace = try await services.workspaces.create(name: "W")
        let model = WorkspaceDetailModel(
            workspaceID: workspace.id,
            workspaceService: services.workspaces,
            sessionService: services.sessions
        )
        let session = try #require(await model.startSession(kind: .shopping))
        #expect(session.kind == .shopping)
        #expect(model.sessions.map(\.id) == [session.id])
        #expect(model.workspace?.name == "W")
    }

    @Test func sessionDetailCapturesAndEnds() async throws {
        let services = Services()
        let workspace = try await services.workspaces.create(name: "W")
        let session = try await services.sessions.start(in: workspace.id)
        let model = SessionDetailModel(sessionID: session.id, sessionService: services.sessions, captureService: services.capture)

        await model.load()
        model.draft = "0770 123 4567"
        await model.captureDraft()
        #expect(model.draft.isEmpty)
        #expect(model.items.count == 1)
        #expect(model.canCapture)

        await model.end()
        #expect(model.session?.isEnded == true)
        #expect(model.canCapture == false)
    }

    @Test func commandCenterCapturesIntoActiveSessionOrInbox() async throws {
        let services = Services()
        let model = CommandCenterModel(
            workspaceService: services.workspaces,
            sessionService: services.sessions,
            captureService: services.capture
        )

        await model.load()
        #expect(model.isEmpty)
        model.draft = "inbox note"
        await model.captureDraft()
        #expect(model.recentItems.first?.sessionID == nil)

        let workspace = try await services.workspaces.create(name: "W")
        let session = try await services.sessions.start(in: workspace.id)
        await model.load()
        #expect(model.captureTarget?.id == session.id)
        #expect(model.workspaceNames[workspace.id] == "W")

        services.clock.advance(by: 1)
        model.draft = "session note"
        await model.captureDraft()
        #expect(model.recentItems.first?.sessionID == session.id)
    }
}
