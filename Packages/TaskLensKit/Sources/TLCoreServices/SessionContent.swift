import Foundation
import TLDomain
import TLFoundation

/// Pure rules for a session's content: kinds, importance, sorting and search.
/// Deterministic: the same items always come back in the same order.
public enum SessionContent {
    /// `ContextItem.metadata` flag set when the user marks an item as important.
    public static let importantKey = "important"

    // MARK: Kind

    public static func kind(of item: ContextItem) -> SessionItemKind {
        switch item.source {
        case .notes: return .note
        case .calculator: return .calculation
        case .clipboard: return .clipboard
        default: break
        }
        switch item.content {
        case .url:
            return .link
        case .file(let reference):
            return reference.kind == .image ? .image : .document
        case .text(let text):
            if item.entities.contains(where: { [.code, .json].contains($0.type) }) { return .code }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("?") || trimmed.hasSuffix("؟") { return .question }
            if ContentClassifier.classify(trimmed).itemType == .url { return .link }
            return .text
        }
    }

    // MARK: Session kinds

    /// What each kind of session is mostly made of.
    /// Research: links, PDFs, notes. Shopping: products (links), prices,
    /// calculations. Study: PDFs, notes, questions. Developer: links, code,
    /// clipboard.
    public static func focus(of kind: SessionKind) -> [SessionItemKind] {
        switch kind {
        case .research: [.link, .document, .note]
        case .shopping: [.link, .calculation]
        case .study: [.document, .note, .question]
        case .developer: [.link, .code, .clipboard]
        default: []
        }
    }

    /// Entities that matter more in a kind of session (prices when shopping).
    static func focusEntities(of kind: SessionKind) -> Set<EntityType> {
        switch kind {
        case .shopping: [.currencyAmount]
        case .research: [.url, .date]
        case .study: [.date]
        case .developer: [.url, .code, .json]
        default: []
        }
    }

    // MARK: Importance

    static let baseWeight: [SessionItemKind: Int] = [
        .document: 3, .note: 3, .link: 2, .calculation: 2, .code: 2, .question: 2, .image: 2, .clipboard: 1, .text: 1,
    ]
    static let markedWeight = 100
    static let focusWeight = 3
    static let focusEntityWeight = 2
    static let actionableEntities: Set<EntityType> = [.phoneNumber, .url, .email, .date, .address, .currencyAmount]

    public static func isImportant(_ item: ContextItem) -> Bool {
        item.metadata[importantKey]?.boolValue == true
    }

    /// Marked by the user: 100. Kind: 1–3, +3 when it is what this session is
    /// about. Up to 3 for things to act on (phones, links, dates, prices), +2
    /// each for entities this kind of session cares about.
    public static func importance(of item: ContextItem, in sessionKind: SessionKind) -> Int {
        let kind = kind(of: item)
        var score = baseWeight[kind] ?? 1
        if isImportant(item) { score += markedWeight }
        if focus(of: sessionKind).contains(kind) { score += focusWeight }
        let types = item.entities.filter { $0.confidence >= .medium }.map(\.type)
        score += min(types.filter(actionableEntities.contains).count, 3)
        score += types.filter(focusEntities(of: sessionKind).contains).count * focusEntityWeight
        return score
    }

    // MARK: Sorting

    public static func sorted(_ items: [ContextItem], by sort: SessionSort, sessionKind: SessionKind = .general) -> [ContextItem] {
        switch sort {
        case .recent:
            return items.sorted(by: newestFirst)
        case .type:
            let order = typeOrder(for: sessionKind)
            return items.sorted { lhs, rhs in
                let left = order[kind(of: lhs)] ?? .max, right = order[kind(of: rhs)] ?? .max
                if left != right { return left < right }
                return newestFirst(lhs, rhs)
            }
        case .importance:
            return items
                .map { ($0, importance(of: $0, in: sessionKind)) }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return newestFirst(lhs.0, rhs.0)
                }
                .map(\.0)
        }
    }

    /// Kinds in display order: this session's focus first, then the rest.
    public static func typeOrder(for sessionKind: SessionKind) -> [SessionItemKind: Int] {
        let focus = focus(of: sessionKind)
        let ordered = focus + SessionItemKind.allCases.filter { !focus.contains($0) }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
    }

    static func newestFirst(_ lhs: ContextItem, _ rhs: ContextItem) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.description < rhs.id.description
    }

    /// Items per kind, for the session header.
    public static func counts(_ items: [ContextItem]) -> [SessionItemKind: Int] {
        items.reduce(into: [:]) { counts, item in counts[kind(of: item), default: 0] += 1 }
    }

    // MARK: Search

    /// Items whose text, link, file name or detected values contain `query`.
    /// Case-, diacritic- and digit-insensitive: "٤٢" finds "42", "مدرسة" finds "مَدرسة".
    public static func search(_ items: [ContextItem], for query: String) -> [ContextItem] {
        let needle = fold(query)
        guard !needle.isEmpty else { return items }
        return items.filter { item in searchableTexts(of: item).contains { fold($0).contains(needle) } }
    }

    static func searchableTexts(of item: ContextItem) -> [String] {
        var texts: [String] = []
        switch item.content {
        case .text(let text): texts.append(text)
        case .url(let url): texts.append(url.absoluteString)
        case .file(let reference): texts.append(reference.originalFilename ?? reference.relativePath)
        }
        for entity in item.entities {
            if let matched = entity.matchedText { texts.append(matched) }
            if let normalized = entity.normalizedText { texts.append(normalized) }
        }
        for key in ["title", "expression", "result"] {
            if let value = item.metadata[key]?.stringValue { texts.append(value) }
        }
        return texts
    }

    static func fold(_ text: String) -> String {
        Normalizer.whitespace(Normalizer.digits(text))
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
