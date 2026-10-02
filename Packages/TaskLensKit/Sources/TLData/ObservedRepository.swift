import Foundation
import TLDomain
import TLFoundation

/// Tells one listener that stored data changed. Signals that arrive while the
/// listener is busy collapse into one, so a burst of writes costs one refresh.
public final class StoreChangeSignal: Sendable {
    public let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    public init() {
        (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func signal() {
        continuation.yield()
    }
}

/// A repository that reports every write. Reads pass straight through.
public struct ObservedRepository<Model: Entity>: Repository {
    private let base: any Repository<Model>
    private let onChange: @Sendable () -> Void

    public init(_ base: any Repository<Model>, onChange: @escaping @Sendable () -> Void) {
        self.base = base
        self.onChange = onChange
    }

    public func fetch(id: Identifier<Model>) async throws -> Model? {
        try await base.fetch(id: id)
    }

    public func fetchAll() async throws -> [Model] {
        try await base.fetchAll()
    }

    public func upsert(_ model: Model) async throws {
        try await base.upsert(model)
        onChange()
    }

    public func upsert(contentsOf models: [Model]) async throws {
        try await base.upsert(contentsOf: models)
        onChange()
    }

    public func delete(id: Identifier<Model>) async throws {
        try await base.delete(id: id)
        onChange()
    }

    public func delete(ids: [Identifier<Model>]) async throws {
        try await base.delete(ids: ids)
        onChange()
    }
}

extension Repositories {
    /// The same store, signalling whenever sessions or their items change.
    /// Used to keep Live Activities and widgets in step with the data.
    public func observingSessions(_ signal: StoreChangeSignal) -> Repositories {
        let notify: @Sendable () -> Void = { signal.signal() }
        return Repositories(
            workspaces: ObservedRepository(workspaces, onChange: notify),
            sessions: ObservedRepository(sessions, onChange: notify),
            contextItems: ObservedRepository(contextItems, onChange: notify),
            documents: documents,
            notes: notes,
            clipboardItems: clipboardItems,
            calculations: calculations,
            actionRecords: actionRecords,
            pipCards: pipCards,
            pipPresentation: pipPresentation,
            aiRecords: aiRecords,
            workflows: workflows
        )
    }
}
