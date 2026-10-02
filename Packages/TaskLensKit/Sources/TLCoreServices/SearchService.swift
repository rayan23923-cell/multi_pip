import Foundation
import TLDomain
import TLFoundation

/// Local, offline search across workspaces, sessions and captured items.
///
/// Matching is case- and diacritic-insensitive and locale-aware
/// (`localizedStandardContains`), so Arabic text matches with or without tashkeel.
public struct SearchService: Sendable {
    public struct Results: Sendable, Equatable {
        public var workspaces: [Workspace] = []
        public var sessions: [Session] = []
        public var items: [ContextItem] = []

        public init(workspaces: [Workspace] = [], sessions: [Session] = [], items: [ContextItem] = []) {
            self.workspaces = workspaces
            self.sessions = sessions
            self.items = items
        }

        public var isEmpty: Bool { workspaces.isEmpty && sessions.isEmpty && items.isEmpty }
    }

    public static let defaultLimit = 25

    private let workspaces: any Repository<Workspace>
    private let sessions: any Repository<Session>
    private let contextItems: any Repository<ContextItem>

    public init(
        workspaces: any Repository<Workspace>,
        sessions: any Repository<Session>,
        contextItems: any Repository<ContextItem>
    ) {
        self.workspaces = workspaces
        self.sessions = sessions
        self.contextItems = contextItems
    }

    public func search(_ query: String, limit: Int = SearchService.defaultLimit) async throws -> Results {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Results() }

        let matchedWorkspaces = try await workspaces.fetchAll(where: { !$0.isArchived && $0.name.localizedStandardContains(query) })
            .sorted { $0.sortOrder < $1.sortOrder }
        let matchedSessions = try await sessions.fetchAll(where: { $0.title?.localizedStandardContains(query) == true })
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        let matchedItems = try await contextItems.fetchAll(where: { Self.searchableText(of: $0)?.localizedStandardContains(query) == true })
            .sorted { $0.createdAt > $1.createdAt }

        return Results(
            workspaces: Array(matchedWorkspaces.prefix(limit)),
            sessions: Array(matchedSessions.prefix(limit)),
            items: Array(matchedItems.prefix(limit))
        )
    }

    private static func searchableText(of item: ContextItem) -> String? {
        switch item.content {
        case .text(let text): text
        case .url(let url): url.absoluteString
        case .file(let reference): reference.originalFilename
        }
    }
}
