import AppIntents
import Foundation
import TLDomain
import TLLocalization

/// Workspace kinds Siri and Shortcuts can name ("Start Research Workspace").
enum WorkspaceKindOption: String, AppEnum {
    case study
    case research
    case work
    case shopping
    case developer

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent.type.workspaceKind")
    static let caseDisplayRepresentations: [WorkspaceKindOption: DisplayRepresentation] = [
        .study: DisplayRepresentation(title: "intent.workspaceKind.study", image: .init(systemName: "book.closed")),
        .research: DisplayRepresentation(title: "intent.workspaceKind.research", image: .init(systemName: "magnifyingglass")),
        .work: DisplayRepresentation(title: "intent.workspaceKind.work", image: .init(systemName: "briefcase")),
        .shopping: DisplayRepresentation(title: "intent.workspaceKind.shopping", image: .init(systemName: "cart")),
        .developer: DisplayRepresentation(title: "intent.workspaceKind.developer", image: .init(systemName: "chevron.left.forwardslash.chevron.right")),
    ]

    var kind: WorkspaceKind { WorkspaceKind(rawValue: rawValue) }
}

/// Session kinds Siri and Shortcuts can name ("Save to Shopping Session").
enum SessionKindOption: String, AppEnum {
    case general
    case research
    case shopping
    case study
    case developer

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent.type.sessionKind")
    static let caseDisplayRepresentations: [SessionKindOption: DisplayRepresentation] = [
        .general: "intent.sessionKind.general",
        .research: "intent.sessionKind.research",
        .shopping: "intent.sessionKind.shopping",
        .study: "intent.sessionKind.study",
        .developer: "intent.sessionKind.developer",
    ]

    var kind: SessionKind { SessionKind(rawValue: rawValue) }
}

/// A workspace as Siri and Shortcuts see it: an id and a name, nothing more.
struct WorkspaceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent.type.workspace")
    static let defaultQuery = WorkspaceEntityQuery()

    let id: UUID
    let name: String
    let kindName: String

    init(_ workspace: Workspace) {
        id = workspace.id.rawValue
        name = workspace.name
        kindName = L10n.string(L10nKey.workspaceKind(workspace.kind))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kindName)")
    }
}

struct WorkspaceEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [WorkspaceEntity] {
        let wanted = Set(identifiers)
        return try await Self.all().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WorkspaceEntity] {
        try await Self.all()
    }

    func entities(matching string: String) async throws -> [WorkspaceEntity] {
        try await Self.all().filter { $0.name.localizedStandardContains(string) }
    }

    /// Unarchived workspaces, most recently opened first.
    private static func all() async throws -> [WorkspaceEntity] {
        let container = await IntentDependencies.container
        let workspaces = try await container.workspaces.list()
        return workspaces
            .sorted { ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt) }
            .map(WorkspaceEntity.init)
    }
}

/// A session as Siri and Shortcuts see it.
struct SessionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent.type.session")
    static let defaultQuery = SessionEntityQuery()

    let id: UUID
    let title: String
    let workspaceName: String

    init(_ session: Session, workspaceName: String) {
        id = session.id.rawValue
        title = SessionEntity.title(of: session)
        self.workspaceName = workspaceName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(workspaceName)")
    }

    /// The session's own title, or its kind when it has none.
    static func title(of session: Session) -> String {
        if let title = session.title, !title.isEmpty { return title }
        return L10n.string(L10nKey.sessionKind(session.kind))
    }
}

struct SessionEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [SessionEntity] {
        let wanted = Set(identifiers)
        return try await Self.all().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SessionEntity] {
        Array(try await Self.all().prefix(20))
    }

    func entities(matching string: String) async throws -> [SessionEntity] {
        try await Self.all().filter {
            $0.title.localizedStandardContains(string) || $0.workspaceName.localizedStandardContains(string)
        }
    }

    /// Unarchived sessions in unarchived workspaces, most recent activity first.
    private static func all() async throws -> [SessionEntity] {
        let container = await IntentDependencies.container
        var entities: [(Date, SessionEntity)] = []
        for workspace in try await container.workspaces.list() {
            for session in try await container.sessions.sessions(in: workspace.id) where !session.isArchived {
                entities.append((session.lastActivityAt, SessionEntity(session, workspaceName: workspace.name)))
            }
        }
        return entities.sorted { $0.0 > $1.0 }.map(\.1)
    }
}
