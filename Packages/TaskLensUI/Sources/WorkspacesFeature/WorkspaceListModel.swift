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
        do {
            workspaces = try await service.list()
        } catch {
            errorMessage = L10n.message(for: error)
        }
        hasLoaded = true
    }

    /// Returns true when the workspace was created.
    @discardableResult
    public func create(name: String, color: WorkspaceColor) async -> Bool {
        do {
            try await service.create(name: name, color: color)
            await load()
            return true
        } catch {
            errorMessage = L10n.message(for: error)
            return false
        }
    }

    public func archive(_ id: WorkspaceID) async {
        do {
            try await service.setArchived(id, true)
        } catch {
            errorMessage = L10n.message(for: error)
        }
        await load()
    }

    public func delete(_ id: WorkspaceID) async {
        do {
            try await service.delete(id)
        } catch {
            errorMessage = L10n.message(for: error)
        }
        await load()
    }
}
