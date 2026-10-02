import Foundation
import TLFoundation

/// Resolves where TaskLens keeps its data.
///
/// The preferred location is the App Group container so the app and its
/// extensions share one store. If the group is not available (for example an
/// unsigned simulator build), it falls back to the app's own Application Support.
public struct StoreLocation: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case appGroup
        case applicationSupport
        case custom
    }

    public let rootURL: URL
    public let kind: Kind

    public init(rootURL: URL, kind: Kind = .custom) {
        self.rootURL = rootURL
        self.kind = kind
    }

    /// Structured data (JSON stores).
    public var dataDirectory: URL { rootURL.appendingPathComponent("Data", isDirectory: true) }
    /// Imported files referenced by `FileReference.relativePath`.
    public var filesDirectory: URL { rootURL.appendingPathComponent("Files", isDirectory: true) }

    public static let directoryName = "TaskLens"

    public static func resolve(
        appGroupIdentifier: String?,
        fileManager: FileManager = .default,
        logger: TLLogger = TLLogger(category: "persistence")
    ) throws -> StoreLocation {
        if let appGroupIdentifier, !appGroupIdentifier.isEmpty,
           let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return StoreLocation(
                rootURL: container.appendingPathComponent(directoryName, isDirectory: true),
                kind: .appGroup
            )
        }

        logger.warning("App Group container unavailable; using Application Support")
        do {
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return StoreLocation(
                rootURL: support.appendingPathComponent(directoryName, isDirectory: true),
                kind: .applicationSupport
            )
        } catch {
            throw TaskLensError.persistenceFailed(operation: .locateStore, details: "\(error)")
        }
    }

    public func prepareDirectories(fileManager: FileManager = .default) throws {
        do {
            try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        } catch {
            throw TaskLensError.persistenceFailed(operation: .locateStore, details: "\(error)")
        }
    }
}
