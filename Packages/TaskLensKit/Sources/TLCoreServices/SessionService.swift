import Foundation
import TLDomain
import TLFoundation

/// Manages session lifecycle.
///
/// Rule: a workspace has at most one active session. Starting or resuming a
/// session pauses any other active session in the same workspace.
public struct SessionService: Sendable {
    public static let maximumTitleLength = 120

    private let workspaces: any Repository<Workspace>
    private let sessionStore: any Repository<Session>
    private let clock: any DateProviding
    private let logger: TLLogger

    public init(
        workspaces: any Repository<Workspace>,
        sessions: any Repository<Session>,
        clock: any DateProviding = SystemDateProvider(),
        logger: TLLogger = TLLogger(category: "sessions")
    ) {
        self.workspaces = workspaces
        self.sessionStore = sessions
        self.clock = clock
        self.logger = logger
    }

    public func session(id: SessionID) async throws -> Session {
        try await sessionStore.require(id: id)
    }

    /// Sessions in a workspace, most recently active first.
    public func sessions(in workspaceID: WorkspaceID) async throws -> [Session] {
        try await sessionStore.fetchAll(where: { $0.workspaceID == workspaceID })
            .sorted(by: Self.mostRecentFirst)
    }

    /// Active sessions across all workspaces, most recently active first.
    public func activeSessions() async throws -> [Session] {
        try await sessionStore.fetchAll(where: \.isActive).sorted(by: Self.mostRecentFirst)
    }

    /// Sessions that are not active or archived, most recently used first.
    public func recentSessions(limit: Int) async throws -> [Session] {
        Array(try await sessionStore.fetchAll(where: { !$0.isActive && !$0.isArchived })
            .sorted(by: Self.mostRecentFirst)
            .prefix(max(limit, 0)))
    }

    public func activeSession(in workspaceID: WorkspaceID) async throws -> Session? {
        try await sessionStore.fetchAll(where: { $0.workspaceID == workspaceID && $0.isActive })
            .sorted(by: Self.mostRecentFirst)
            .first
    }

    /// Where a tool should save: the active session of `workspaceID` when given,
    /// otherwise the most recently active session anywhere. `nil` means the inbox.
    public func captureTarget(preferring workspaceID: WorkspaceID?) async throws -> Session? {
        if let workspaceID, let session = try await activeSession(in: workspaceID) {
            return session
        }
        return try await activeSessions().first
    }

    @discardableResult
    public func start(
        in workspaceID: WorkspaceID,
        kind: SessionKind? = nil,
        title: String? = nil
    ) async throws -> Session {
        let workspace = try await workspaces.require(id: workspaceID)
        guard !workspace.isArchived else { throw TaskLensError.invalidState(.workspaceArchived) }
        let kind = kind ?? workspace.settings.defaultSessionKind

        let now = clock.now()
        let session = Session(
            workspaceID: workspaceID,
            title: try Validation.optionalTitle(title, maximumLength: Self.maximumTitleLength),
            kind: kind,
            startedAt: now
        )
        try await pauseOthers(in: workspaceID, except: session.id, at: now)
        try await sessionStore.upsert(session)
        logger.info("Started session \(session.id) kind=\(kind.rawValue)")
        return session
    }

    @discardableResult
    public func pause(_ id: SessionID) async throws -> Session {
        var session = try await sessionStore.require(id: id)
        try session.pause(at: clock.now())
        try await sessionStore.upsert(session)
        return session
    }

    @discardableResult
    public func resume(_ id: SessionID) async throws -> Session {
        var session = try await sessionStore.require(id: id)
        let workspace = try await workspaces.require(id: session.workspaceID)
        guard !workspace.isArchived else { throw TaskLensError.invalidState(.workspaceArchived) }

        let now = clock.now()
        try session.resume(at: now)
        try await pauseOthers(in: session.workspaceID, except: id, at: now)
        try await sessionStore.upsert(session)
        return session
    }

    @discardableResult
    public func end(_ id: SessionID) async throws -> Session {
        var session = try await sessionStore.require(id: id)
        try session.end(at: clock.now())
        try await sessionStore.upsert(session)
        logger.info("Ended session \(id)")
        return session
    }

    @discardableResult
    public func rename(_ id: SessionID, to title: String?) async throws -> Session {
        var session = try await sessionStore.require(id: id)
        session.title = try Validation.optionalTitle(title, maximumLength: Self.maximumTitleLength)
        try await sessionStore.upsert(session)
        return session
    }

    @discardableResult
    public func setFavorite(_ id: SessionID, _ isFavorite: Bool) async throws -> Session {
        var session = try await sessionStore.require(id: id)
        session.setFavorite(isFavorite, at: clock.now())
        try await sessionStore.upsert(session)
        return session
    }

    /// Ends the session if needed and moves it out of the main lists.
    @discardableResult
    public func archive(_ id: SessionID) async throws -> Session {
        var session = try await sessionStore.require(id: id)
        session.archive(at: clock.now())
        try await sessionStore.upsert(session)
        logger.info("Archived session \(id)")
        return session
    }

    @discardableResult
    public func unarchive(_ id: SessionID) async throws -> Session {
        var session = try await sessionStore.require(id: id)
        session.unarchive()
        try await sessionStore.upsert(session)
        return session
    }

    /// Makes any session active again: paused, ended or archived. The other
    /// active session of the workspace is paused.
    @discardableResult
    public func reopen(_ id: SessionID) async throws -> Session {
        var session = try await sessionStore.require(id: id)
        let workspace = try await workspaces.require(id: session.workspaceID)
        guard !workspace.isArchived else { throw TaskLensError.invalidState(.workspaceArchived) }
        let now = clock.now()
        session.reopen(at: now)
        try await pauseOthers(in: session.workspaceID, except: id, at: now)
        try await sessionStore.upsert(session)
        return session
    }

    /// Marks the session as just used. Ended sessions are rejected.
    @discardableResult
    public func recordActivity(_ id: SessionID) async throws -> Session {
        var session = try await sessionStore.require(id: id)
        try session.recordActivity(at: clock.now())
        try await sessionStore.upsert(session)
        return session
    }

    private func pauseOthers(in workspaceID: WorkspaceID, except id: SessionID, at date: Date) async throws {
        var paused: [Session] = []
        for var other in try await sessionStore.fetchAll(where: {
            $0.workspaceID == workspaceID && $0.isActive && $0.id != id
        }) {
            try other.pause(at: date)
            paused.append(other)
        }
        try await sessionStore.upsert(contentsOf: paused)
    }

    private static func mostRecentFirst(_ lhs: Session, _ rhs: Session) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
        return lhs.startedAt > rhs.startedAt
    }
}
