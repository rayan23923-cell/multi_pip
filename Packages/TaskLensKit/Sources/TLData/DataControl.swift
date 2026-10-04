import Foundation
import TLDomain
import TLFoundation

/// The user's own copy of everything TaskLens keeps, and "delete everything".
/// Both run on the device; the export is a file the user chooses to share.
public struct DataControl: Sendable {
    private let repositories: Repositories
    private let filesDirectory: URL
    /// Other folders TaskLens writes to, such as the share extension's outbox.
    private let otherDirectories: [URL]

    public init(repositories: Repositories, filesDirectory: URL, otherDirectories: [URL] = []) {
        self.repositories = repositories
        self.filesDirectory = filesDirectory
        self.otherDirectories = otherDirectories
    }

    /// Everything as one JSON file. Imported files (PDFs, images) stay in
    /// TaskLens; the export lists them by name.
    public struct Export: Encodable {
        public static let formatVersion = 1
        public var formatVersion = Export.formatVersion
        public var exportedAt: Date
        public var workspaces: [Workspace]
        public var sessions: [Session]
        public var items: [ContextItem]
        public var notes: [Note]
        public var documents: [Document]
        public var clipboard: [ClipboardItem]
        public var calculations: [CalculationRecord]
        public var actionHistory: [ActionRecord]
        public var pictureInPictureCards: [PiPCard]
        public var aiHistory: [AIRecord]
        public var workflows: [Workflow]
        public var presentationSessions: [PresentationSession]
    }

    public func makeExport(now: Date) async throws -> Export {
        Export(
            exportedAt: now,
            workspaces: try await repositories.workspaces.fetchAll(),
            sessions: try await repositories.sessions.fetchAll(),
            items: try await repositories.contextItems.fetchAll(),
            notes: try await repositories.notes.fetchAll(),
            documents: try await repositories.documents.fetchAll(),
            clipboard: try await repositories.clipboardItems.fetchAll(),
            calculations: try await repositories.calculations.fetchAll(),
            actionHistory: try await repositories.actionRecords.fetchAll(),
            pictureInPictureCards: try await repositories.pipCards.fetchAll(),
            aiHistory: try await repositories.aiRecords.fetchAll(),
            workflows: try await repositories.workflows.fetchAll(),
            presentationSessions: try await repositories.presentationSessions.fetchAll()
        )
    }

    /// Writes the export into `directory` and returns the file.
    public func export(to directory: URL, now: Date = Date()) async throws -> URL {
        let export = try await makeExport(now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = directory.appendingPathComponent("TaskLens Export \(formatter.string(from: now)).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(export).write(to: url, options: Self.writingOptions)
        } catch {
            throw TaskLensError.persistenceFailed(operation: .write, details: "export: \(error)")
        }
        return url
    }

    /// Deletes every record and every imported file. Can't be undone.
    public func deleteEverything() async throws {
        try await Self.clear(repositories.contextItems)
        try await Self.clear(repositories.sessions)
        try await Self.clear(repositories.workspaces)
        try await Self.clear(repositories.notes)
        try await Self.clear(repositories.documents)
        try await Self.clear(repositories.clipboardItems)
        try await Self.clear(repositories.calculations)
        try await Self.clear(repositories.actionRecords)
        try await Self.clear(repositories.pipCards)
        try await Self.clear(repositories.pipPresentation)
        try await Self.clear(repositories.aiRecords)
        try await Self.clear(repositories.workflows)
        try await Self.clear(repositories.presentationSessions)
        for directory in [filesDirectory] + otherDirectories {
            Self.removeContents(of: directory)
        }
    }

    private static var writingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }

    private static func clear<Model: Entity>(_ repository: any Repository<Model>) async throws {
        let ids = try await repository.fetchAll().map(\.id)
        try await repository.delete(ids: ids)
    }

    private static func removeContents(of directory: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }
}
