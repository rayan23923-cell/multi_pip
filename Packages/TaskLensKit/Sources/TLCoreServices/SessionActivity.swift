import Foundation
import TLDomain
import TLFoundation

/// What a session's Live Activity shows. Shared by the app (which requests
/// and updates the activity) and the widget extension (which draws it), so
/// it holds only plain values: no store access, no network.
public struct SessionActivityContent: Codable, Hashable, Sendable {
    /// Which presentation the Lock Screen and Dynamic Island use.
    public enum Mode: String, Codable, Hashable, Sendable {
        /// An ongoing session: elapsed time and what it collected.
        case session
        /// TaskLens is working on something for the session (with progress).
        case processing
        /// A focus timer the user started for the session.
        case timer
        /// The item the user marked important: the task at hand.
        case task
    }

    public var mode: Mode
    /// The session's own title; nil shows its kind ("Research Session").
    public var title: String?
    public var startedAt: Date
    public var links: Int
    public var notes: Int
    public var documents: Int
    public var items: Int
    public var focusEndsAt: Date?
    public var taskTitle: String?
    public var processingTitle: String?
    /// 0...1 when known.
    public var progress: Double?

    public init(
        mode: Mode = .session, title: String? = nil, startedAt: Date,
        links: Int = 0, notes: Int = 0, documents: Int = 0, items: Int = 0,
        focusEndsAt: Date? = nil, taskTitle: String? = nil,
        processingTitle: String? = nil, progress: Double? = nil
    ) {
        self.mode = mode
        self.title = title
        self.startedAt = startedAt
        self.links = links
        self.notes = notes
        self.documents = documents
        self.items = items
        self.focusEndsAt = focusEndsAt
        self.taskTitle = taskTitle
        self.processingTitle = processingTitle
        self.progress = progress
    }
}

/// Work TaskLens is doing for a session, shown in its Live Activity.
public struct SessionProcessing: Hashable, Sendable {
    public var title: String
    public var progress: Double?

    public init(title: String, progress: Double? = nil) {
        self.title = title
        self.progress = progress.map { min(max($0, 0), 1) }
    }
}

/// One Live Activity TaskLens wants to show.
public struct SessionActivityRequest: Hashable, Sendable {
    public var sessionID: SessionID
    public var kind: SessionKind
    public var workspaceName: String
    public var content: SessionActivityContent
    /// When the system should show the activity as out of date.
    public var staleDate: Date

    public init(sessionID: SessionID, kind: SessionKind, workspaceName: String, content: SessionActivityContent, staleDate: Date) {
        self.sessionID = sessionID
        self.kind = kind
        self.workspaceName = workspaceName
        self.content = content
        self.staleDate = staleDate
    }
}

/// A change to the running Live Activities.
public enum SessionActivityChange: Hashable, Sendable {
    case start(SessionActivityRequest)
    case update(SessionActivityRequest)
    case end(SessionID)
}

/// Decides which Live Activities should exist and how they look. Pure, so
/// every lifecycle case (start, update, end, timeout, relaunch, several
/// sessions) is tested without ActivityKit.
public enum SessionActivityPlanner {
    /// iOS limits how many activities an app runs; TaskLens shows the most recent few.
    public static let maximumActivities = 3
    /// With no activity for this long, the activity is marked stale.
    public static let staleAfter: TimeInterval = 2 * 60 * 60
    public static let maximumTitleLength = 60

    public static func content(
        for session: Session,
        items: [ContextItem],
        processing: SessionProcessing? = nil,
        now: Date
    ) -> SessionActivityContent {
        let counts = SessionContent.counts(items)
        var content = SessionActivityContent(
            title: session.title.flatMap { $0.isEmpty ? nil : String($0.prefix(maximumTitleLength)) },
            startedAt: session.startedAt,
            links: counts[.link, default: 0],
            notes: counts[.note, default: 0],
            documents: counts[.document, default: 0] + counts[.image, default: 0],
            items: items.count
        )
        let task = items
            .filter(SessionContent.isImportant)
            .max { $0.createdAt < $1.createdAt }
            .flatMap(summary)
        content.taskTitle = task

        if let processing {
            content.mode = .processing
            content.processingTitle = String(processing.title.prefix(maximumTitleLength))
            content.progress = processing.progress
        } else if let focusEndsAt = session.focusEndsAt, focusEndsAt > now {
            content.mode = .timer
            content.focusEndsAt = focusEndsAt
        } else if task != nil {
            content.mode = .task
        }
        return content
    }

    public static func staleDate(for session: Session, content: SessionActivityContent) -> Date {
        if content.mode == .timer, let focusEndsAt = content.focusEndsAt { return focusEndsAt }
        return session.lastActivityAt.addingTimeInterval(staleAfter)
    }

    /// Active, unarchived sessions, most recent first, up to the limit.
    public static func eligible(_ sessions: [Session]) -> [Session] {
        Array(sessions
            .filter { $0.isActive && !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
                return lhs.id.description < rhs.id.description
            }
            .prefix(maximumActivities))
    }

    /// What to change so the running activities match the wanted ones.
    /// Running activities whose session is no longer wanted (ended, paused,
    /// deleted, or left over after the app was closed) are ended.
    public static func changes(
        wanted: [SessionActivityRequest],
        running: [SessionID: SessionActivityContent]
    ) -> [SessionActivityChange] {
        var changes: [SessionActivityChange] = []
        let wantedIDs = Set(wanted.map(\.sessionID))
        for id in running.keys.sorted(by: { $0.description < $1.description }) where !wantedIDs.contains(id) {
            changes.append(.end(id))
        }
        for request in wanted {
            if let current = running[request.sessionID] {
                if current != request.content { changes.append(.update(request)) }
            } else {
                changes.append(.start(request))
            }
        }
        return changes
    }

    private static func summary(of item: ContextItem) -> String? {
        let text: String
        switch item.content {
        case .text(let value): text = value
        case .url(let url): text = url.host() ?? url.absoluteString
        case .file(let reference): text = reference.originalFilename ?? reference.relativePath
        }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : String(line.prefix(maximumTitleLength))
    }
}

/// Gathers the Live Activities TaskLens should show from the store.
public struct SessionActivityService: Sendable {
    private let workspaces: WorkspaceService
    private let sessions: SessionService
    private let capture: CaptureService
    private let clock: any DateProviding

    public init(workspaces: WorkspaceService, sessions: SessionService, capture: CaptureService, clock: any DateProviding = SystemDateProvider()) {
        self.workspaces = workspaces
        self.sessions = sessions
        self.capture = capture
        self.clock = clock
    }

    public func wanted(processing: [SessionID: SessionProcessing] = [:]) async throws -> [SessionActivityRequest] {
        let now = clock.now()
        let workspaces = try await workspaces.list()
        let names = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.name) })
        let active = try await sessions.activeSessions().filter { names[$0.workspaceID] != nil }
        var requests: [SessionActivityRequest] = []
        for session in SessionActivityPlanner.eligible(active) {
            let items = try await capture.items(in: session.id)
            let content = SessionActivityPlanner.content(for: session, items: items, processing: processing[session.id], now: now)
            requests.append(SessionActivityRequest(
                sessionID: session.id,
                kind: session.kind,
                workspaceName: names[session.workspaceID] ?? "",
                content: content,
                staleDate: SessionActivityPlanner.staleDate(for: session, content: content)
            ))
        }
        return requests
    }
}
