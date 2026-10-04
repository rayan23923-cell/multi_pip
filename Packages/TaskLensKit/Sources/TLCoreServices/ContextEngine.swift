import Foundation
import TLDomain
import TLFoundation

/// Rule-based Context Engine.
///
/// Input → Normalizer → Detectors → entity extraction (overlaps resolved) →
/// category. The Action Engine takes it from there. Everything is
/// deterministic and on device: Foundation only, no network, no AI.
public struct ContextEngine: EntityDetecting {
    public init() {}

    // MARK: EntityDetecting

    public func detectEntities(in content: ContextContent) async throws -> [DetectedEntity] {
        Self.analyze(content).entities
    }

    // MARK: Detectors

    /// Every detector, in precedence order: when two matches cover the same
    /// text, or several cover the whole content, the earlier type wins.
    /// "2026-10-15" is a date, not a number; "$25" is money, not a number.
    public static let detectors: [any ContentDetector] = [
        JSONDetector(), URLDetector(), EmailDetector(), PhoneDetector(), CurrencyDetector(),
        NumberDetector(), DateDetector(), AddressDetector(), CodeDetector(),
    ]

    static let precedence: [EntityType: Int] = Dictionary(
        uniqueKeysWithValues: detectors.enumerated().map { ($0.element.entityType, $0.offset) }
    )

    /// Category of content whose whole text is one entity of this type.
    static let categories: [EntityType: ContentCategory] = [
        .json: .json, .url: .url, .email: .email, .phoneNumber: .phone, .currencyAmount: .currency,
        .number: .number, .date: .date, .address: .address, .code: .code,
    ]

    // MARK: Analysis

    /// Category and entities for any content.
    public static func analyze(_ content: ContextContent) -> (category: ContentCategory, entities: [DetectedEntity]) {
        let result = analyze(Normalizer.normalize(content))
        return (result.category, result.entities)
    }

    /// Category and entities for text.
    public static func analyze(text: String) -> (category: ContentCategory, entities: [DetectedEntity]) {
        analyze(.text(text))
    }

    public static func analyze(_ input: NormalizedInput) -> (category: ContentCategory, entities: [DetectedEntity]) {
        switch input.kind {
        case .file(let file):
            switch file.kind {
            case .image: return (.image, [])
            case .pdf: return (.pdf, [])
            case .text, .document, .powerpoint: return (.document, [])
            }
        case .url:
            return (.url, URLDetector().detect(in: input))
        case .text:
            guard !input.text.isEmpty else { return (.unknown, []) }
            let entities = extract(detectors.flatMap { $0.detect(in: input) })
            return (category(of: entities, text: input.text), entities)
        }
    }

    /// Resolves what the detectors found into one list of entities, in text order.
    ///
    /// - JSON is structured data: when the content is JSON, nothing inside it is reported.
    /// - Code wraps the content: it is kept next to the entities found inside it.
    /// - Otherwise, of two overlapping matches the stronger one stays: the one
    ///   covering the whole content, then higher confidence, then the longer
    ///   match, then detector precedence.
    static func extract(_ found: [DetectedEntity]) -> [DetectedEntity] {
        if let json = found.first(where: { $0.type == .json && $0.isPrimary }) {
            return [json]
        }
        let containers = found.filter { $0.type == .code }
        let candidates = found.filter { $0.type != .code }.sorted(by: isStronger)

        var kept: [DetectedEntity] = []
        for entity in candidates where !kept.contains(where: { overlaps($0, entity) }) {
            kept.append(entity)
        }
        return (containers + kept).sorted { lhs, rhs in
            let left = lhs.range?.location ?? 0, right = rhs.range?.location ?? 0
            if left != right { return left < right }
            return isStronger(lhs, rhs)
        }
    }

    static func isStronger(_ lhs: DetectedEntity, _ rhs: DetectedEntity) -> Bool {
        if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        let left = lhs.range?.length ?? 0, right = rhs.range?.length ?? 0
        if left != right { return left > right }
        return (precedence[lhs.type] ?? .max) < (precedence[rhs.type] ?? .max)
    }

    static func overlaps(_ lhs: DetectedEntity, _ rhs: DetectedEntity) -> Bool {
        guard let a = lhs.range, let b = rhs.range else { return false }
        return a.location < b.location + b.length && b.location < a.location + a.length
    }

    /// The whole-content entity with the highest precedence decides the
    /// category; then code; then text if there are letters at all.
    static func category(of entities: [DetectedEntity], text: String) -> ContentCategory {
        let whole = entities.filter { $0.isPrimary && $0.type != .code }
            .min { (precedence[$0.type] ?? .max) < (precedence[$1.type] ?? .max) }
        if let whole, let category = categories[whole.type] { return category }
        if entities.contains(where: { $0.type == .code }) { return .code }
        let hasLetters = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        return hasLetters ? .plainText : .unknown
    }

    // MARK: Compatibility

    /// Arabic-Indic digits to ASCII. See `Normalizer.digits`.
    public static func normalizeDigits(_ text: String) -> String {
        Normalizer.digits(text)
    }
}

extension DetectedEntity {
    /// True when this entity is the whole content.
    public var isPrimary: Bool {
        metadata[ContextAnalysis.primaryKey]?.boolValue == true
    }

    /// The value in canonical text form, as detectors normalized it.
    public var normalizedText: String? {
        metadata[DetectionKey.normalized]?.stringValue ?? matchedText
    }

    /// The YouTube video this link points to, read from the URL (no network).
    public var youTubeLink: YouTubeLink? {
        guard type == .url, metadata[DetectionKey.platform]?.stringValue == YouTubeLink.platform,
              case .url(let url) = value else { return nil }
        return YouTubeLink.parse(url)
    }
}

extension ContextAnalysis {
    /// The YouTube video, when the whole content is one YouTube link.
    public var youTubeLink: YouTubeLink? {
        category == .url ? primaryEntity?.youTubeLink : nil
    }
}
