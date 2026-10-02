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
    /// Every suggested action, best first.
    public var actions: [Action]
    /// The same actions grouped for display.
    public var suggestions: ActionSuggestions

    public init(category: ContentCategory, entities: [DetectedEntity], actions: [Action]) {
        self.category = category
        self.entities = entities
        self.actions = actions
        self.suggestions = ActionSuggestions(ranked: actions)
    }

    /// The entity that made the whole content its category, if any.
    public var primaryEntity: DetectedEntity? {
        entities.first { $0.metadata[ContextAnalysis.primaryKey]?.boolValue == true }
    }

    /// Metadata flag on the entity that covers the whole content.
    public static let primaryKey = "primary"
}

/// Ranked actions split into what the UI shows: a few recommended buttons,
/// a short list of secondary actions, and the rest behind "More".
public struct ActionSuggestions: Sendable, Equatable {
    public var primary: [Action]
    public var secondary: [Action]
    public var more: [Action]

    public static let primaryLimit = 3
    public static let secondaryLimit = 3
    /// Minimum score (`priority`) to be recommended, unless nothing reaches it.
    public static let primaryMinimum = ActionPriority(500)
    /// Minimum score to be listed without opening "More".
    public static let secondaryMinimum = ActionPriority(550)

    public init(primary: [Action], secondary: [Action], more: [Action]) {
        self.primary = primary
        self.secondary = secondary
        self.more = more
    }

    /// Splits actions that are already ranked, best first.
    public init(ranked actions: [Action]) {
        var remaining = actions[...]
        var primary: [Action] = []
        while primary.count < Self.primaryLimit, let next = remaining.first,
              next.priority >= Self.primaryMinimum || primary.isEmpty {
            primary.append(next)
            remaining = remaining.dropFirst()
        }
        var secondary: [Action] = []
        while secondary.count < Self.secondaryLimit, let next = remaining.first, next.priority >= Self.secondaryMinimum {
            secondary.append(next)
            remaining = remaining.dropFirst()
        }
        self.init(primary: primary, secondary: secondary, more: Array(remaining))
    }

    public var all: [Action] { primary + secondary + more }
    public var isEmpty: Bool { primary.isEmpty }
}
