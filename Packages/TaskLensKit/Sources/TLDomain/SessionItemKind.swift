import Foundation

/// What an item is, from the point of view of a session.
public enum SessionItemKind: String, Codable, Sendable, CaseIterable {
    case note
    case link
    case document
    case image
    case calculation
    case code
    case question
    case clipboard
    case text
}

/// How the items of a session are ordered.
public enum SessionSort: String, Codable, Sendable, CaseIterable {
    /// Newest first.
    case recent
    /// Grouped by kind; the kinds this session is about come first.
    case type
    /// Marked items first, then what matters most for this kind of session.
    case importance
}
