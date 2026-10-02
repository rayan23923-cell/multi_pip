import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

@MainActor
@Observable
public final class CommandCenterModel {
    public static let recentItemLimit = 20

    public private(set) var activeSessions: [Session] = []
    public private(set) var workspaceNames: [WorkspaceID: String] = [:]
    public private(set) var recentItems: [ContextItem] = []
    public private(set) var hasLoaded = false
    public private(set) var isSaving = false
    public var draft = ""
    public var errorMessage: String?

    private let workspaceService: WorkspaceService
    private let sessionService: SessionService
    private let captureService: CaptureService

    public init(workspaceService: WorkspaceService, sessionService: SessionService, captureService: CaptureService) {
        self.workspaceService = workspaceService
        self.sessionService = sessionService
        self.captureService = captureService
    }

    /// Where quick capture saves: the most recently active session, else the inbox.
    public var captureTarget: Session? { activeSessions.first }

    public var isEmpty: Bool { activeSessions.isEmpty && recentItems.isEmpty }

    public func load() async {
        do {
            let workspaces = try await workspaceService.list(includeArchived: true)
            workspaceNames = Dictionary(workspaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            activeSessions = try await sessionService.activeSessions()
            recentItems = try await captureService.recentItems(limit: Self.recentItemLimit)
        } catch {
            errorMessage = L10n.message(for: error)
        }
        hasLoaded = true
    }

    public func captureDraft() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await captureService.capture(.text(draft), source: .manualEntry, into: captureTarget?.id)
            draft = ""
            await load()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }
}
