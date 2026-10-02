import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

@MainActor
@Observable
public final class CommandCenterModel {
    public static let recentItemLimit = 10
    public static let recentSessionLimit = 5
    public static let workspaceStripLimit = 8

    public private(set) var workspaces: [Workspace] = []
    /// Favorites first, then recently opened, then the rest; capped for the strip.
    public private(set) var featuredWorkspaces: [Workspace] = []
    public private(set) var activeSessions: [Session] = []
    public private(set) var recentSessions: [Session] = []
    public private(set) var recentItems: [ContextItem] = []
    public private(set) var searchResults = SearchService.Results()
    public private(set) var hasLoaded = false
    public private(set) var isSaving = false
    public var draft = ""
    public var query = ""
    public var errorMessage: String?

    private let workspaceService: WorkspaceService
    private let sessionService: SessionService
    private let captureService: CaptureService
    private let searchService: SearchService

    public init(
        workspaceService: WorkspaceService,
        sessionService: SessionService,
        captureService: CaptureService,
        searchService: SearchService
    ) {
        self.workspaceService = workspaceService
        self.sessionService = sessionService
        self.captureService = captureService
        self.searchService = searchService
    }

    /// Where quick capture saves: the most recently active session, else the inbox.
    public var captureTarget: Session? { activeSessions.first }

    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func workspaceName(for id: WorkspaceID) -> String? {
        workspaces.first { $0.id == id }?.name
    }

    public func load() async {
        do {
            workspaces = try await workspaceService.list()
            featuredWorkspaces = Self.featured(from: workspaces)
            activeSessions = try await sessionService.activeSessions()
            recentSessions = try await sessionService.recentSessions(limit: Self.recentSessionLimit)
            recentItems = try await captureService.recentItems(limit: Self.recentItemLimit)
        } catch {
            errorMessage = L10n.message(for: error)
        }
        hasLoaded = true
    }

    public func search() async {
        guard isSearching else {
            searchResults = SearchService.Results()
            return
        }
        do {
            searchResults = try await searchService.search(query)
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    public func captureDraft() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await captureService.capture(
                ContentClassifier.classify(draft),
                source: .manualEntry,
                into: captureTarget?.id
            )
            draft = ""
            await load()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    /// Creates a workspace from the quick action. Returns it so the view can open it.
    public func createWorkspace(_ draft: WorkspaceDraft) async -> Workspace? {
        do {
            let workspace = try await workspaceService.create(draft)
            await load()
            return workspace
        } catch {
            errorMessage = L10n.message(for: error)
            return nil
        }
    }

    /// Exposed for tests.
    public static func featuredForTesting(_ workspaces: [Workspace]) -> [Workspace] {
        featured(from: workspaces)
    }

    static func featured(from workspaces: [Workspace]) -> [Workspace] {
        let favorites = workspaces.filter(\.isFavorite)
        let opened = workspaces
            .filter { !$0.isFavorite && $0.lastOpenedAt != nil }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        let rest = workspaces.filter { !$0.isFavorite && $0.lastOpenedAt == nil }
        return Array((favorites + opened + rest).prefix(workspaceStripLimit))
    }
}
