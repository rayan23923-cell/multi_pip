import Foundation
import TLDomain
import TLFoundation

/// What the Action Engine knows about the situation, besides the content.
public struct ActionContext: Sendable {
    /// Where the content came from. Changes what is useful: content from the
    /// clipboard does not need "Copy" first.
    public var source: ContextSource?
    /// The user's language ("en", "ar"), for deciding when Translate matters.
    public var preferredLanguage: String
    /// What the user chose before. Not collected yet: `NoActionHistory` until
    /// a later phase records choices, on device.
    public var history: any ActionHistoryProviding

    public init(
        source: ContextSource? = nil,
        preferredLanguage: String = ActionContext.deviceLanguage,
        history: any ActionHistoryProviding = NoActionHistory()
    ) {
        self.source = source
        self.preferredLanguage = preferredLanguage
        self.history = history
    }

    public static var deviceLanguage: String {
        Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
    }
}

/// Past choices, as a preference in `0...1` for an action on a kind of content.
public protocol ActionHistoryProviding: Sendable {
    func preference(for type: ActionType, category: ContentCategory) -> Double
}

/// No history: every action keeps its rule score.
public struct NoActionHistory: ActionHistoryProviding {
    public init() {}
    public func preference(for type: ActionType, category: ContentCategory) -> Double { 0 }
}

/// An action the generator proposes, before ranking.
public struct ActionCandidate: Sendable, Equatable {
    public var type: ActionType
    /// How useful this action is for this kind of content, from the rule table (`0...1`).
    public var relevance: Double
    /// The entity the action works on. Its confidence scales the score of
    /// actions specific to that entity type (Call for a phone number).
    public var entity: DetectedEntity?
    public var isSpecific: Bool
    public var isPlaceholder: Bool
    public var requiresConfirmation: Bool
    public var parameters: [String: JSONValue]
    /// Position in the rule table; breaks ties so ranking never depends on chance.
    public var order: Int

    public init(
        type: ActionType, relevance: Double, entity: DetectedEntity?, isSpecific: Bool, isPlaceholder: Bool,
        requiresConfirmation: Bool, parameters: [String: JSONValue], order: Int
    ) {
        self.type = type
        self.relevance = relevance
        self.entity = entity
        self.isSpecific = isSpecific
        self.isPlaceholder = isPlaceholder
        self.requiresConfirmation = requiresConfirmation
        self.parameters = parameters
        self.order = order
    }
}

/// An action with its score and the reasons behind it.
public struct RankedAction: Sendable, Equatable {
    public var action: Action
    public var score: Double
    public var reasons: [String]
}

/// Rule-based Action Engine: Context → Action Generator → Action Ranking.
///
/// No AI and no network. Actions that need a later phase (exchange rates,
/// reminders, summaries, AI) are generated as placeholders so the UI can show
/// them honestly as "coming later" instead of pretending to do them.
public struct ActionEngine: ActionSuggesting {
    public var context: ActionContext

    public init(context: ActionContext = ActionContext()) {
        self.context = context
    }

    public func suggestActions(for item: ContextItem) async -> [Action] {
        var context = context
        context.source = item.source
        return Self.analyze(item.content, itemID: item.id, context: context).actions
    }

    /// The whole pipeline for one piece of content.
    public static func analyze(
        _ content: ContextContent,
        itemID: ContextItemID? = nil,
        context: ActionContext = ActionContext()
    ) -> ContextAnalysis {
        let input = Normalizer.normalize(content, source: context.source)
        let (category, entities) = ContextEngine.analyze(input)
        let candidates = generate(category: category, entities: entities, input: input)
        let ranked = rank(candidates, category: category, input: input, context: context)
        let actions = ranked.map { ranked in
            var action = ranked.action
            action.targetItemID = itemID
            return action
        }
        return ContextAnalysis(category: category, entities: entities, actions: actions)
    }

    // MARK: Action Generator

    private enum Kind { case specific, generic }

    private struct Rule {
        var type: ActionType
        var relevance: Double
        var kind: Kind = .generic
        var placeholder = false
        var confirm = false

        init(_ type: ActionType, _ relevance: Double, _ kind: Kind = .generic, placeholder: Bool = false, confirm: Bool = false) {
            self.type = type
            self.relevance = relevance
            self.kind = kind
            self.placeholder = placeholder
            self.confirm = confirm
        }
    }

    /// The rule table: what is useful for each kind of content, and how much.
    private static let rules: [ContentCategory: [Rule]] = [
        .phone: [Rule(.call, 0.95, .specific, confirm: true), Rule(.sendMessage, 0.85, .specific), Rule(.saveToSession, 0.7),
                 Rule(.copy, 0.5), Rule(.createNote, 0.3), Rule(.share, 0.3)],
        .url: [Rule(.openURL, 0.95, .specific), Rule(.saveToSession, 0.8), Rule(.search, 0.75), Rule(.share, 0.7), Rule(.copy, 0.5),
               Rule(.createNote, 0.25)],
        .email: [Rule(.sendEmail, 0.95, .specific), Rule(.saveToSession, 0.7), Rule(.copy, 0.6), Rule(.share, 0.3)],
        .currency: [Rule(.convertCurrency, 0.97, .specific, placeholder: true), Rule(.calculate, 0.9, .specific),
                    Rule(.saveToSession, 0.7), Rule(.copy, 0.5), Rule(.share, 0.4)],
        .number: [Rule(.calculate, 0.95, .specific), Rule(.saveToSession, 0.7), Rule(.copy, 0.6), Rule(.share, 0.3)],
        .date: [Rule(.addToCalendar, 0.9, .specific), Rule(.createReminder, 0.88, .specific, placeholder: true),
                Rule(.saveToSession, 0.7), Rule(.copy, 0.5), Rule(.createNote, 0.3), Rule(.share, 0.3)],
        .address: [Rule(.openInMaps, 0.95, .specific), Rule(.saveToSession, 0.7), Rule(.copy, 0.6), Rule(.share, 0.4)],
        .json: [Rule(.copy, 0.9, .specific), Rule(.saveToSession, 0.75), Rule(.share, 0.6), Rule(.createNote, 0.3)],
        .code: [Rule(.copy, 0.9, .specific), Rule(.saveToSession, 0.75), Rule(.share, 0.6), Rule(.createNote, 0.4),
                Rule(.askAI, 0.2, placeholder: true)],
        .plainText: [Rule(.saveToSession, 0.8), Rule(.copy, 0.75), Rule(.translate, 0.7), Rule(.createNote, 0.65),
                     Rule(.search, 0.55), Rule(.share, 0.5), Rule(.summarize, 0.45, placeholder: true),
                     Rule(.askAI, 0.2, placeholder: true)],
        .image: [Rule(.saveToSession, 0.9), Rule(.extractText, 0.7, placeholder: true), Rule(.share, 0.5)],
        .pdf: [Rule(.saveToSession, 0.9), Rule(.extractText, 0.7, placeholder: true), Rule(.share, 0.5),
               Rule(.summarize, 0.3, placeholder: true)],
        .document: [Rule(.saveToSession, 0.9), Rule(.share, 0.5)],
        .unknown: [Rule(.saveToSession, 0.8), Rule(.copy, 0.6)],
    ]

    /// The action for an entity found inside a longer text (a phone number in a message).
    private static let entityRules: [EntityType: Rule] = [
        .phoneNumber: Rule(.call, 0.95, .specific, confirm: true),
        .url: Rule(.openURL, 0.95, .specific),
        .email: Rule(.sendEmail, 0.95, .specific),
        .date: Rule(.addToCalendar, 0.9, .specific),
        .address: Rule(.openInMaps, 0.95, .specific),
        .currencyAmount: Rule(.calculate, 0.9, .specific),
    ]

    /// Entity actions inside text are worth less than the same action on content
    /// that *is* the entity: the user may not mean that part.
    static let embeddedWeight = 0.6
    /// Relevance of "Extract" when a text holds several useful entities.
    static let extractRelevance = 0.6

    /// Candidates for the content's category, then for entities found inside it.
    public static func generate(category: ContentCategory, entities: [DetectedEntity], input: NormalizedInput) -> [ActionCandidate] {
        let primary = entities.first { $0.isPrimary && ContextEngine.categories[$0.type] == category }
        var candidates: [ActionCandidate] = []

        for rule in rules[category] ?? [] {
            let entity = rule.kind == .specific ? primary : nil
            candidates.append(candidate(rule, entity: entity, input: input, order: candidates.count))
        }

        // Useful entities inside a longer text: one action per kind, from the strongest match.
        let embedded = entities.filter { !$0.isPrimary && $0.confidence >= .medium }
        for entity in embedded.sorted(by: ContextEngine.isStronger) {
            guard var rule = entityRules[entity.type], !candidates.contains(where: { $0.type == rule.type }) else { continue }
            rule.relevance *= embeddedWeight
            candidates.append(candidate(rule, entity: entity, input: input, order: candidates.count))
        }

        if embedded.count >= 2, [.plainText, .code].contains(category) {
            var extract = ActionCandidate(
                type: .extractText, relevance: extractRelevance, entity: nil, isSpecific: false, isPlaceholder: false,
                requiresConfirmation: false, parameters: [:], order: candidates.count
            )
            extract.parameters[Action.ParameterKey.values] = .array(embedded.compactMap(\.normalizedText).map(JSONValue.string))
            candidates.removeAll { $0.type == .extractText }
            candidates.append(extract)
        }
        return candidates
    }

    private static func candidate(_ rule: Rule, entity: DetectedEntity?, input: NormalizedInput, order: Int) -> ActionCandidate {
        var parameters: [String: JSONValue] = [:]
        // Entity actions work on the entity's canonical value; the rest on the content.
        let value = entity?.normalizedText ?? (input.text.isEmpty ? nil : input.text)
        if let value { parameters[Action.ParameterKey.value] = .string(value) }
        if rule.placeholder { parameters[Action.ParameterKey.placeholder] = .bool(true) }
        if let entity {
            switch entity.value {
            case .currency(_, let code?):
                parameters[Action.ParameterKey.currencyCode] = .string(code)
            case .date:
                parameters[Action.ParameterKey.includesTime] = entity.metadata[DetectionKey.includesTime] ?? .bool(false)
                if let title = eventTitle(around: entity, in: input.text) {
                    parameters[Action.ParameterKey.title] = .string(title)
                }
            default:
                break
            }
        }
        return ActionCandidate(
            type: rule.type, relevance: rule.relevance, entity: entity, isSpecific: rule.kind == .specific,
            isPlaceholder: rule.placeholder, requiresConfirmation: rule.confirm, parameters: parameters, order: order
        )
    }

    /// "Dinner with Sara tomorrow at 8" → "Dinner with Sara": the text around a
    /// date, as the title of an event. Nil when the date is the whole text.
    static func eventTitle(around entity: DetectedEntity, in text: String) -> String? {
        guard let range = entity.range, !entity.isPrimary else { return nil }
        let rest = (text as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: " ")
        let firstLine = rest.split(separator: "\n").first.map(String.init) ?? rest
        let title = firstLine.split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return title.isEmpty ? nil : String(title.prefix(80))
    }

    // MARK: Action Ranking

    /// Actions that need the full app: from the share sheet they only point to it.
    public static let needsApp: Set<ActionType> = [
        .call, .sendMessage, .sendEmail, .openURL, .openInMaps, .calculate, .search, .createNote, .addToCalendar,
    ]

    /// Score adjustments by source. Deterministic, documented, and tested.
    static func sourceAdjustment(_ type: ActionType, source: ContextSource?) -> Double {
        switch source {
        case .clipboard?:
            return type == .copy ? -0.3 : 0  // already on the clipboard
        case .shareExtension?:
            if type == .share { return -0.4 }  // just shared
            if type == .saveToSession { return 0.1 }
            return needsApp.contains(type) ? -0.25 : 0
        case .calculator?:
            return type == .calculate ? -0.4 : 0
        case .notes?:
            return type == .createNote ? -0.4 : 0
        case .browser?:
            return type == .openURL ? -0.2 : 0  // already open
        default:
            return 0
        }
    }

    static let placeholderPenalty = 0.05
    static let historyWeight = 0.2
    static let languageAdjustment = 0.15
    static let longTextLength = 280

    /// Orders candidates by score:
    ///
    ///     relevance × (0.5 + 0.5 × confidence, for entity-specific actions)
    ///     + source adjustment + context adjustment + 0.2 × history
    ///     − 0.05 for placeholders
    ///
    /// Ties keep rule-table order. The same input always gives the same order.
    public static func rank(_ candidates: [ActionCandidate], category: ContentCategory, input: NormalizedInput,
                            context: ActionContext) -> [RankedAction] {
        let script = TextScript.dominant(in: input.text)
        let isLong = input.text.count > longTextLength

        let scored = candidates.map { candidate -> (ActionCandidate, Double, [String]) in
            var score = candidate.relevance
            var reasons = ["rule \(candidate.relevance)"]
            if candidate.isSpecific, let entity = candidate.entity {
                score *= 0.5 + 0.5 * entity.confidence.value
                reasons.append("confidence \(entity.confidence.value)")
            }
            let source = sourceAdjustment(candidate.type, source: context.source)
            if source != 0 {
                score += source
                reasons.append("source \(context.source?.rawValue ?? "") \(source)")
            }
            if candidate.type == .translate, let script {
                let same = script.matches(language: context.preferredLanguage)
                score += same ? -languageAdjustment : languageAdjustment
                reasons.append(same ? "same language" : "other language")
            }
            if isLong, [.summarize, .createNote].contains(candidate.type) {
                score += 0.15
                reasons.append("long text")
            }
            let preference = min(max(context.history.preference(for: candidate.type, category: category), 0), 1)
            if preference > 0 {
                score += historyWeight * preference
                reasons.append("history \(preference)")
            }
            if candidate.isPlaceholder {
                score -= placeholderPenalty
                reasons.append("placeholder")
            }
            // Three decimals, so floating-point noise never reorders equal scores.
            return (candidate, (min(max(score, 0), 1) * 1000).rounded() / 1000, reasons)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.order < rhs.0.order
            }
            .map { candidate, score, reasons in
                RankedAction(
                    action: Action(
                        type: candidate.type,
                        priority: ActionPriority(Int((score * 1000).rounded())),
                        parameters: candidate.parameters,
                        targetEntityID: candidate.entity?.id,
                        requiresConfirmation: candidate.requiresConfirmation
                    ),
                    score: score,
                    reasons: reasons
                )
            }
    }
}

/// The writing system most of a text's letters use. Decides whether
/// Translate is likely useful, without guessing the language itself.
enum TextScript: Equatable {
    case arabic
    case latin

    static func dominant(in text: String) -> TextScript? {
        var arabic = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: arabic += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
            default: break
            }
        }
        let total = arabic + latin
        guard total >= 3 else { return nil }
        if Double(arabic) >= Double(total) * 0.7 { return .arabic }
        if Double(latin) >= Double(total) * 0.7 { return .latin }
        return nil
    }

    /// True when the user's language is written in this script.
    func matches(language: String) -> Bool {
        let arabicScript: Set<String> = ["ar", "fa", "ur", "ps", "ckb", "ku"]
        return (self == .arabic) == arabicScript.contains(language)
    }
}
