import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

@MainActor
@Observable
public final class WorkspaceDetailModel {
    public let workspaceID: WorkspaceID
    public private(set) var workspace: Workspace?
    public private(set) var sessions: [Session] = []
    public private(set) var hasLoaded = false
    public var errorMessage: String?

    private let workspaceService: WorkspaceService
    private let sessionService: SessionService

    public init(workspaceID: WorkspaceID, workspaceService: WorkspaceService, sessionService: SessionService) {
        self.workspaceID = workspaceID
        self.workspaceService = workspaceService
        self.sessionService = sessionService
    }

    public func load() async {
        do {
            workspace = try await workspaceService.workspace(id: workspaceID)
            sessions = try await sessionService.sessions(in: workspaceID)
        } catch {
            errorMessage = L10n.message(for: error)
        }
        hasLoaded = true
    }

    /// Starts a session and returns it so the view can navigate to it.
    public func startSession(kind: SessionKind) async -> Session? {
        do {
            let session = try await sessionService.start(in: workspaceID, kind: kind)
            await load()
            return session
        } catch {
            errorMessage = L10n.message(for: error)
            return nil
        }
    }
}
