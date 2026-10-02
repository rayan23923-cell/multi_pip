import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

@MainActor
@Observable
public final class WorkspaceListModel {
    public private(set) var workspaces: [Workspace] = []
    public private(set) var hasLoaded = false
    public var errorMessage: String?

    private let service: WorkspaceService

    public init(service: WorkspaceService) {
        self.service = service
    }

    public func load() async {
        await perform { workspaces = try await service.list() }
        hasLoaded = true
    }

    /// Returns true when the workspace was created.
    @discardableResult
    public func create(_ draft: WorkspaceDraft) async -> Bool {
        await perform(reload: true) { _ = try await service.create(draft) }
    }

    @discardableResult
    public func update(_ id: WorkspaceID, with draft: WorkspaceDraft) async -> Bool {
        await perform(reload: true) { _ = try await service.update(id, with: draft) }
    }

    public func duplicate(_ workspace: Workspace) async {
        let name = L10n.format(.workspaceCopyName, workspace.name)
        await perform(reload: true) { _ = try await service.duplicate(workspace.id, name: name) }
    }

    public func delete(_ id: WorkspaceID) async {
        await perform(reload: true) { try await service.delete(id) }
    }

    public func toggleFavorite(_ workspace: Workspace) async {
        await perform(reload: true) { _ = try await service.setFavorite(workspace.id, !workspace.isFavorite) }
    }

    /// Applies a list move immediately, then persists it.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        workspaces.move(fromOffsets: source, toOffset: destination)
        let order = workspaces.map(\.id)
        await perform(reload: true) { try await service.reorder(order) }
    }

    @discardableResult
    private func perform(reload: Bool = false, _ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            if reload { workspaces = try await service.list() }
            return true
        } catch {
            errorMessage = L10n.message(for: error)
            if reload, let current = try? await service.list() { workspaces = current }
            return false
        }
    }
}
