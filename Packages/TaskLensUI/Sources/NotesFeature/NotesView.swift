import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

public struct NotesView: View {
    @State private var model: NotesModel
    @State private var editor: NoteEditorModel?
    @State private var attaching: Note?
    @State private var pendingDeletion: Note?
    @State private var draft: String?
    @State private var openingNoteID: NoteID?
    @Environment(AppRouter.self) private var router

    /// `draft` opens the editor on a new note holding that text;
    /// `openingNote` opens an existing note (Resume).
    public init(model: NotesModel, draft: String? = nil, openingNote: NoteID? = nil) {
        _model = State(initialValue: model)
        _draft = State(initialValue: draft)
        _openingNoteID = State(initialValue: openingNote)
    }

    public var body: some View {
        List {
            if model.hasLoaded && model.notes.isEmpty && model.query.isEmpty {
                TLEmptyState(title: .notesEmptyTitle, message: .notesEmptyMessage, symbolName: "note.text")
                    .listRowBackground(Color.clear)
            }
            if !model.pinnedNotes.isEmpty {
                Section {
                    ForEach(model.pinnedNotes) { row($0) }
                } header: {
                    Text(L10nKey.notesPinned)
                }
            }
            if !model.otherNotes.isEmpty {
                Section {
                    ForEach(model.otherNotes) { row($0) }
                }
            }
        }
        .overlay {
            if model.hasLoaded && model.notes.isEmpty && !model.query.isEmpty {
                ContentUnavailableView.search(text: model.query)
            }
        }
        .navigationTitle(Text(L10nKey.workspaceToolNotes))
        .searchable(text: $model.query, prompt: Text(L10nKey.notesSearchPrompt))
        .task(id: model.query) { await model.load() }
        .task {
            if let text = draft {
                draft = nil
                editor = NoteEditorModel(draft: text)
            } else if let id = openingNoteID {
                openingNoteID = nil
                if let note = await model.note(id: id) { editor = NoteEditorModel(note: note) }
            }
        }
        .refreshable { await model.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = NoteEditorModel() } label: {
                    TLLabel(.notesNew, systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("notes.new")
            }
        }
        .sheet(item: $editor) { editor in
            NoteEditorView(model: editor) {
                await model.save(editor)
            }
        }
        .sheet(item: $attaching) { note in
            AttachSessionSheet(note: note, model: model)
        }
        .alert(
            Text(L10nKey.notesDeleteTitle),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { note in
            Button(role: .destructive) {
                Task { await model.delete(note.id) }
            } label: {
                Text(L10nKey.commonDelete)
            }
            Button(role: .cancel) {} label: { Text(L10nKey.commonCancel) }
        }
        .errorAlert(message: $model.errorMessage)
    }

    private func row(_ note: Note) -> some View {
        Button {
            editor = NoteEditorModel(note: note)
        } label: {
            NoteRow(note: note)
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("noteRow.\(note.title)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDeletion = note } label: {
                TLLabel(.commonDelete, systemImage: "trash")
            }
            Button { attaching = note } label: {
                TLLabel(.notesAttach, systemImage: "paperclip")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .leading) {
            Button { Task { await model.togglePin(note.id) } } label: {
                if note.isPinned {
                    TLLabel(.notesUnpin, systemImage: "pin.slash")
                } else {
                    TLLabel(.notesPin, systemImage: "pin")
                }
            }
            .tint(.orange)
        }
        .contextMenu {
            Button { Task { await model.togglePin(note.id) } } label: {
                if note.isPinned {
                    TLLabel(.notesUnpin, systemImage: "pin.slash")
                } else {
                    TLLabel(.notesPin, systemImage: "pin")
                }
            }
            .accessibilityIdentifier("note.pin")
            Button { attaching = note } label: { TLLabel(.notesAttach, systemImage: "paperclip") }
                .accessibilityIdentifier("note.attach")
            Button {
                router.keepInPiP(.output(NoteService.output(for: note), workspaceID: note.workspaceID))
            } label: {
                TLLabel(.pipKeep, systemImage: "pip.enter")
            }
            .accessibilityIdentifier("note.keepInPiP")
            Divider()
            Button(role: .destructive) { pendingDeletion = note } label: {
                TLLabel(.commonDelete, systemImage: "trash")
            }
            .accessibilityIdentifier("note.delete")
        }
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: TLSpacing.xxs) {
            HStack(spacing: TLSpacing.xs) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text(L10nKey.notesPinned))
                }
                if note.title.isEmpty {
                    Text(L10nKey.notesUntitled).font(.headline).foregroundStyle(.secondary)
                } else {
                    Text(note.title).font(.headline)
                }
                if note.sessionID != nil {
                    Image(systemName: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(L10nKey.notesAttached))
                }
            }
            if !note.body.isEmpty {
                Text(note.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(note.updatedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, TLSpacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

struct NoteEditorView: View {
    @Bindable var model: NoteEditorModel
    let onSave: () async -> Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    enum Field { case title, body }

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.string(.notesTitlePlaceholder), text: $model.title, axis: .vertical)
                    .font(.headline)
                    .focused($focusedField, equals: .title)
                    .accessibilityIdentifier("noteEditor.title")
                TextField(L10n.string(.notesBodyPlaceholder), text: $model.body, axis: .vertical)
                    .lineLimit(8...)
                    .focused($focusedField, equals: .body)
                    .accessibilityIdentifier("noteEditor.body")
            }
            .navigationTitle(Text(model.isNew ? L10nKey.notesNew : L10nKey.notesEdit))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(L10nKey.commonCancel) }
                        .accessibilityIdentifier("noteEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await onSave() { dismiss() }
                        }
                    } label: {
                        Text(L10nKey.commonSave)
                    }
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("noteEditor.save")
                }
            }
            .onAppear { if model.isNew { focusedField = .title } }
        }
    }
}

struct AttachSessionSheet: View {
    let note: Note
    let model: NotesModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.attachableSessions.isEmpty {
                    Text(L10nKey.notesNoSessions).foregroundStyle(.secondary)
                }
                ForEach(model.attachableSessions) { session in
                    Button {
                        Task {
                            if await model.attach(note.id, to: session) { dismiss() }
                        }
                    } label: {
                        HStack {
                            SessionRow(session: session)
                            if note.sessionID == session.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle(Text(L10nKey.notesAttach))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(L10nKey.commonCancel) }
                }
            }
            .task { await model.loadAttachableSessions() }
        }
    }
}
