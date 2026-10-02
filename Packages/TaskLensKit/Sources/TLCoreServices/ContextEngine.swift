import Foundation
import TLDomain
import TLFoundation

/// Rule-based Context Engine: classifies content and finds entities in it.
///
/// Uses only Foundation (`NSDataDetector`, regular expressions, `JSONSerialization`),
/// runs on device and needs no network or AI. Arabic-Indic digits are understood.
public struct ContextEngine: EntityDetecting {
    public init() {}

    // MARK: EntityDetecting

    public func detectEntities(in content: ContextContent) async throws -> [DetectedEntity] {
        Self.analyze(content).entities
    }

    // MARK: Analysis

    /// Category and entities for any content.
    public static func analyze(_ content: ContextContent) -> (category: ContentCategory, entities: [DetectedEntity]) {
        switch content {
        case .url(let url):
            return (.url, [primary(.url, .url(url), text: url.absoluteString)])
        case .file(let reference):
            switch reference.kind {
            case .image: return (.image, [])
            case .pdf: return (.pdf, [])
            case .text, .document: return (.document, [])
            }
        case .text(let text):
            return analyze(text: text)
        }
    }

    /// Text is classified as a whole first (is it a phone number? a price?),
    /// then searched for entities inside it.
    public static func analyze(text raw: String) -> (category: ContentCategory, entities: [DetectedEntity]) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (.unknown, []) }

        if let whole = classifyWhole(text) {
            return whole
        }
        let entities = findEntities(in: text)
        if looksLikeCode(text) {
            return (.code, [primary(.code, .text(text), text: text, confidence: .medium)] + entities)
        }
        let hasLetters = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        return (hasLetters ? .plainText : .unknown, entities)
    }

    // MARK: Whole-content rules

    private static func classifyWhole(_ text: String) -> (ContentCategory, [DetectedEntity])? {
        if let json = jsonValue(text) {
            return (.json, [primary(.json, .text(json), text: text)])
        }
        if case .url(let url) = ContentClassifier.classify(text) {
            return (.url, [primary(.url, .url(url), text: text)])
        }
        if isEmail(text) {
            return (.email, [primary(.email, .email(text), text: text)])
        }
        if let phone = phoneNumber(text) {
            return (.phone, [primary(.phoneNumber, .phoneNumber(phone), text: text)])
        }
        if let (amount, code) = currency(text) {
            return (.currency, [primary(.currencyAmount, .currency(amount: amount, currencyCode: code), text: text)])
        }
        if let number = number(text) {
            return (.number, [primary(.number, .number(number), text: text)])
        }
        let normalized = normalizeDigits(text)
        let length = (normalized as NSString).length
        for match in detector?.matches(in: normalized, range: NSRange(location: 0, length: length)) ?? []
        where Double(match.range.length) >= Double(length) * 0.8 {
            if match.resultType == .date, let date = match.date {
                return (.date, [primary(.date, .date(date), text: text, range: match.range)])
            }
            if match.resultType == .address, let components = match.addressComponents {
                return (.address, [primary(.address, .address(addressDictionary(components)), text: text, range: match.range)])
            }
        }
        return nil
    }

    // MARK: Entities inside text

    static func findEntities(in text: String) -> [DetectedEntity] {
        let normalized = normalizeDigits(text)
        let nsText = normalized as NSString
        var entities: [DetectedEntity] = []

        for match in detector?.matches(in: normalized, range: NSRange(location: 0, length: nsText.length)) ?? [] {
            let matched = nsText.substring(with: match.range)
            let range = TextRange(location: match.range.location, length: match.range.length)
            switch match.resultType {
            case .link:
                guard let url = match.url else { continue }
                if url.scheme == "mailto" {
                    let address = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                    entities.append(DetectedEntity(type: .email, confidence: .high, value: .email(address), matchedText: matched, range: range))
                } else {
                    entities.append(DetectedEntity(type: .url, confidence: .high, value: .url(url), matchedText: matched, range: range))
                }
            case .phoneNumber:
                guard let phone = match.phoneNumber, digitCount(phone) >= 7 else { continue }
                entities.append(DetectedEntity(type: .phoneNumber, confidence: .medium, value: .phoneNumber(phone), matchedText: matched, range: range))
            case .date:
                guard let date = match.date else { continue }
                entities.append(DetectedEntity(type: .date, confidence: .medium, value: .date(date), matchedText: matched, range: range))
            case .address:
                guard let components = match.addressComponents else { continue }
                entities.append(DetectedEntity(type: .address, confidence: .medium, value: .address(addressDictionary(components)), matchedText: matched, range: range))
            default:
                continue
            }
        }

        // Prices inside sentences ("it costs $25").
        for match in currencyRegex.matches(in: normalized, range: NSRange(location: 0, length: nsText.length)) {
            let matched = nsText.substring(with: match.range)
            guard let (amount, code) = currency(matched) else { continue }
            entities.append(DetectedEntity(
                type: .currencyAmount, confidence: .medium, value: .currency(amount: amount, currencyCode: code),
                matchedText: matched, range: TextRange(location: match.range.location, length: match.range.length)
            ))
        }
        return entities.sorted { ($0.range?.location ?? 0) < ($1.range?.location ?? 0) }
    }

    // MARK: Rules

    // Regular expressions and data detectors are immutable and thread safe.
    nonisolated(unsafe) private static let detector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.date.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue
    )

    static func isEmail(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }

    /// A phone number on its own: optional +, 7–15 digits, common separators.
    static func phoneNumber(_ text: String) -> String? {
        let normalized = normalizeDigits(text)
        guard normalized.range(of: #"^\+?[0-9(][0-9 ()\-.]{5,}[0-9]$"#, options: .regularExpression) != nil else { return nil }
        let digits = digitCount(normalized)
        guard (7...15).contains(digits) else { return nil }
        // "1,250.75" or "2026.10.02" are not phone numbers: require a +, a space,
        // a dash or parentheses, or a leading 0, or 10+ digits.
        let hasPhoneShape = normalized.hasPrefix("+") || normalized.hasPrefix("0")
            || normalized.contains(" ") || normalized.contains("-") || normalized.contains("(") || digits >= 10
        let looksLikeDate = normalized.range(of: #"^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$"#, options: .regularExpression) != nil
        guard hasPhoneShape, !looksLikeDate, !normalized.contains(".") else { return nil }
        return normalized
    }

    /// Currency symbols and words, mapped to ISO codes where unambiguous.
    static let currencySymbols: [String: String?] = [
        "$": "USD", "US$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR", "₩": "KRW", "₺": "TRY",
        "﷼": "SAR", "ر.س": "SAR", "ر.س.": "SAR", "ريال": "SAR", "د.إ": "AED", "درهم": "AED",
        "د.ع": "IQD", "د.ك": "KWD", "ج.م": "EGP", "دينار": nil, "دولار": "USD", "يورو": "EUR",
    ]

    nonisolated(unsafe) private static let currencyRegex: NSRegularExpression = {
        let codes = Locale.commonISOCurrencyCodes.joined(separator: "|")
        let symbols = currencySymbols.keys.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let unit = "(?:\(symbols)|\\b(?:\(codes))\\b)"
        let amount = amountPattern
        // Raw pattern is built from escaped pieces, so it always compiles.
        return try! NSRegularExpression(pattern: "(?:\(unit)\\s?\(amount)|\(amount)\\s?\(unit))")
    }()

    private static let amountPattern = #"[0-9][0-9,]*(?:\.[0-9]+)?"#

    static func currency(_ text: String) -> (Decimal, String?)? {
        let normalized = normalizeDigits(text).trimmingCharacters(in: .whitespaces)
        let range = NSRange(location: 0, length: (normalized as NSString).length)
        guard let match = currencyRegex.firstMatch(in: normalized, range: range), match.range == range,
              let amountRange = normalized.range(of: amountPattern, options: .regularExpression),
              let amount = number(String(normalized[amountRange]))
        else { return nil }
        var unitText = normalized
        unitText.removeSubrange(amountRange)
        let unit = unitText.trimmingCharacters(in: .whitespaces)
        if let code = currencySymbols[unit] { return (amount, code) }
        let upper = unit.uppercased()
        return (amount, Locale.commonISOCurrencyCodes.contains(upper) ? upper : nil)
    }

    /// A plain number: "42", "-3.5", "1,250.75", "١٢٣٫٥".
    static func number(_ text: String) -> Decimal? {
        let normalized = normalizeDigits(text).trimmingCharacters(in: .whitespaces)
        guard normalized.range(of: #"^[-+]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?$"#, options: .regularExpression) != nil
        else { return nil }
        return Decimal(string: normalized.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX"))
    }

    static func jsonValue(_ text: String) -> String? {
        guard let first = text.first, first == "{" || first == "[",
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8)
        else { return nil }
        return string
    }

    /// At least two independent signs of source code.
    static func looksLikeCode(_ text: String) -> Bool {
        let signals: [String] = [
            #"(?m)^\s*(func|let|var|const|def|class|struct|enum|import|return|public|private|#include|package|fn)\b"#,
            #"(?m)[;{}]\s*$"#,
            #"=>|->|==|!=|\+\+|&&|\|\|"#,
            #"\b\w+\([^)]*\)\s*[{:;]"#,
            #"</?[a-zA-Z][a-zA-Z0-9]*(\s[^>]*)?>"#,
        ]
        let hits = signals.filter { text.range(of: $0, options: .regularExpression) != nil }.count
        return hits >= 2
    }

    // MARK: Helpers

    /// Arabic-Indic and Eastern Arabic-Indic digits to ASCII; Arabic decimal and
    /// thousands separators to "." and ",".
    public static func normalizeDigits(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0660...0x0669: result.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9: result.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!)
            case 0x066B: result.append(".")
            case 0x066C: result.append(",")
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func digitCount(_ text: String) -> Int {
        text.unicodeScalars.filter { ("0"..."9").contains($0) }.count
    }

    private static func addressDictionary(_ components: [NSTextCheckingKey: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: components.map { ($0.key.rawValue, $0.value) })
    }

    private static func primary(
        _ type: EntityType, _ value: EntityValue, text: String,
        confidence: Confidence = .high, range: NSRange? = nil
    ) -> DetectedEntity {
        let nsRange = range ?? NSRange(location: 0, length: (text as NSString).length)
        return DetectedEntity(
            type: type, confidence: confidence, value: value, matchedText: text,
            range: TextRange(location: nsRange.location, length: nsRange.length),
            metadata: [ContextAnalysis.primaryKey: .bool(true)]
        )
    }
}
