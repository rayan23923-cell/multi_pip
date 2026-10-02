import Foundation
import TLDomain

/// Rule-based action suggestions: the first, offline Action Engine.
///
/// It looks only at the content type and simple patterns. It uses no AI and
/// no network. Richer suggestions plug in later through `ActionSuggesting`.
public struct BasicActionSuggester: ActionSuggesting {
    public init() {}

    public func suggestActions(for item: ContextItem) async -> [Action] {
        Self.actions(for: item.content, itemID: item.id)
    }

    public static func actions(for content: ContextContent, itemID: ContextItemID? = nil) -> [Action] {
        var actions = [
            Action(type: .copy, priority: .normal, targetItemID: itemID),
            Action(type: .share, priority: .normal, targetItemID: itemID),
            Action(type: .saveToSession, priority: .high, targetItemID: itemID),
        ]
        switch content {
        case .url:
            actions.append(Action(type: .openURL, priority: .primary, targetItemID: itemID))
        case .text(let text):
            actions.append(Action(type: .createNote, priority: .normal, targetItemID: itemID))
            if isNumber(text) {
                actions.append(Action(type: .calculate, priority: .high, targetItemID: itemID))
            }
        case .file:
            break
        }
        return Action.ranked(actions)
    }

    /// True for plain numbers such as "42", "-3.5" or "1,250.75".
    static func isNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return false }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) != nil
            && trimmed.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
    }
}
