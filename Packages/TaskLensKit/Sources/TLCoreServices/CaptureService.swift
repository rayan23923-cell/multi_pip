import Foundation
import TLDomain
import TLFoundation

/// Turns user-provided content into stored `ContextItem`s.
///
/// This is the entry point of the CONTENT → CONTEXT pipeline. Entity detection
/// is delegated to an `EntityDetecting` implementation (a no-op until the
/// Context Engine phase).
public struct CaptureService: Sendable {
    /// Identical content captured into the same place within this window is
    /// treated as a duplicate (e.g. a double tap on paste).
    public static let defaultDuplicateWindow: TimeInterval = 5

    private let sessions: any Repository<Session>
    private let contextItems: any Repository<ContextItem>
    private let detector: any EntityDetecting
    private let clock: any DateProviding
    private let duplicateWindow: TimeInterval
    private let logger: TLLogger

    public init(
        sessions: any Repository<Session>,
        contextItems: any Repository<ContextItem>,
        detector: any EntityDetecting = NoEntityDetector(),
        clock: any DateProviding = SystemDateProvider(),
        duplicateWindow: TimeInterval = CaptureService.defaultDuplicateWindow,
        logger: TLLogger = TLLogger(category: "capture")
    ) {
        self.sessions = sessions
        self.contextItems = contextItems
        self.detector = detector
        self.clock = clock
        self.duplicateWindow = duplicateWindow
        self.logger = logger
    }

    /// Stores content. With no `sessionID` the item lands in the inbox.
    @discardableResult
    public func capture(
        _ content: ContextContent,
        source: ContextSource,
        into sessionID: SessionID? = nil,
        metadata: Metadata = [:]
    ) async throws -> ContextItem {
        let content = try Validation.content(content)
        let now = clock.now()

        var session: Session?
        if let sessionID {
            var target = try await sessions.require(id: sessionID)
            try target.recordActivity(at: now)
            session = target
        }

        if let duplicate = try await recentDuplicate(of: content, in: sessionID, now: now) {
            logger.debug("Ignored duplicate capture of \(content.logDescription)")
            return duplicate
        }

        let entities: [DetectedEntity]
        do {
            entities = try await detector.detectEntities(in: content)
        } catch {
            // Detection is an enhancement; a failure must not lose the user's content.
            logger.warning("Entity detection failed: \(error)")
            entities = []
        }

        let item = ContextItem(
            sessionID: sessionID,
            workspaceID: session?.workspaceID,
            source: source,
            content: content,
            entities: entities,
            metadata: metadata,
            createdAt: now
        )
        try await contextItems.upsert(item)
        if let session {
            try await sessions.upsert(session)
        }
        logger.info("Captured \(content.logDescription) from \(source.rawValue) with \(entities.count) entities")
        return item
    }

    /// Stores what a tool produced. Every tool saves through here.
    @discardableResult
    public func capture(_ output: ToolOutput, into sessionID: SessionID? = nil) async throws -> ContextItem {
        try await capture(output.content, source: output.source, into: sessionID, metadata: output.itemMetadata)
    }

    public func item(id: ContextItemID) async throws -> ContextItem {
        try await contextItems.require(id: id)
    }

    /// Items in a session, newest first.
    public func items(in sessionID: SessionID) async throws -> [ContextItem] {
        try await contextItems.fetchAll(where: { $0.sessionID == sessionID }).sorted(by: Self.newestFirst)
    }

    /// Items not attached to any session, newest first.
    public func inboxItems() async throws -> [ContextItem] {
        try await contextItems.fetchAll(where: { $0.sessionID == nil }).sorted(by: Self.newestFirst)
    }

    public func recentItems(limit: Int) async throws -> [ContextItem] {
        Array(try await contextItems.fetchAll().sorted(by: Self.newestFirst).prefix(max(limit, 0)))
    }

    /// Moves an item into a session, or back to the inbox with `nil`.
    @discardableResult
    public func move(_ id: ContextItemID, to sessionID: SessionID?) async throws -> ContextItem {
        var item = try await contextItems.require(id: id)
        if let sessionID {
            let session = try await sessions.require(id: sessionID)
            guard !session.isEnded else { throw TaskLensError.invalidState(.sessionEnded) }
            item.workspaceID = session.workspaceID
        } else {
            item.workspaceID = nil
        }
        item.sessionID = sessionID
        try await contextItems.upsert(item)
        return item
    }

    public func delete(_ id: ContextItemID) async throws {
        try await contextItems.delete(id: id)
    }

    private func recentDuplicate(
        of content: ContextContent,
        in sessionID: SessionID?,
        now: Date
    ) async throws -> ContextItem? {
        guard duplicateWindow > 0 else { return nil }
        let window = duplicateWindow
        return try await contextItems.fetchAll(where: { item in
            item.sessionID == sessionID
                && item.content == content
                && now.timeIntervalSince(item.createdAt) <= window
        })
        .sorted(by: Self.newestFirst)
        .first
    }

    private static func newestFirst(_ lhs: ContextItem, _ rhs: ContextItem) -> Bool {
        lhs.createdAt > rhs.createdAt
    }
}
