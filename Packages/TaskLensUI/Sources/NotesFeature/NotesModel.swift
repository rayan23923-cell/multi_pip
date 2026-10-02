import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

/// Notes list for one workspace, or every note when `workspaceID` is `nil`.
@MainActor
@Observable
public final class NotesModel {
    public let workspaceID: WorkspaceID?
    public var query = ""
    public private(set) var notes: [Note] = []
    public private(set) var attachableSessions: [Session] = []
    public private(set) var hasLoaded = false
    public var errorMessage: String?

    private let noteService: NoteService
    private let toolCapture: ToolCaptureService
    private let stateRecorder: ToolStateRecorder?

    public init(
        workspaceID: WorkspaceID?,
        noteService: NoteService,
        toolCapture: ToolCaptureService,
        stateRecorder: ToolStateRecorder? = nil
    ) {
        self.workspaceID = workspaceID
        self.noteService = noteService
        self.toolCapture = toolCapture
        self.stateRecorder = stateRecorder
    }

    /// A note by id, for opening it directly (Resume).
    public func note(id: NoteID) async -> Note? {
        try? await noteService.note(id: id)
    }

    public var pinnedNotes: [Note] { notes.filter(\.isPinned) }
    public var otherNotes: [Note] { notes.filter { !$0.isPinned } }

    public func load() async {
        await perform {
            notes = try await noteService.search(query, in: workspaceID)
            hasLoaded = true
        }
    }

    /// Creates or updates a note. Returns false (with an error message) when invalid.
    @discardableResult
    public func save(_ editor: NoteEditorModel) async -> Bool {
        await perform {
            let note: Note
            if let id = editor.noteID {
                note = try await noteService.update(id, title: editor.title, body: editor.body)
            } else {
                note = try await noteService.create(title: editor.title, body: editor.body, workspaceID: workspaceID)
            }
            editor.didSave(note)
            try await reload()
            if let stateRecorder {
                await stateRecorder.record(.notes, in: workspaceID ?? note.workspaceID, noteID: note.id)
            }
        }
    }

    public func delete(_ id: NoteID) async {
        await perform {
            try await noteService.delete(id)
            try await reload()
        }
    }

    public func togglePin(_ id: NoteID) async {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        await perform {
            try await noteService.setPinned(id, !note.isPinned)
            try await reload()
        }
    }

    public func loadAttachableSessions() async {
        await perform {
            attachableSessions = try await toolCapture.attachableSessions(preferring: workspaceID)
        }
    }

    /// Saves the note as a context item in the session and links the two.
    @discardableResult
    public func attach(_ id: NoteID, to session: Session) async -> Bool {
        await perform {
            let note = try await noteService.note(id: id)
            let item = try await toolCapture.save(NoteService.output(for: note), into: session.id)
            try await noteService.attach(id, to: session, itemID: item.id)
            try await reload()
        }
    }

    public func sessionTitle(for id: SessionID?) -> String? {
        guard let id, let session = attachableSessions.first(where: { $0.id == id }) else { return nil }
        return session.title ?? L10n.string(.sessionUntitled)
    }

    private func reload() async throws {
        notes = try await noteService.search(query, in: workspaceID)
    }

    @discardableResult
    private func perform(_ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            return true
        } catch {
            errorMessage = L10n.message(for: error)
            return false
        }
    }
}

/// State of the note editor sheet. Produces a context item from what is typed.
@MainActor
@Observable
public final class NoteEditorModel: ContextProducing, Identifiable {
    public private(set) var noteID: NoteID?
    public var title: String
    public var body: String

    public init(note: Note? = nil) {
        noteID = note?.id
        title = note?.title ?? ""
        body = note?.body ?? ""
    }

    /// A new note holding text from the Action Engine (Create Note).
    public convenience init(draft: String) {
        self.init()
        body = draft
    }

    public var isNew: Bool { noteID == nil }

    public var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var toolOutput: ToolOutput? {
        guard canSave else { return nil }
        return NoteService.output(for: Note(id: noteID ?? NoteID(), title: title, body: body, createdAt: Date()))
    }

    func didSave(_ note: Note) {
        noteID = note.id
    }
}
