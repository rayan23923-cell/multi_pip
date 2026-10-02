import Foundation
import TLFoundation

public typealias WorkspaceID = Identifier<Workspace>

/// A long-lived container that groups sessions, notes and documents
/// around one area of the user's work (a project, a trip, a course).
public struct Workspace: Entity {
    public static let entityName = "workspace"
    public static let maximumNameLength = 80

    public let id: WorkspaceID
    public var name: String
    public var symbolName: String?
    public var color: WorkspaceColor
    public var isArchived: Bool
    public var sortOrder: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var metadata: Metadata

    public init(
        id: WorkspaceID = WorkspaceID(),
        name: String,
        symbolName: String? = nil,
        color: WorkspaceColor = .blue,
        isArchived: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date,
        updatedAt: Date? = nil,
        metadata: Metadata = [:]
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.color = color
        self.isArchived = isArchived
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.metadata = metadata
    }
}

/// Semantic color tag. The design system decides the actual color.
public struct WorkspaceColor: ExtensibleKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let blue: WorkspaceColor = "blue"
    public static let green: WorkspaceColor = "green"
    public static let orange: WorkspaceColor = "orange"
    public static let purple: WorkspaceColor = "purple"
    public static let pink: WorkspaceColor = "pink"
    public static let gray: WorkspaceColor = "gray"

    public static let allKnown: [WorkspaceColor] = [.blue, .green, .orange, .purple, .pink, .gray]
}
