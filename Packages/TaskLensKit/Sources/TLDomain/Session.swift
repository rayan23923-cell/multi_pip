import Foundation
import TLFoundation

public typealias SessionID = Identifier<Session>

/// A bounded period of focused work inside a workspace.
/// Captured context items belong to a session.
public struct Session: Entity {
    public static let entityName = "session"

    public let id: SessionID
    public let workspaceID: WorkspaceID
    public var title: String?
    public var kind: SessionKind
    public private(set) var state: SessionState
    public let startedAt: Date
    public private(set) var endedAt: Date?
    public var lastActivityAt: Date
    public var metadata: Metadata
    /// Set when the user marked the session as a favorite.
    public private(set) var favoritedAt: Date?
    /// Set when the session was archived: ended and kept out of the main lists.
    public private(set) var archivedAt: Date?
    /// Where the user was in TaskLens's own tools, for Resume.
    public var resumeState: SessionResumeState?

    public init(
        id: SessionID = SessionID(),
        workspaceID: WorkspaceID,
        title: String? = nil,
        kind: SessionKind = .general,
        state: SessionState = .active,
        startedAt: Date,
        endedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        metadata: Metadata = [:]
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.kind = kind
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastActivityAt = lastActivityAt ?? startedAt
        self.metadata = metadata
    }

    public var isActive: Bool { state == .active }
    public var isEnded: Bool { state == .ended }
    public var isFavorite: Bool { favoritedAt != nil }
    public var isArchived: Bool { archivedAt != nil }

    // MARK: State transitions

    public mutating func pause(at date: Date) throws {
        guard state != .ended else { throw TaskLensError.invalidState(.sessionEnded) }
        state = .paused
        lastActivityAt = date
    }

    public mutating func resume(at date: Date) throws {
        guard state != .ended else { throw TaskLensError.invalidState(.sessionEnded) }
        state = .active
        lastActivityAt = date
    }

    public mutating func end(at date: Date) throws {
        guard state != .ended else { throw TaskLensError.invalidState(.sessionEnded) }
        state = .ended
        endedAt = date
        lastActivityAt = date
    }

    public mutating func setFavorite(_ isFavorite: Bool, at date: Date) {
        favoritedAt = isFavorite ? (favoritedAt ?? date) : nil
    }

    /// Archiving ends the session; it stays readable and searchable.
    public mutating func archive(at date: Date) {
        if state != .ended {
            state = .ended
            endedAt = date
        }
        archivedAt = date
        lastActivityAt = max(lastActivityAt, date)
    }

    public mutating func unarchive() {
        archivedAt = nil
    }

    /// Makes an ended or archived session active again, for Resume.
    public mutating func reopen(at date: Date) {
        archivedAt = nil
        endedAt = nil
        state = .active
        lastActivityAt = date
    }

    public mutating func recordActivity(at date: Date) throws {
        guard state != .ended else { throw TaskLensError.invalidState(.sessionEnded) }
        lastActivityAt = max(lastActivityAt, date)
    }
}

public enum SessionState: String, Codable, Sendable, CaseIterable {
    case active
    case paused
    case ended
}

/// What the session is for. Drives which actions are suggested later.
public struct SessionKind: ExtensibleKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let general: SessionKind = "general"
    public static let research: SessionKind = "research"
    public static let shopping: SessionKind = "shopping"
    public static let study: SessionKind = "study"
    public static let developer: SessionKind = "developer"

    public static let allKnown: [SessionKind] = [.general, .research, .shopping, .study, .developer]
}
