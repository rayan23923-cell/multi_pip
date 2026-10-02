import Foundation
import TLDomain
import TLFoundation

/// What Siri, Shortcuts, widgets and Live Activities can ask TaskLens to do.
///
/// App Intents stay thin and call this, so every system command runs the same
/// tested code as the app. Everything is on device; nothing needs a network.
public struct SystemActions: Sendable {
    private let workspaces: WorkspaceService
    private let sessions: SessionService
    private let capture: CaptureService
    private let notes: NoteService

    public init(workspaces: WorkspaceService, sessions: SessionService, capture: CaptureService, notes: NoteService) {
        self.workspaces = workspaces
        self.sessions = sessions
        self.capture = capture
        self.notes = notes
    }

    // MARK: Workspaces and sessions

    /// "Start Research Workspace": the most recently used workspace of that
    /// kind, or a new one named `name`. Marked as opened.
    @discardableResult
    public func startWorkspace(kind: WorkspaceKind, name: String) async throws -> Workspace {
        let existing = try await workspaces.list()
            .filter { $0.kind == kind }
            .max { ($0.lastOpenedAt ?? $0.createdAt) < ($1.lastOpenedAt ?? $1.createdAt) }
        let workspace: Workspace
        if let existing {
            workspace = existing
        } else {
            workspace = try await workspaces.create(WorkspaceDraft(name: name, kind: kind))
        }
        return try await workspaces.markOpened(workspace.id)
    }

    /// Starts a session in a workspace (its default kind unless `kind` is given).
    @discardableResult
    public func startSession(in workspaceID: WorkspaceID, kind: SessionKind? = nil) async throws -> Session {
        try await sessions.start(in: workspaceID, kind: kind)
    }

    /// Where "Save to Shopping Session" saves: the most recently used open
    /// session of that kind. Nil when there is none.
    public func session(ofKind kind: SessionKind) async throws -> Session? {
        let workspaces = try await workspaces.list()
        var candidates: [Session] = []
        for workspace in workspaces {
            candidates += try await sessions.sessions(in: workspace.id).filter { $0.kind == kind && !$0.isEnded }
        }
        return candidates.max { $0.lastActivityAt < $1.lastActivityAt }
    }

    /// The session "Save to Shopping Session" saves into: the most recently
    /// used open session of that kind, or a new one in a workspace of the
    /// matching kind (reused or created with `workspaceName`).
    public func sessionForSaving(kind: SessionKind, workspaceName: String) async throws -> Session {
        if let existing = try await session(ofKind: kind) { return existing }
        let workspaceKind = WorkspaceKind.allKnown.first { $0.rawValue == kind.rawValue } ?? .custom
        let workspace = try await startWorkspace(kind: workspaceKind, name: workspaceName)
        return try await startSession(in: workspace.id, kind: kind)
    }

    // MARK: Content

    /// Where saved content went.
    public enum Destination: Sendable, Equatable {
        case session(Session)
        case inbox
    }

    /// Saves text or a link. Into `sessionID` when given, otherwise into the
    /// active session, otherwise the inbox.
    @discardableResult
    public func save(_ text: String, into sessionID: SessionID? = nil) async throws -> (item: ContextItem, destination: Destination) {
        let content = ContentClassifier.classify(text)
        let target: Session?
        if let sessionID {
            target = try await sessions.session(id: sessionID)
        } else {
            target = try await sessions.captureTarget(preferring: nil)
        }
        if let target, !target.isEnded {
            let item = try await capture.capture(content, source: .appIntent, into: target.id)
            return (item, .session(try await sessions.session(id: target.id)))
        }
        let item = try await capture.capture(content, source: .appIntent)
        return (item, .inbox)
    }

    @discardableResult
    public func createNote(_ text: String) async throws -> Note {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TaskLensError.validationFailed(.emptyContent) }
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = lines.count > 1 ? String(lines[0]).trimmingCharacters(in: .whitespaces) : ""
        let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        let target = try await sessions.captureTarget(preferring: nil)
        return try await notes.create(
            title: String(title.prefix(NoteService.maximumTitleLength)),
            body: body,
            workspaceID: target?.workspaceID,
            sessionID: target?.id
        )
    }

    // MARK: Numbers

    /// "12*3+4" → 40, with the calculator's rules. Throws for anything else.
    public func calculate(_ expression: String) throws -> CalculatorEngine.Completion {
        guard let completion = CalculatorEngine.evaluate(expression) else {
            throw TaskLensError.validationFailed(.invalidExpression)
        }
        return completion
    }

    /// Converts with a rate the user gives. TaskLens has no live exchange
    /// rates: fetching them would need a network service, so it never guesses one.
    public func convert(_ amount: Decimal, rate: Decimal) throws -> Decimal {
        guard rate > 0 else { throw TaskLensError.validationFailed(.invalidExpression) }
        var product = amount * rate
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 4, .bankers)
        return rounded
    }
}
