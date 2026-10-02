import Foundation
import TLFoundation

public typealias ContextItemID = Identifier<ContextItem>

/// One thing the user explicitly gave TaskLens: shared, pasted, typed, captured or imported.
public struct ContextItem: Entity {
    public static let entityName = "contextItem"
    /// Upper bound for inline text content. Larger text should be stored as a file.
    public static let maximumTextLength = 200_000

    public let id: ContextItemID
    public var sessionID: SessionID?
    public var workspaceID: WorkspaceID?
    public let source: ContextSource
    public var content: ContextContent
    public var entities: [DetectedEntity]
    public var metadata: Metadata
    public let createdAt: Date

    public init(
        id: ContextItemID = ContextItemID(),
        sessionID: SessionID? = nil,
        workspaceID: WorkspaceID? = nil,
        source: ContextSource,
        content: ContextContent,
        entities: [DetectedEntity] = [],
        metadata: Metadata = [:],
        createdAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.source = source
        self.content = content
        self.entities = entities
        self.metadata = metadata
        self.createdAt = createdAt
    }

    /// Derived from `content` so the two can never disagree.
    public var type: ContextItemType { content.itemType }

    /// Entities ordered by confidence, highest first.
    public var rankedEntities: [DetectedEntity] {
        entities.sorted { $0.confidence > $1.confidence }
    }
}

public enum ContextItemType: String, Codable, Sendable, CaseIterable {
    case text
    case url
    case image
    case pdf
    case document
}

/// Where a context item came from. Every source is user-initiated.
public struct ContextSource: ExtensibleKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let manualEntry: ContextSource = "manualEntry"
    public static let clipboard: ContextSource = "clipboard"
    public static let shareExtension: ContextSource = "shareExtension"
    public static let fileImport: ContextSource = "fileImport"
    public static let photoLibrary: ContextSource = "photoLibrary"
    public static let camera: ContextSource = "camera"
    public static let browser: ContextSource = "browser"
    public static let appIntent: ContextSource = "appIntent"
    public static let notes: ContextSource = "notes"
    public static let calculator: ContextSource = "calculator"
    public static let documentViewer: ContextSource = "documentViewer"
    public static let imageViewer: ContextSource = "imageViewer"
    public static let textViewer: ContextSource = "textViewer"
}
