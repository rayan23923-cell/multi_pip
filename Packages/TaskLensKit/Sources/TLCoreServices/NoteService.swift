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

    /// Every note across workspaces, pinned first.
    public func allNotes() async throws -> [Note] {
        try await noteStore.fetchAll().sorted(by: Self.displayOrder)
    }

    /// Notes whose title or body contains `query` (case, diacritic and locale aware).
    /// With a `workspaceID`, only that workspace's notes are searched.
    public func search(_ query: String, in workspaceID: WorkspaceID? = nil) async throws -> [Note] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope: [Note]
        if let workspaceID {
            scope = try await notes(in: workspaceID)
        } else {
            scope = try await allNotes()
        }
        guard !query.isEmpty else { return scope }
        return scope.filter { $0.title.localizedStandardContains(query) || $0.body.localizedStandardContains(query) }
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

    /// Links a note to a session and that session's workspace.
    /// `itemID` is the context item created from the note, if any.
    @discardableResult
    public func attach(_ id: NoteID, to session: Session, itemID: ContextItemID? = nil) async throws -> Note {
        var note = try await noteStore.require(id: id)
        note.sessionID = session.id
        note.workspaceID = session.workspaceID
        if let itemID, !note.linkedItemIDs.contains(itemID) {
            note.linkedItemIDs.append(itemID)
        }
        note.updatedAt = clock.now()
        try await noteStore.upsert(note)
        logger.info("Attached note \(note.id) to session \(session.id)")
        return note
    }

    public func delete(_ id: NoteID) async throws {
        try await noteStore.delete(id: id)
    }

    /// The note as a context item payload: title and body as text.
    public static func output(for note: Note) -> ToolOutput {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = [title, body].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return ToolOutput(
            tool: .notes,
            source: .notes,
            content: .text(String(text.prefix(ContextItem.maximumTextLength))),
            metadata: ["noteID": .string(note.id.description)]
        )
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
