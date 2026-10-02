import Foundation
import TLDomain
import TLFoundation

/// Repository backed by a dictionary. Used for tests, previews and as a
/// fallback when the shared container cannot be opened.
public actor InMemoryRepository<Model: Entity>: Repository {
    private var storage: [Identifier<Model>: Model]

    public init(_ models: [Model] = []) {
        storage = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func fetch(id: Identifier<Model>) async throws -> Model? {
        storage[id]
    }

    public func fetchAll() async throws -> [Model] {
        Array(storage.values)
    }

    public func upsert(_ model: Model) async throws {
        storage[model.id] = model
    }

    public func upsert(contentsOf models: [Model]) async throws {
        for model in models {
            storage[model.id] = model
        }
    }

    public func delete(id: Identifier<Model>) async throws {
        storage[id] = nil
    }

    public func delete(ids: [Identifier<Model>]) async throws {
        for id in ids {
            storage[id] = nil
        }
    }
}
