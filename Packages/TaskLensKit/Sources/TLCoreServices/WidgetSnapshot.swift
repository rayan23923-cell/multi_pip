import Foundation
import TLDomain
import TLFoundation

/// The little a widget shows, written by the app into the shared App Group
/// container. Widgets read this file only: they never open the app's store
/// and never use the network.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let maximumSessions = 4
    public static let maximumWorkspaces = 3

    public struct WorkspaceSummary: Codable, Sendable, Equatable, Identifiable {
        public var id: WorkspaceID
        public var name: String
        public var kind: WorkspaceKind
        public var symbolName: String
        public var color: WorkspaceColor
        public var activeSessionCount: Int

        public init(id: WorkspaceID, name: String, kind: WorkspaceKind, symbolName: String, color: WorkspaceColor, activeSessionCount: Int) {
            self.id = id
            self.name = name
            self.kind = kind
            self.symbolName = symbolName
            self.color = color
            self.activeSessionCount = activeSessionCount
        }
    }

    public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
        public var id: SessionID
        public var title: String?
        public var kind: SessionKind
        public var state: SessionState
        public var workspaceName: String
        public var itemCount: Int
        public var lastActivityAt: Date

        public init(
            id: SessionID, title: String?, kind: SessionKind, state: SessionState,
            workspaceName: String, itemCount: Int, lastActivityAt: Date
        ) {
            self.id = id
            self.title = title
            self.kind = kind
            self.state = state
            self.workspaceName = workspaceName
            self.itemCount = itemCount
            self.lastActivityAt = lastActivityAt
        }
    }

    public var version: Int
    public var generatedAt: Date
    /// The workspace to feature in the large widget: the most recently opened.
    public var featuredWorkspace: WorkspaceSummary?
    public var workspaces: [WorkspaceSummary]
    /// Newest activity first; active sessions before others.
    public var sessions: [SessionSummary]

    public init(
        generatedAt: Date,
        featuredWorkspace: WorkspaceSummary? = nil,
        workspaces: [WorkspaceSummary] = [],
        sessions: [SessionSummary] = []
    ) {
        self.version = Self.currentVersion
        self.generatedAt = generatedAt
        self.featuredWorkspace = featuredWorkspace
        self.workspaces = workspaces
        self.sessions = sessions
    }

    public static let empty = WidgetSnapshot(generatedAt: Date(timeIntervalSinceReferenceDate: 0))

    public var isEmpty: Bool { workspaces.isEmpty && sessions.isEmpty }

    /// Builds the snapshot from the store.
    public static func make(
        workspaces workspaceService: WorkspaceService,
        sessions sessionService: SessionService,
        capture: CaptureService,
        now: Date
    ) async throws -> WidgetSnapshot {
        let workspaces = try await workspaceService.list()
        let names = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.name) })
        var sessions: [Session] = []
        for workspace in workspaces {
            sessions += try await sessionService.sessions(in: workspace.id).filter { !$0.isArchived }
        }
        let recent = sessions.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
            return lhs.id.description < rhs.id.description
        }.prefix(maximumSessions)

        var summaries: [SessionSummary] = []
        for session in recent {
            summaries.append(SessionSummary(
                id: session.id,
                title: session.title,
                kind: session.kind,
                state: session.state,
                workspaceName: names[session.workspaceID] ?? "",
                itemCount: try await capture.items(in: session.id).count,
                lastActivityAt: session.lastActivityAt
            ))
        }

        let activeCounts = Dictionary(grouping: sessions.filter(\.isActive), by: \.workspaceID).mapValues(\.count)
        let ordered = workspaces.sorted { lhs, rhs in
            let left = lhs.lastOpenedAt ?? lhs.createdAt, right = rhs.lastOpenedAt ?? rhs.createdAt
            if left != right { return left > right }
            return lhs.id.description < rhs.id.description
        }
        let workspaceSummaries = ordered.prefix(maximumWorkspaces).map { workspace in
            WorkspaceSummary(
                id: workspace.id, name: workspace.name, kind: workspace.kind,
                symbolName: workspace.symbolName, color: workspace.color,
                activeSessionCount: activeCounts[workspace.id] ?? 0
            )
        }
        return WidgetSnapshot(
            generatedAt: now,
            featuredWorkspace: workspaceSummaries.first,
            workspaces: Array(workspaceSummaries),
            sessions: summaries
        )
    }
}

/// Reads and writes the snapshot file. Writing is atomic so a widget never
/// reads half a file; an unreadable file reads as empty.
public struct WidgetSnapshotStore: Sendable {
    public static let fileName = "widget-snapshot.json"
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
    }

    /// The App Group container shared by the app and its widgets, if this build has one.
    public static func shared(appGroupIdentifier: String?) -> WidgetSnapshotStore? {
        guard let appGroupIdentifier, !appGroupIdentifier.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        else { return nil }
        return WidgetSnapshotStore(directory: container.appendingPathComponent("Widgets", isDirectory: true))
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
    }

    public func read() -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version <= WidgetSnapshot.currentVersion
        else { return .empty }
        return snapshot
    }
}
