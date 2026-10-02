import Foundation
import TLFoundation

/// Persistence abstraction. Services depend on this protocol only; the data
/// layer provides in-memory and file-backed implementations, and a database
/// backend can be added later without touching services or UI.
public protocol Repository<Model>: Sendable {
    associatedtype Model: Entity

    func fetch(id: Identifier<Model>) async throws -> Model?
    func fetchAll() async throws -> [Model]
    func upsert(_ model: Model) async throws
    func upsert(contentsOf models: [Model]) async throws
    func delete(id: Identifier<Model>) async throws
    func delete(ids: [Identifier<Model>]) async throws
}

extension Repository {
    public func fetchAll(where isIncluded: (Model) -> Bool) async throws -> [Model] {
        try await fetchAll().filter(isIncluded)
    }

    /// Fetches a model or throws `TaskLensError.notFound`.
    public func require(id: Identifier<Model>) async throws -> Model {
        guard let model = try await fetch(id: id) else {
            throw TaskLensError.notFound(entity: Model.entityName, id: id.uuidString)
        }
        return model
    }
}
