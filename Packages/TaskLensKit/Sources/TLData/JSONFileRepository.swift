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

    /// Reads records one by one, so one record this version can't read (a
    /// damaged entry, or one written by a newer app) doesn't hide the rest.
    private struct LossyEnvelope: Decodable {
        var schemaVersion: Int
        var items: [Model]
        var skipped: Int

        private enum CodingKeys: String, CodingKey { case schemaVersion, items }
        /// Accepts any value, so the list moves past a record that didn't decode.
        private struct Skip: Decodable {
            init(from decoder: any Decoder) throws {}
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            var list = try container.nestedUnkeyedContainer(forKey: .items)
            var items: [Model] = []
            var skipped = 0
            while !list.isAtEnd {
                if let item = try? list.decode(Model.self) {
                    items.append(item)
                } else {
                    guard (try? list.decode(Skip.self)) != nil else { break }
                    skipped += 1
                }
            }
            self.items = items
            self.skipped = skipped
        }
    }

    private func load() throws -> [Identifier<Model>: Model] {
        if let cache { return cache }

        var models: [Identifier<Model>: Model] = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                // Not readable now (for example before first unlock): don't treat as empty.
                logger.error("Failed to read \(Model.entityName) store: \(error)")
                throw TaskLensError.persistenceFailed(operation: .read, details: "\(Model.entityName): \(error)")
            }
            do {
                let envelope = try JSONDecoder().decode(LossyEnvelope.self, from: data)
                if envelope.schemaVersion > Self.currentSchemaVersion {
                    logger.warning("\(Model.entityName) store has newer schema \(envelope.schemaVersion)")
                }
                if envelope.skipped > 0 {
                    logger.error("Skipped \(envelope.skipped) unreadable \(Model.entityName) record(s); kept a copy")
                    keepCopy(of: data)
                }
                models = Dictionary(envelope.items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            } catch {
                // A damaged file must not lock the user out: keep a copy and start over.
                logger.error("Unreadable \(Model.entityName) store, kept a copy: \(error)")
                keepCopy(of: data)
            }
        }
        cache = models
        return models
    }

    /// Next to the store, so nothing is lost and support can recover it.
    private func keepCopy(of data: Data) {
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        try? data.write(to: copy, options: Self.writingOptions)
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
