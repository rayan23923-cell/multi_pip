import Foundation
import TLDomain
import TLFoundation

/// The first Action Engine: fixed rules from content category to actions.
///
/// No AI and no network. Actions that need a later phase (summaries, calendar,
/// reminders, exchange rates) are returned as placeholders so the UI can show
/// them honestly as "coming later" instead of pretending to do them.
public struct RuleActionEngine: ActionSuggesting {
    public init() {}

    public func suggestActions(for item: ContextItem) async -> [Action] {
        Self.analyze(item.content, itemID: item.id).actions
    }

    /// Category, entities and actions for content, in one call.
    public static func analyze(_ content: ContextContent, itemID: ContextItemID? = nil) -> ContextAnalysis {
        let (category, entities) = ContextEngine.analyze(content)
        return ContextAnalysis(
            category: category,
            entities: entities,
            actions: actions(for: category, content: content, entities: entities, itemID: itemID)
        )
    }

    public static func actions(
        for category: ContentCategory,
        content: ContextContent,
        entities: [DetectedEntity],
        itemID: ContextItemID? = nil
    ) -> [Action] {
        let primary = entities.first { $0.metadata[ContextAnalysis.primaryKey]?.boolValue == true }
        let value = primary.flatMap(valueText) ?? plainText(of: content)

        func make(_ type: ActionType, _ priority: ActionPriority, placeholder: Bool = false,
                  confirm: Bool = false, extra: [String: JSONValue] = [:]) -> Action {
            var parameters = extra
            if let value { parameters[Action.ParameterKey.value] = .string(value) }
            if placeholder { parameters[Action.ParameterKey.placeholder] = .bool(true) }
            return Action(type: type, priority: priority, parameters: parameters, targetItemID: itemID,
                          targetEntityID: primary?.id, requiresConfirmation: confirm)
        }

        var actions: [Action]
        switch category {
        case .phone:
            actions = [make(.call, .primary, confirm: true), make(.sendMessage, .high), make(.saveToSession, .normal),
                       make(.copy, .low)]
        case .url:
            actions = [make(.openURL, .primary), make(.saveToSession, .high), make(.share, .normal), make(.copy, .low)]
        case .email:
            actions = [make(.sendEmail, .primary), make(.saveToSession, .high), make(.copy, .normal)]
        case .currency:
            var extra: [String: JSONValue] = [:]
            if case .currency(_, let code)? = primary?.value, let code {
                extra[Action.ParameterKey.currencyCode] = .string(code)
            }
            actions = [make(.convertCurrency, .primary, placeholder: true, extra: extra), make(.calculate, .high),
                       make(.saveToSession, .normal), make(.copy, .low)]
        case .number:
            actions = [make(.calculate, .primary), make(.saveToSession, .high), make(.copy, .normal)]
        case .date:
            actions = [make(.createReminder, .primary, placeholder: true), make(.addToCalendar, .high, placeholder: true),
                       make(.saveToSession, .normal), make(.copy, .low)]
        case .address:
            actions = [make(.openInMaps, .primary), make(.saveToSession, .high), make(.copy, .normal)]
        case .json, .code:
            actions = [make(.copy, .primary), make(.share, .high), make(.saveToSession, .normal)]
        case .plainText:
            actions = [make(.saveToSession, .primary), make(.copy, .high), make(.translate, .normal),
                       make(.summarize, .low, placeholder: true), make(.share, .low)]
        case .image, .pdf, .document:
            actions = [make(.saveToSession, .primary), make(.share, .normal)]
        case .unknown:
            actions = [make(.saveToSession, .primary)]
        }
        return Action.ranked(actions)
    }

    private static func valueText(_ entity: DetectedEntity) -> String? {
        switch entity.value {
        case .text(let text): text
        case .url(let url): url.absoluteString
        case .phoneNumber(let phone): phone
        case .email(let email): email
        case .date(let date): ISO8601DateFormatter().string(from: date)
        case .currency(let amount, _), .number(let amount): NSDecimalNumber(decimal: amount).description(withLocale: Locale(identifier: "en_US_POSIX"))
        case .address: entity.matchedText
        }
    }

    private static func plainText(of content: ContextContent) -> String? {
        switch content {
        case .text(let text): text
        case .url(let url): url.absoluteString
        case .file: nil
        }
    }
}
