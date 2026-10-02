import Foundation

/// What a piece of content is, as a whole. Drives the suggested actions.
public enum ContentCategory: String, Codable, Sendable, CaseIterable {
    case plainText
    case url
    case phone
    case email
    case currency
    case number
    case date
    case address
    case json
    case code
    case image
    case pdf
    case document
    case unknown
}

/// The Context Engine's view of one piece of content.
public struct ContextAnalysis: Sendable, Equatable {
    public var category: ContentCategory
    public var entities: [DetectedEntity]
    public var actions: [Action]

    public init(category: ContentCategory, entities: [DetectedEntity], actions: [Action]) {
        self.category = category
        self.entities = entities
        self.actions = actions
    }

    /// The entity that made the whole content its category, if any.
    public var primaryEntity: DetectedEntity? {
        entities.first { $0.metadata[ContextAnalysis.primaryKey]?.boolValue == true }
    }

    /// Metadata flag on the entity that covers the whole content.
    public static let primaryKey = "primary"
}
