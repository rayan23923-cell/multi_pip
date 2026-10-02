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
    /// Set after the workspace is deleted so the view can pop.
    public private(set) var isDeleted = false
    public var errorMessage: String?

    private let workspaceService: WorkspaceService
    private let sessionService: SessionService
    private var hasRecordedOpen = false

    public init(workspaceID: WorkspaceID, workspaceService: WorkspaceService, sessionService: SessionService) {
        self.workspaceID = workspaceID
        self.workspaceService = workspaceService
        self.sessionService = sessionService
    }

    public func load() async {
        do {
            if !hasRecordedOpen {
                // Recording the open may also resume the last session (workspace setting).
                workspace = try await workspaceService.markOpened(workspaceID)
                hasRecordedOpen = true
            } else {
                workspace = try await workspaceService.workspace(id: workspaceID)
            }
            sessions = try await sessionService.sessions(in: workspaceID)
        } catch {
            errorMessage = L10n.message(for: error)
        }
        hasLoaded = true
    }

    /// Starts a session with the workspace's default kind, or `kind` when given.
    public func startSession(kind: SessionKind? = nil) async -> Session? {
        do {
            let session = try await sessionService.start(in: workspaceID, kind: kind)
            await load()
            return session
        } catch {
            errorMessage = L10n.message(for: error)
            return nil
        }
    }

    @discardableResult
    public func update(with draft: WorkspaceDraft) async -> Bool {
        do {
            workspace = try await workspaceService.update(workspaceID, with: draft)
            return true
        } catch {
            errorMessage = L10n.message(for: error)
            return false
        }
    }

    public func toggleFavorite() async {
        guard let workspace else { return }
        do {
            self.workspace = try await workspaceService.setFavorite(workspaceID, !workspace.isFavorite)
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    /// Returns the copy so the view can open it.
    public func duplicate() async -> Workspace? {
        guard let workspace else { return nil }
        do {
            return try await workspaceService.duplicate(workspaceID, name: L10n.format(.workspaceCopyName, workspace.name))
        } catch {
            errorMessage = L10n.message(for: error)
            return nil
        }
    }

    public func delete() async {
        do {
            try await workspaceService.delete(workspaceID)
            isDeleted = true
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }
}
