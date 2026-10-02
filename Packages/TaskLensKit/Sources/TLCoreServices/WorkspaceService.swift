import Foundation
import TLDomain
import TLFoundation

public struct WorkspaceService: Sendable {
    private let workspaces: any Repository<Workspace>
    private let sessions: any Repository<Session>
    private let contextItems: any Repository<ContextItem>
    private let documents: any Repository<Document>
    private let notes: any Repository<Note>
    private let actionRecords: (any Repository<ActionRecord>)?
    private let clock: any DateProviding
    private let logger: TLLogger

    public init(
        workspaces: any Repository<Workspace>,
        sessions: any Repository<Session>,
        contextItems: any Repository<ContextItem>,
        documents: any Repository<Document>,
        notes: any Repository<Note>,
        actionRecords: (any Repository<ActionRecord>)? = nil,
        clock: any DateProviding = SystemDateProvider(),
        logger: TLLogger = TLLogger(category: "workspaces")
    ) {
        self.workspaces = workspaces
        self.sessions = sessions
        self.contextItems = contextItems
        self.documents = documents
        self.notes = notes
        self.actionRecords = actionRecords
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

    /// Favorite workspaces in display order.
    public func favorites() async throws -> [Workspace] {
        try await list().filter(\.isFavorite)
    }

    /// Most recently opened workspaces first. Never-opened workspaces are excluded.
    public func recentlyOpened(limit: Int) async throws -> [Workspace] {
        let opened = try await list().filter { $0.lastOpenedAt != nil }
        return Array(opened.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .prefix(max(limit, 0)))
    }

    @discardableResult
    public func create(_ draft: WorkspaceDraft) async throws -> Workspace {
        let validName = try Validation.name(draft.name, maximumLength: Workspace.maximumNameLength)
        let existing = try await workspaces.fetchAll()
        let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        let workspace = Workspace(
            name: validName,
            kind: draft.kind,
            symbolName: draft.symbolName,
            color: draft.color,
            tools: Self.uniqued(draft.tools),
            settings: draft.settings,
            sortOrder: nextOrder,
            createdAt: clock.now()
        )
        try await workspaces.upsert(workspace)
        logger.info("Created workspace \(workspace.id) kind=\(draft.kind.rawValue)")
        return workspace
    }

    /// Convenience for code paths that only know a name.
    @discardableResult
    public func create(
        name: String,
        kind: WorkspaceKind = .custom,
        color: WorkspaceColor? = nil
    ) async throws -> Workspace {
        try await create(WorkspaceDraft(name: name, kind: kind, color: color))
    }

    /// Applies every editable field from `draft`.
    @discardableResult
    public func update(_ id: WorkspaceID, with draft: WorkspaceDraft) async throws -> Workspace {
        var workspace = try await workspaces.require(id: id)
        workspace.name = try Validation.name(draft.name, maximumLength: Workspace.maximumNameLength)
        workspace.kind = draft.kind
        workspace.symbolName = draft.symbolName
        workspace.color = draft.color
        workspace.tools = Self.uniqued(draft.tools)
        workspace.settings = draft.settings
        workspace.updatedAt = clock.now()
        try await workspaces.upsert(workspace)
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

    /// Copies a workspace's configuration (not its sessions or content) and
    /// places the copy right after the original.
    @discardableResult
    public func duplicate(_ id: WorkspaceID, name: String) async throws -> Workspace {
        let original = try await workspaces.require(id: id)
        let copy = Workspace(
            name: try Validation.name(name, maximumLength: Workspace.maximumNameLength),
            kind: original.kind,
            symbolName: original.symbolName,
            color: original.color,
            tools: original.tools,
            settings: original.settings,
            createdAt: clock.now(),
            metadata: original.metadata
        )
        var ordered = try await orderedAll()
        let index = ordered.firstIndex { $0.id == id }.map { $0 + 1 } ?? ordered.endIndex
        ordered.insert(copy, at: index)
        try await workspaces.upsert(contentsOf: Self.renumbered(ordered))
        logger.info("Duplicated workspace \(id) as \(copy.id)")
        return try await workspaces.require(id: copy.id)
    }

    /// Persists a new display order. IDs not listed keep their relative order after the listed ones.
    public func reorder(_ orderedIDs: [WorkspaceID]) async throws {
        let all = try await orderedAll()
        let position = Dictionary(orderedIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = all.filter { position[$0.id] != nil }.sorted { position[$0.id]! < position[$1.id]! }
        let rest = all.filter { position[$0.id] == nil }
        try await workspaces.upsert(contentsOf: Self.renumbered(listed + rest))
    }

    @discardableResult
    public func setFavorite(_ id: WorkspaceID, _ isFavorite: Bool) async throws -> Workspace {
        var workspace = try await workspaces.require(id: id)
        guard workspace.isFavorite != isFavorite else { return workspace }
        workspace.isFavorite = isFavorite
        workspace.updatedAt = clock.now()
        try await workspaces.upsert(workspace)
        return workspace
    }

    /// Records that the user opened the workspace and applies its
    /// "resume last session" setting.
    @discardableResult
    public func markOpened(_ id: WorkspaceID) async throws -> Workspace {
        var workspace = try await workspaces.require(id: id)
        let now = clock.now()
        workspace.lastOpenedAt = now
        try await workspaces.upsert(workspace)

        if workspace.settings.resumesLastSession && !workspace.isArchived {
            let owned = try await sessions.fetchAll(where: { $0.workspaceID == id })
            if !owned.contains(where: \.isActive),
               var last = owned.filter({ $0.state == .paused }).max(by: { $0.lastActivityAt < $1.lastActivityAt }) {
                try last.resume(at: now)
                try await sessions.upsert(last)
                logger.info("Resumed session \(last.id) on opening workspace \(id)")
            }
        }
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

    /// All workspaces, archived included, in display order.
    private func orderedAll() async throws -> [Workspace] {
        try await list(includeArchived: true)
    }

    private static func renumbered(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.enumerated().map { index, workspace in
            var workspace = workspace
            workspace.sortOrder = index
            return workspace
        }
    }

    private static func uniqued(_ tools: [WorkspaceTool]) -> [WorkspaceTool] {
        var seen = Set<WorkspaceTool>()
        return tools.filter { seen.insert($0).inserted }
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
        if let actionRecords {
            try await actionRecords.delete(ids: try await actionRecords.fetchAll(where: { sessionIDs.contains($0.sessionID) }).map(\.id))
        }
        try await sessions.delete(ids: Array(sessionIDs))
        try await workspaces.delete(id: id)

        logger.info(
            "Deleted workspace \(id) with \(sessionIDs.count) sessions, \(itemIDs.count) items, "
                + "\(noteIDs.count) notes, \(documentIDs.count) documents"
        )
    }
}
