import Foundation
import TLDomain
import TLFoundation

public struct WorkspaceService: Sendable {
    private let workspaces: any Repository<Workspace>
    private let sessions: any Repository<Session>
    private let contextItems: any Repository<ContextItem>
    private let documents: any Repository<Document>
    private let notes: any Repository<Note>
    private let clock: any DateProviding
    private let logger: TLLogger

    public init(
        workspaces: any Repository<Workspace>,
        sessions: any Repository<Session>,
        contextItems: any Repository<ContextItem>,
        documents: any Repository<Document>,
        notes: any Repository<Note>,
        clock: any DateProviding = SystemDateProvider(),
        logger: TLLogger = TLLogger(category: "workspaces")
    ) {
        self.workspaces = workspaces
        self.sessions = sessions
        self.contextItems = contextItems
        self.documents = documents
        self.notes = notes
        self.clock = clock
        self.logger = logger
    }

    /// Workspaces in display order.
    public func list(includeArchived: Bool = false) async throws -> [Workspace] {
        try await workspaces.fetchAll()
            .filter { includeArchived || !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.createdAt < rhs.createdAt
            }
    }

    public func workspace(id: WorkspaceID) async throws -> Workspace {
        try await workspaces.require(id: id)
    }

    @discardableResult
    public func create(
        name: String,
        color: WorkspaceColor = .blue,
        symbolName: String? = nil
    ) async throws -> Workspace {
        let validName = try Validation.name(name, maximumLength: Workspace.maximumNameLength)
        let existing = try await workspaces.fetchAll()
        let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        let workspace = Workspace(
            name: validName,
            symbolName: symbolName,
            color: color,
            sortOrder: nextOrder,
            createdAt: clock.now()
        )
        try await workspaces.upsert(workspace)
        logger.info("Created workspace \(workspace.id)")
        return workspace
    }

    @discardableResult
    public func rename(_ id: WorkspaceID, to name: String) async throws -> Workspace {
        var workspace = try await workspaces.require(id: id)
        workspace.name = try Validation.name(name, maximumLength: Workspace.maximumNameLength)
        workspace.updatedAt = clock.now()
        try await workspaces.upsert(workspace)
        return workspace
    }

    @discardableResult
    public func setArchived(_ id: WorkspaceID, _ isArchived: Bool) async throws -> Workspace {
        var workspace = try await workspaces.require(id: id)
        guard workspace.isArchived != isArchived else { return workspace }
        let now = clock.now()
        workspace.isArchived = isArchived
        workspace.updatedAt = now

        if isArchived {
            // An archived workspace has no running sessions.
            var paused: [Session] = []
            for var session in try await sessions.fetchAll(where: { $0.workspaceID == id && $0.isActive }) {
                try session.pause(at: now)
                paused.append(session)
            }
            try await sessions.upsert(contentsOf: paused)
        }

        try await workspaces.upsert(workspace)
        logger.info("Workspace \(id) archived=\(isArchived)")
        return workspace
    }

    /// Deletes the workspace and everything that belongs to it.
    public func delete(_ id: WorkspaceID) async throws {
        _ = try await workspaces.require(id: id)

        let sessionIDs = Set(try await sessions.fetchAll(where: { $0.workspaceID == id }).map(\.id))
        let itemIDs = try await contextItems.fetchAll(where: { item in
            item.workspaceID == id || item.sessionID.map { sessionIDs.contains($0) } == true
        }).map(\.id)
        let noteIDs = try await notes.fetchAll(where: { $0.workspaceID == id }).map(\.id)
        let documentIDs = try await documents.fetchAll(where: { $0.workspaceID == id }).map(\.id)

        try await contextItems.delete(ids: itemIDs)
        try await notes.delete(ids: noteIDs)
        try await documents.delete(ids: documentIDs)
        try await sessions.delete(ids: Array(sessionIDs))
        try await workspaces.delete(id: id)

        logger.info(
            "Deleted workspace \(id) with \(sessionIDs.count) sessions, \(itemIDs.count) items, "
                + "\(noteIDs.count) notes, \(documentIDs.count) documents"
        )
    }
}
