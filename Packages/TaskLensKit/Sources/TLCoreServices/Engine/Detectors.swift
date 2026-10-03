import Foundation
import TLDomain
import TLFoundation

/// One deterministic detector of the Context Engine.
///
/// Each detector looks for one kind of entity in normalized text and returns
/// every match as a `DetectedEntity`: its type, typed value, confidence and
/// metadata. A match that is the whole content is flagged with
/// `ContextAnalysis.primaryKey`. Detectors use only Foundation, run on device
/// and give the same answer for the same input.
public protocol ContentDetector: Sendable {
    var entityType: EntityType { get }
    func detect(in input: NormalizedInput) -> [DetectedEntity]
}

/// Metadata keys written by detectors.
public enum DetectionKey {
    /// The value in canonical form (dialable phone, ISO date, POSIX number...).
    public static let normalized = "normalized"
    public static let detector = "detector"
    public static let currencyCode = "currencyCode"
    public static let currencySymbol = "symbol"
    public static let host = "host"
    public static let scheme = "scheme"
    public static let domain = "domain"
    public static let international = "international"
    public static let digitCount = "digitCount"
    public static let includesTime = "includesTime"
    public static let isInteger = "isInteger"
    public static let structure = "structure"
    public static let count = "count"
    public static let language = "language"
    public static let signals = "signals"
    /// A link to a known media platform: "youtube".
    public static let platform = "platform"
    /// What the link points to on that platform: "video".
    public static let contentType = "contentType"
    public static let videoID = "videoID"
    public static let startSeconds = "startSeconds"
}

/// Shared helpers for building entities.
enum Detection {
    static func entity(
        _ type: EntityType, _ value: EntityValue, confidence: Confidence,
        range: NSRange, in input: NormalizedInput, metadata: Metadata = [:], wholeTolerance: Double = 1
    ) -> DetectedEntity {
        var metadata = metadata
        metadata[DetectionKey.detector] = .string(type.rawValue)
        if covers(range, input, tolerance: wholeTolerance) {
            metadata[ContextAnalysis.primaryKey] = .bool(true)
        }
        return DetectedEntity(
            type: type, confidence: confidence, value: value,
            matchedText: (input.text as NSString).substring(with: range),
            range: TextRange(location: range.location, length: range.length),
            metadata: metadata
        )
    }

    /// True when the match is the whole text, or at least `tolerance` of it.
    static func covers(_ range: NSRange, _ input: NormalizedInput, tolerance: Double) -> Bool {
        let length = input.length
        guard length > 0 else { return false }
        if range.location == 0 && range.length == length { return true }
        return tolerance < 1 && Double(range.length) >= Double(length) * tolerance
    }

    static func fullRange(_ input: NormalizedInput) -> NSRange {
        NSRange(location: 0, length: input.length)
    }

    static func digitCount(_ text: String) -> Int {
        text.unicodeScalars.filter { ("0"..."9").contains($0) }.count
    }

    /// Foundation's data detector; immutable and thread safe once created.
    static let dataDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.date.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue
    )

    static func matches(_ type: NSTextCheckingResult.CheckingType, in input: NormalizedInput) -> [NSTextCheckingResult] {
        guard input.length > 0 else { return [] }
        return (dataDetector?.matches(in: input.text, range: fullRange(input)) ?? []).filter { $0.resultType == type }
    }
}

// MARK: - URL

public struct URLDetector: ContentDetector {
    public init() {}
    public var entityType: EntityType { .url }

    public func detect(in input: NormalizedInput) -> [DetectedEntity] {
        if case .url(let url) = input.kind {
            return [make(url, range: Detection.fullRange(input), input: input, confidence: .certain)]
        }
        return Detection.matches(.link, in: input).compactMap { match in
            guard let found = match.url, found.scheme != "mailto" else { return nil }
            let matched = (input.text as NSString).substring(with: match.range)
            // Links typed with a scheme or "www." are certain; bare domains
            // ("example.com") might be a file name or a sentence end.
            let explicit = matched.lowercased().hasPrefix("http") || matched.lowercased().hasPrefix("www.")
            guard let url = Normalizer.url(matched) ?? Normalizer.url(found.absoluteString) else { return nil }
            return make(url, range: match.range, input: input, confidence: explicit ? .high : .medium)
        }
    }

    private func make(_ url: URL, range: NSRange, input: NormalizedInput, confidence: Confidence) -> DetectedEntity {
        var metadata: Metadata = [
            DetectionKey.normalized: .string(url.absoluteString),
            DetectionKey.host: .string(url.host ?? ""),
            DetectionKey.scheme: .string(url.scheme ?? ""),
        ]
        if let video = YouTubeLink.parse(url) {
            metadata[DetectionKey.platform] = .string(YouTubeLink.platform)
            metadata[DetectionKey.contentType] = .string(YouTubeLink.contentType)
            metadata[DetectionKey.videoID] = .string(video.videoID)
            if let start = video.startSeconds { metadata[DetectionKey.startSeconds] = .number(Double(start)) }
        }
        return Detection.entity(.url, .url(url), confidence: confidence, range: range, in: input, metadata: metadata)
    }
}

// MARK: - Email

public struct EmailDetector: ContentDetector {
    public init() {}
    public var entityType: EntityType { .email }

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9._%+\-])(?:mailto:)?([A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,})(?![A-Za-z0-9\-])"#,
        options: [.caseInsensitive]
    )

    public func detect(in input: NormalizedInput) -> [DetectedEntity] {
        guard case .text = input.kind else { return [] }
        let text = input.text as NSString
        return Self.pattern.matches(in: input.text, range: Detection.fullRange(input)).map { match in
            let address = text.substring(with: match.range(at: 1)).lowercased()
            let domain = String(address.split(separator: "@").last ?? "")
            return Detection.entity(.email, .email(address), confidence: .high, range: match.range, in: input, metadata: [
                DetectionKey.normalized: .string(address),
                DetectionKey.domain: .string(domain),
            ])
        }
    }
}

// MARK: - Phone

public struct PhoneDetector: ContentDetector {
    public init() {}
    public var entityType: EntityType { .phoneNumber }

    /// A phone number on its own: optional +, 7–15 digits, common separators.
    private static let wholePattern = #"^\+?[0-9(][0-9 ()\-.]{5,}[0-9]$"#

    public func detect(in input: NormalizedInput) -> [DetectedEntity] {
        guard case .text = input.kind else { return [] }
        if let whole = Self.wholePhone(input.text) {
            return [make(whole, range: Detection.fullRange(input), input: input)]
        }
        return Detection.matches(.phoneNumber, in: input).compactMap { match in
            guard let phone = match.phoneNumber, Detection.digitCount(phone) >= 7,
                  // The whole text already failed the stricter rules above ("2026-10-15").
                  !Detection.covers(match.range, input, tolerance: 1),
                  phone.range(of: #"^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$"#, options: .regularExpression) == nil
            else { return nil }
            return make(phone, range: match.range, input: input)
        }
    }

    private func make(_ display: String, range: NSRange, input: NormalizedInput) -> DetectedEntity {
        let dialable = Normalizer.phone(display)
        let digits = Detection.digitCount(dialable)
        let international = dialable.hasPrefix("+")
        // A + or a full-length number reads as a phone number; shorter local
        // numbers could also be order numbers.
        let confidence: Confidence = international || digits >= 10 ? .high : .medium
        return Detection.entity(.phoneNumber, .phoneNumber(dialable), confidence: confidence, range: range, in: input, metadata: [
            DetectionKey.normalized: .string(dialable),
            DetectionKey.international: .bool(international),
            DetectionKey.digitCount: .number(Double(digits)),
        ])
    }

    /// The whole text as a phone number, or nil. "1,250.75" and "2026-10-02"
    /// are not phone numbers.
    static func wholePhone(_ text: String) -> String? {
        guard text.range(of: wholePattern, options: .regularExpression) != nil else { return nil }
        let digits = Detection.digitCount(text)
        guard (7...15).contains(digits) else { return nil }
        let hasPhoneShape = text.hasPrefix("+") || text.hasPrefix("0")
            || text.contains(" ") || text.contains("-") || text.contains("(") || digits >= 10
        let looksLikeDate = text.range(of: #"^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$"#, options: .regularExpression) != nil
        guard hasPhoneShape, !looksLikeDate, !text.contains(".") else { return nil }
        return text
    }
}

// MARK: - Currency

public struct CurrencyDetector: ContentDetector {
    public init() {}
    public var entityType: EntityType { .currencyAmount }

    static let amountPattern = #"[0-9][0-9,]*(?:\.[0-9]+)?"#

    private static let pattern: NSRegularExpression = {
        let codes = Locale.commonISOCurrencyCodes.joined(separator: "|")
        let symbols = Normalizer.currencySymbols.keys.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let unit = "(?:\(symbols)|\\b(?:\(codes))\\b)"
        let amount = amountPattern
        // Built from escaped pieces, so it always compiles.
        return try! NSRegularExpression(pattern: "(?:\(unit)\\s?\(amount)|\(amount)\\s?\(unit))")
    }()

    public func detect(in input: NormalizedInput) -> [DetectedEntity] {
        guard case .text = input.kind else { return [] }
        let text = input.text as NSString
        return Self.pattern.matches(in: input.text, range: Detection.fullRange(input)).compactMap { match in
            guard let (amount, unit, code) = Self.parse(text.substring(with: match.range)) else { return nil }
            var metadata: Metadata = [
                DetectionKey.normalized: .string(Normalizer.string(amount)),
                DetectionKey.currencySymbol: .string(unit),
            ]
            if let code { metadata[DetectionKey.currencyCode] = .string(code) }
            // An ambiguous unit (dinar) is still money, but less certain.
            return Detection.entity(.currencyAmount, .currency(amount: amount, currencyCode: code),
                                    confidence: code == nil ? .medium : .high, range: match.range, in: input, metadata: metadata)
        }
    }

    /// Amount, the unit as written and its ISO code.
    static func parse(_ text: String) -> (Decimal, String, String?)? {
        guard let amountRange = text.range(of: amountPattern, options: .regularExpression),
              let amount = Normalizer.decimal(String(text[amountRange]))
        else { return nil }
        var unit = text
        unit.removeSubrange(amountRange)
        unit = unit.trimmingCharacters(in: .whitespaces)
        return (amount, unit, Normalizer.currencyCode(unit))
    }
}

// MARK: - Number

public struct NumberDetector: ContentDetector {
    public init() {}
    public var entityType: EntityType { .number }

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\w.,\-+])[-+]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?(?![\w.,]*[0-9A-Za-z])"#
    )

    public func detect(in input: NormalizedInput) -> [DetectedEntity] {
        guard case .text = input.kind else { return [] }
        let text = input.text as NSString
        return Self.pattern.matches(in: input.text, range: Detection.fullRange(input)).compactMap { match in
            guard let value = Normalizer.decimal(text.substring(with: match.range)) else { return nil }
            let whole = Detection.covers(match.range, input, tolerance: 1)
            // A number on its own is clearly a number; a number in a sentence
            // ("3 people") is rarely something to act on.
            return Detection.entity(.number, .number(value), confidence: whole ? .high : .low,
                                    range: match.range, in: input, metadata: [
                DetectionKey.normalized: .string(Normalizer.string(value)),
                DetectionKey.isInteger: .bool(value == value.integerPart),
            ])
        }
    }
}

private extension Decimal {
    var integerPart: Decimal {
        var source = self
        var result = Decimal()
        NSDecimalRound(&result, &source, 0, .plain)
        return result
    }
}

// MARK: - Date

public struct DateDetector: ContentDetector {
    public init() {}
    public var entityType: EntityType { .date }

    public func detect(in input: NormalizedInput) -> [DetectedEntity] {
        guard case .text = input.kind else { return [] }
        return Detection.matches(.date, in: input).compactMap { match in
            guard let date = match.date else { return nil }
            let matched = (input.text as NSString).substring(with: match.range)
            let includesTime = Self.mentionsTime(matched)
            // "October 15, 2026" is certain; "Friday" or "tomorrow" alone is softer.
            let confidence: Confidence = Detection.digitCount(matched) >= 2 ? .high : .medium
            return Detection.entity(.date, .date(date), confidence: confidence, range: match.range, in: input, metadata: [
                DetectionKey.normalized: .string(Normalizer.date(date, includesTime: includesTime)),
                DetectionKey.includesTime: .bool(includesTime),
            ], wholeTolerance: 0.8)
        }
    }

    /// True for "3:00", "5pm", "at 17".
    static func mentionsTime(_ text: String) -> Bool {
        text.range(of: #"[0-9]{1,2}:[0-9]{2}|[0-9]\s?(?:am|pm|AM|PM|ص|م)\b|\bat\s[0-9]"#, options: .regularExpression) != nil
    }
}

// MARK: - Address

public struct AddressDetector: ContentDetector {
    public init() {}
    public var entityType: EntityType { .address }

    public func detect(in input: NormalizedInput) -> [DetectedEntity] {
        guard case .text = input.kind else { return [] }
        return Detection.matches(.address, in: input).compactMap { match in
            guard let components = match.addressComponents, !components.isEmpty else { return nil }
            let dictionary = Dictionary(uniqueKeysWithValues: components.map { ($0.key.rawValue, $0.value) })
            // A street plus a city or postcode is an address; one part alone may not be.
            let confidence: Confidence = components.count >= 2 ? .high : .medium
            let normalized = (input.text as NSString).substring(with: match.range)
                .replacingOccurrences(of: "\n", with: ", ")
            return Detection.entity(.address, .address(dictionary), confidence: confidence, range: match.range, in: input, metadata: [
                DetectionKey.normalized: .string(normalized),
                DetectionKey.count: .number(Double(components.count)),
            ], wholeTolerance: 0.8)
        }
    }
}

// MARK: - JSON

public struct JSONDetector: ContentDetector {
    public init() {}
    public var entityType: EntityType { .json }

    /// Whole-content only: a JSON object or array, pretty-printed as the value.
    public func detect(in input: NormalizedInput) -> [DetectedEntity] {
        guard case .text = input.kind, let first = input.text.first, first == "{" || first == "[",
              let data = input.text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8)
        else { return [] }
        let structure: String
        let count: Int
        if let dictionary = object as? [String: Any] {
            structure = "object"
            count = dictionary.count
        } else {
            structure = "array"
            count = (object as? [Any])?.count ?? 0
        }
        return [Detection.entity(.json, .text(string), confidence: .certain, range: Detection.fullRange(input), in: input, metadata: [
            DetectionKey.normalized: .string(string),
            DetectionKey.structure: .string(structure),
            DetectionKey.count: .number(Double(count)),
        ])]
    }
}

// MARK: - Code

public struct CodeDetector: ContentDetector {
    public init() {}
    public var entityType: EntityType { .code }

    private static let signals: [String] = [
        #"(?m)^\s*(func|let|var|const|def|class|struct|enum|import|return|public|private|#include|package|fn)\b"#,
        #"(?m)[;{}]\s*$"#,
        #"=>|->|==|!=|\+\+|&&|\|\|"#,
        #"\b\w+\([^)]*\)\s*[{:;]"#,
        #"</?[a-zA-Z][a-zA-Z0-9]*(\s[^>]*)?>"#,
    ]

    /// Language hints, checked in order. Only a label for the UI and ranking.
    private static let languages: [(String, String)] = [
        ("swift", #"\b(func|guard|let)\b.*(->|\{)|\bstruct\s+\w+\s*:"#),
        ("python", #"(?m)^\s*(def|class)\s+\w+.*:\s*$|^\s*import\s+\w+\s*$"#),
        ("html", #"</?(html|div|span|p|a|body|head)\b"#),
        ("javascript", #"\b(const|function)\b|=>"#),
        ("c", #"#include\s*<"#),
    ]

    /// Whole-content only, and only with at least two independent signs of code.
    public func detect(in input: NormalizedInput) -> [DetectedEntity] {
        guard case .text = input.kind else { return [] }
        let hits = Self.signalCount(input.text)
        guard hits >= 2 else { return [] }
        let language = Self.languages.first { input.text.range(of: $0.1, options: .regularExpression) != nil }?.0
        var metadata: Metadata = [DetectionKey.signals: .number(Double(hits))]
        if let language { metadata[DetectionKey.language] = .string(language) }
        // Two signals could still be prose with symbols; four or more is code.
        let confidence = Confidence(0.4 + 0.15 * Double(hits))
        return [Detection.entity(.code, .text(input.text), confidence: confidence, range: Detection.fullRange(input),
                                 in: input, metadata: metadata)]
    }

    static func signalCount(_ text: String) -> Int {
        signals.filter { text.range(of: $0, options: .regularExpression) != nil }.count
    }
}
