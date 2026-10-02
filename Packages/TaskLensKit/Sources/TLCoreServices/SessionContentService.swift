import Foundation
import TLDomain
import TLFoundation

/// Everything a session holds, and Resume.
///
/// A session gathers context items (notes, links, documents, images,
/// clipboard entries, calculations and their detected entities), the actions
/// run on them and their results, all with timestamps. Resume brings back
/// TaskLens's own state only: the workspace, the session's items, recent
/// context and the last tool position. It never claims to restore other apps.
public struct SessionContentService: Sendable {
    public static let recentContextLimit = 5

    /// One session with its workspace, items and action history.
    public struct Overview: Sendable, Equatable {
        public var session: Session
        public var workspace: Workspace
        /// Newest first.
        public var items: [ContextItem]
        /// Newest first.
        public var actions: [ActionRecord]
    }

    /// What Resume gives back.
    public struct Resumption: Sendable, Equatable {
        public var session: Session
        public var workspace: Workspace
        public var items: [ContextItem]
        /// The most recent items, to pick up where the user stopped.
        public var recentContext: [ContextItem]
        /// The last place in a TaskLens tool, when one was recorded.
        public var resumeState: SessionResumeState?
    }

    private let workspaces: any Repository<Workspace>
    private let sessionStore: any Repository<Session>
    private let contextItems: any Repository<ContextItem>
    private let notes: any Repository<Note>
    private let actionRecords: any Repository<ActionRecord>
    private let clock: any DateProviding
    private let logger: TLLogger

    public init(
        workspaces: any Repository<Workspace>,
        sessions: any Repository<Session>,
        contextItems: any Repository<ContextItem>,
        notes: any Repository<Note>,
        actionRecords: any Repository<ActionRecord>,
        clock: any DateProviding = SystemDateProvider(),
        logger: TLLogger = TLLogger(category: "sessions")
    ) {
        self.workspaces = workspaces
        self.sessionStore = sessions
        self.contextItems = contextItems
        self.notes = notes
        self.actionRecords = actionRecords
        self.clock = clock
        self.logger = logger
    }

    private var lifecycle: SessionService {
        SessionService(workspaces: workspaces, sessions: sessionStore, clock: clock, logger: logger)
    }

    // MARK: Reading

    public func overview(of id: SessionID) async throws -> Overview {
        let session = try await sessionStore.require(id: id)
        return Overview(
            session: session,
            workspace: try await workspaces.require(id: session.workspaceID),
            items: try await items(in: id),
            actions: try await actions(in: id)
        )
    }

    public func items(in id: SessionID) async throws -> [ContextItem] {
        SessionContent.sorted(try await contextItems.fetchAll(where: { $0.sessionID == id }), by: .recent)
    }

    public func actions(in id: SessionID) async throws -> [ActionRecord] {
        try await actionRecords.fetchAll(where: { $0.sessionID == id }).sorted { lhs, rhs in
            if lhs.performedAt != rhs.performedAt { return lhs.performedAt > rhs.performedAt }
            return lhs.id.description < rhs.id.description
        }
    }

    // MARK: Resume

    /// Makes the session active again (reopening it if it ended or was
    /// archived) and returns what the user needs to continue.
    public func resume(_ id: SessionID) async throws -> Resumption {
        let session: Session
        if try await sessionStore.require(id: id).isActive {
            session = try await lifecycle.recordActivity(id)
        } else {
            session = try await lifecycle.reopen(id)
        }
        let items = try await items(in: id)
        logger.info("Resumed session \(id) with \(items.count) items")
        return Resumption(
            session: session,
            workspace: try await workspaces.require(id: session.workspaceID),
            items: items,
            recentContext: Array(items.prefix(Self.recentContextLimit)),
            resumeState: session.resumeState
        )
    }

    /// Remembers the tool position for the active session of `workspaceID`
    /// (or the most recently active session when no workspace is given).
    /// Returns the session that was updated, if any.
    @discardableResult
    public func recordToolState(_ state: SessionResumeState, in workspaceID: WorkspaceID?) async throws -> Session? {
        guard var session = try await lifecycle.captureTarget(preferring: workspaceID) else { return nil }
        session.resumeState = state
        try session.recordActivity(at: state.updatedAt)
        try await sessionStore.upsert(session)
        return session
    }

    // MARK: Items and actions

    /// Marks an item as important, or clears the mark.
    @discardableResult
    public func setImportant(_ itemID: ContextItemID, _ isImportant: Bool) async throws -> ContextItem {
        var item = try await contextItems.require(id: itemID)
        if isImportant {
            item.metadata[SessionContent.importantKey] = .bool(true)
        } else {
            item.metadata[SessionContent.importantKey] = nil
        }
        try await contextItems.upsert(item)
        return item
    }

    /// Records an action the user ran on something in a session.
    @discardableResult
    public func record(
        _ actionType: ActionType,
        outcome: ActionRecord.Outcome,
        detail: String? = nil,
        itemID: ContextItemID? = nil,
        in sessionID: SessionID
    ) async throws -> ActionRecord {
        _ = try await sessionStore.require(id: sessionID)
        let record = ActionRecord(
            sessionID: sessionID, itemID: itemID, actionType: actionType, outcome: outcome,
            detail: detail, performedAt: clock.now()
        )
        try await actionRecords.upsert(record)
        return record
    }

    // MARK: Delete

    /// Deletes the session, its items and its action history. Notes saved
    /// into it stay in Notes and are only unlinked.
    public func delete(_ id: SessionID) async throws {
        _ = try await sessionStore.require(id: id)
        let itemIDs = try await contextItems.fetchAll(where: { $0.sessionID == id }).map(\.id)
        let recordIDs = try await actionRecords.fetchAll(where: { $0.sessionID == id }).map(\.id)
        let removed = Set(itemIDs)
        let linkedNotes = try await notes.fetchAll(where: { $0.sessionID == id }).map { note -> Note in
            var note = note
            note.sessionID = nil
            note.linkedItemIDs.removeAll { removed.contains($0) }
            return note
        }

        try await contextItems.delete(ids: itemIDs)
        try await actionRecords.delete(ids: recordIDs)
        try await notes.upsert(contentsOf: linkedNotes)
        try await sessionStore.delete(id: id)
        logger.info("Deleted session \(id) with \(itemIDs.count) items and \(recordIDs.count) actions")
    }
}

/// Lets a tool remember where the user is, for Resume. Failures are ignored:
/// remembering a position must never interrupt the tool.
public struct ToolStateRecorder: Sendable {
    private let service: SessionContentService
    private let clock: any DateProviding

    public init(service: SessionContentService, clock: any DateProviding = SystemDateProvider()) {
        self.service = service
        self.clock = clock
    }

    public func record(
        _ tool: WorkspaceTool,
        in workspaceID: WorkspaceID?,
        url: URL? = nil,
        documentID: DocumentID? = nil,
        page: Int? = nil,
        noteID: NoteID? = nil
    ) async {
        let state = SessionResumeState(
            tool: tool, url: url, documentID: documentID, page: page, noteID: noteID, updatedAt: clock.now()
        )
        _ = try? await service.recordToolState(state, in: workspaceID)
    }
}
