import Foundation
import TLDomain
import TLFoundation

public struct NoteService: Sendable {
    public static let maximumTitleLength = 200

    private let noteStore: any Repository<Note>
    private let clock: any DateProviding
    private let logger: TLLogger

    public init(
        notes: any Repository<Note>,
        clock: any DateProviding = SystemDateProvider(),
        logger: TLLogger = TLLogger(category: "notes")
    ) {
        self.noteStore = notes
        self.clock = clock
        self.logger = logger
    }

    /// Notes in a workspace (or unfiled notes with `nil`): pinned first, then most recently edited.
    public func notes(in workspaceID: WorkspaceID?) async throws -> [Note] {
        try await noteStore.fetchAll(where: { $0.workspaceID == workspaceID }).sorted(by: Self.displayOrder)
    }

    public func note(id: NoteID) async throws -> Note {
        try await noteStore.require(id: id)
    }

    @discardableResult
    public func create(
        title: String = "",
        body: String = "",
        workspaceID: WorkspaceID? = nil,
        sessionID: SessionID? = nil,
        linkedItemIDs: [ContextItemID] = []
    ) async throws -> Note {
        let note = Note(
            workspaceID: workspaceID,
            sessionID: sessionID,
            title: try Self.validTitle(title),
            body: body,
            linkedItemIDs: linkedItemIDs,
            createdAt: clock.now()
        )
        guard !note.isEmpty else { throw TaskLensError.validationFailed(.emptyContent) }
        try await noteStore.upsert(note)
        logger.info("Created note \(note.id)")
        return note
    }

    @discardableResult
    public func update(_ id: NoteID, title: String, body: String) async throws -> Note {
        var note = try await noteStore.require(id: id)
        note.title = try Self.validTitle(title)
        note.body = body
        guard !note.isEmpty else { throw TaskLensError.validationFailed(.emptyContent) }
        note.updatedAt = clock.now()
        try await noteStore.upsert(note)
        return note
    }

    @discardableResult
    public func setPinned(_ id: NoteID, _ isPinned: Bool) async throws -> Note {
        var note = try await noteStore.require(id: id)
        note.isPinned = isPinned
        note.updatedAt = clock.now()
        try await noteStore.upsert(note)
        return note
    }

    public func delete(_ id: NoteID) async throws {
        try await noteStore.delete(id: id)
    }

    private static func validTitle(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumTitleLength else { throw TaskLensError.validationFailed(.nameTooLong) }
        return trimmed
    }

    private static func displayOrder(_ lhs: Note, _ rhs: Note) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        return lhs.updatedAt > rhs.updatedAt
    }
}
