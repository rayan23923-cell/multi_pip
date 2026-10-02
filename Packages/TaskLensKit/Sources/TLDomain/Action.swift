import Foundation
import TLFoundation

public typealias ActionID = Identifier<Action>

/// A suggested operation on a context item or one of its entities.
///
/// Actions are values: they describe *what* to do. Executing them is the job of
/// an `ActionPerforming` implementation in a later phase.
public struct Action: Codable, Sendable, Hashable, Identifiable {
    public let id: ActionID
    public var type: ActionType
    /// Localization key for the title. The domain never holds user-facing text.
    public var titleKey: String
    public var priority: ActionPriority
    public var parameters: [String: JSONValue]
    public var targetItemID: ContextItemID?
    public var targetEntityID: DetectedEntityID?
    /// True for actions that leave the app or change data (call, delete...).
    public var requiresConfirmation: Bool

    public init(
        id: ActionID = ActionID(),
        type: ActionType,
        titleKey: String? = nil,
        priority: ActionPriority = .normal,
        parameters: [String: JSONValue] = [:],
        targetItemID: ContextItemID? = nil,
        targetEntityID: DetectedEntityID? = nil,
        requiresConfirmation: Bool = false
    ) {
        self.id = id
        self.type = type
        self.titleKey = titleKey ?? type.defaultTitleKey
        self.priority = priority
        self.parameters = parameters
        self.targetItemID = targetItemID
        self.targetEntityID = targetEntityID
        self.requiresConfirmation = requiresConfirmation
    }
}

extension Action {
    /// Parameter keys shared by the Action Engine and the code that performs actions.
    public enum ParameterKey {
        /// The value the action works on (phone number, URL, amount...).
        public static let value = "value"
        public static let currencyCode = "currencyCode"
        /// Event or note title suggested from the content.
        public static let title = "title"
        /// True when a date value carries a time of day.
        public static let includesTime = "includesTime"
        /// Several values at once (Extract).
        public static let values = "values"
        /// True when the action is shown but not implemented yet.
        public static let placeholder = "placeholder"
    }

    /// Shown so the user knows it is coming, but not performed yet.
    public var isPlaceholder: Bool {
        parameters[ParameterKey.placeholder]?.boolValue ?? false
    }

    /// The `value` parameter as text.
    public var valueText: String? {
        parameters[ParameterKey.value]?.stringValue
    }

    /// Highest priority first; ties broken by type name so ordering is stable.
    public static func ranked(_ actions: [Action]) -> [Action] {
        actions.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.type.rawValue < rhs.type.rawValue
        }
    }
}

public struct ActionType: ExtensibleKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public var defaultTitleKey: String { "action.\(rawValue)" }

    public static let copy: ActionType = "copy"
    public static let share: ActionType = "share"
    public static let saveToSession: ActionType = "saveToSession"
    public static let createNote: ActionType = "createNote"
    public static let openURL: ActionType = "openURL"
    public static let call: ActionType = "call"
    public static let sendMessage: ActionType = "sendMessage"
    public static let sendEmail: ActionType = "sendEmail"
    public static let addContact: ActionType = "addContact"
    public static let addToCalendar: ActionType = "addToCalendar"
    public static let openInMaps: ActionType = "openInMaps"
    public static let calculate: ActionType = "calculate"
    public static let convertCurrency: ActionType = "convertCurrency"
    public static let extractText: ActionType = "extractText"
    public static let translate: ActionType = "translate"
    public static let summarize: ActionType = "summarize"
    public static let createReminder: ActionType = "createReminder"
    /// Searches what the user saved in TaskLens.
    public static let search: ActionType = "search"
    /// Reserved for an optional, clearly separated AI feature. Always a placeholder.
    public static let askAI: ActionType = "askAI"

    public static let allKnown: [ActionType] = [
        .copy, .share, .saveToSession, .createNote, .openURL, .call, .sendMessage, .sendEmail, .addContact,
        .addToCalendar, .openInMaps, .calculate, .convertCurrency, .extractText, .translate, .summarize, .createReminder,
        .search, .askAI,
    ]
}

/// Ordering weight for actions. Higher is shown first.
public struct ActionPriority: Codable, Sendable, Hashable, Comparable {
    public let rawValue: Int

    public init(_ rawValue: Int) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: ActionPriority, rhs: ActionPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    public static let low = ActionPriority(250)
    public static let normal = ActionPriority(500)
    public static let high = ActionPriority(750)
    public static let primary = ActionPriority(1000)
}
