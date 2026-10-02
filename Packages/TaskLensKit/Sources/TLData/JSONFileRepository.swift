import Foundation
import TLDomain
import TLFoundation

/// Repository that keeps one JSON file per entity type.
///
/// This is the offline-first foundation store: simple, inspectable and fully
/// testable. Every write replaces the file atomically. It is intended for the
/// data volumes of the early phases; a database backend can replace it behind
/// the same `Repository` protocol when volumes grow.
public actor JSONFileRepository<Model: Entity>: Repository {
    /// Bumped when the on-disk envelope changes shape.
    public static var currentSchemaVersion: Int { 1 }

    public nonisolated let fileURL: URL
    private let logger: TLLogger
    private var cache: [Identifier<Model>: Model]?

    public init(directory: URL, logger: TLLogger = TLLogger(category: "persistence")) {
        self.fileURL = directory.appendingPathComponent("\(Model.entityName).json", isDirectory: false)
        self.logger = logger
    }

    public func fetch(id: Identifier<Model>) async throws -> Model? {
        try load()[id]
    }

    public func fetchAll() async throws -> [Model] {
        Array(try load().values)
    }

    public func upsert(_ model: Model) async throws {
        var models = try load()
        models[model.id] = model
        try save(models)
    }

    public func upsert(contentsOf models: [Model]) async throws {
        guard !models.isEmpty else { return }
        var current = try load()
        for model in models {
            current[model.id] = model
        }
        try save(current)
    }

    public func delete(id: Identifier<Model>) async throws {
        var models = try load()
        guard models.removeValue(forKey: id) != nil else { return }
        try save(models)
    }

    public func delete(ids: [Identifier<Model>]) async throws {
        var models = try load()
        var changed = false
        for id in ids {
            if models.removeValue(forKey: id) != nil {
                changed = true
            }
        }
        if changed {
            try save(models)
        }
    }

    // MARK: - File IO

    private struct Envelope: Codable {
        var schemaVersion: Int
        var items: [Model]
    }

    private func load() throws -> [Identifier<Model>: Model] {
        if let cache { return cache }

        let models: [Identifier<Model>: Model]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                if envelope.schemaVersion > Self.currentSchemaVersion {
                    logger.warning("\(Model.entityName) store has newer schema \(envelope.schemaVersion)")
                }
                models = Dictionary(envelope.items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            } catch {
                logger.error("Failed to read \(Model.entityName) store: \(error)")
                throw TaskLensError.persistenceFailed(operation: .read, details: "\(Model.entityName): \(error)")
            }
        } else {
            models = [:]
        }
        cache = models
        return models
    }

    private func save(_ models: [Identifier<Model>: Model]) throws {
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, items: Array(models.values))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: Self.writingOptions)
            cache = models
            logger.debug("Saved \(models.count) \(Model.entityName) records")
        } catch {
            logger.error("Failed to write \(Model.entityName) store: \(error)")
            throw TaskLensError.persistenceFailed(operation: .write, details: "\(Model.entityName): \(error)")
        }
    }

    private static var writingOptions: Data.WritingOptions {
        #if os(iOS)
        // Readable after first unlock so extensions and background tasks can use it.
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }
}
