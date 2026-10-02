import Foundation
import TLDomain

/// Content after the Normalizer: the first stage of the Context Engine.
///
/// Detectors only ever see `text`, so they never deal with invisible
/// characters, Arabic-Indic digits or Windows line breaks themselves.
public struct NormalizedInput: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        case url(URL)
        case file(FileMetadata)
    }

    public var kind: Kind
    /// Normalized text for detection. For a link it is the normalized URL;
    /// for a file it is empty.
    public var text: String
    public var source: ContextSource?

    public init(kind: Kind, text: String, source: ContextSource? = nil) {
        self.kind = kind
        self.text = text
        self.source = source
    }

    /// Length of `text` in UTF-16 units, the unit of `TextRange`.
    public var length: Int { (text as NSString).length }
}

/// What the engine knows about a file without opening it.
public struct FileMetadata: Sendable, Equatable {
    public var filename: String
    public var fileExtension: String
    public var kind: FileKind
    public var typeIdentifier: String
    public var byteCount: Int64?

    public init(filename: String, fileExtension: String, kind: FileKind, typeIdentifier: String, byteCount: Int64?) {
        self.filename = filename
        self.fileExtension = fileExtension
        self.kind = kind
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
    }
}

/// Deterministic clean-up of content before detection. Pure functions only.
public enum Normalizer {
    public static func normalize(_ content: ContextContent, source: ContextSource? = nil) -> NormalizedInput {
        switch content {
        case .text(let raw):
            return NormalizedInput(kind: .text, text: text(raw), source: source)
        case .url(let url):
            let normalized = self.url(url.absoluteString) ?? url
            return NormalizedInput(kind: .url(normalized), text: normalized.absoluteString, source: source)
        case .file(let reference):
            return NormalizedInput(kind: .file(fileMetadata(reference)), text: "", source: source)
        }
    }

    // MARK: Text

    /// Whitespace and digits normalized, trimmed.
    public static func text(_ raw: String) -> String {
        whitespace(digits(raw))
    }

    /// Characters removed before detection: zero-width space, BOM, soft hyphen
    /// and bidirectional marks that copy-paste from RTL text often carries.
    /// The zero-width joiner and non-joiner are kept: emoji and Persian need them.
    private static let invisible: Set<UInt32> = [
        0x200B, 0xFEFF, 0x00AD, 0x200E, 0x200F, 0x061C,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
    ]

    /// Space-like characters treated as a plain space.
    private static let spaces: Set<UInt32> = [0x0009, 0x00A0, 0x2007, 0x202F, 0x205F, 0x3000, 0x2000, 0x2001,
                                               0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2008, 0x2009, 0x200A]

    /// Unifies line breaks, drops invisible characters, collapses runs of spaces
    /// inside each line (indentation stays), keeps at most one empty line
    /// between paragraphs, trims.
    public static func whitespace(_ raw: String) -> String {
        var cleaned = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in raw.unicodeScalars {
            if invisible.contains(scalar.value) { continue }
            if scalar == "\r" {
                cleaned.append("\n")
            } else if scalar == "\n", previous == "\r" {
                // Second half of \r\n.
            } else if spaces.contains(scalar.value) || scalar == "\u{0B}" || scalar == "\u{0C}" {
                cleaned.append(" ")
            } else if scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == "\u{85}" {
                cleaned.append("\n")
            } else {
                cleaned.append(scalar)
            }
            previous = scalar
        }

        var lines: [String] = []
        var blankRun = 0
        for line in String(cleaned).split(separator: "\n", omittingEmptySubsequences: false) {
            // Leading indentation is kept: it is meaning in code and lists.
            let indent = line.prefix { $0 == " " }
            let collapsed = line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            if collapsed.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
                lines.append("")
            } else {
                blankRun = 0
                lines.append(String(indent) + collapsed)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Arabic-Indic and Eastern Arabic-Indic digits to ASCII; Arabic decimal and
    /// thousands separators to "." and ",".
    public static func digits(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0660...0x0669: result.append(Unicode.Scalar(scalar.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9: result.append(Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!)
            case 0x066B: result.append(".")
            case 0x066C: result.append(",")
            default: result.append(scalar)
            }
        }
        return String(result)
    }

    // MARK: Values

    /// Trailing punctuation that belongs to the sentence, not the link.
    private static let trailingURLPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\"", "،", "؛", "؟"]

    /// A canonical web URL: `https://` added to `www.` links, scheme and host
    /// lowercased, default ports and a bare trailing `#` removed, sentence
    /// punctuation and unbalanced closing brackets trimmed. Nil for anything
    /// that is not an http(s) link.
    public static func url(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last {
            if trailingURLPunctuation.contains(last) {
                text.removeLast()
            } else if let open = ["(": ")", "[": "]", "{": "}"].first(where: { $0.value == String(last) })?.key,
                      text.filter({ String($0) == open }).count < text.filter({ $0 == last }).count {
                text.removeLast()
            } else {
                break
            }
        }
        if text.lowercased().hasPrefix("www.") { text = "https://" + text }
        if text.hasSuffix("#") { text.removeLast() }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, !host.contains(" ")
        else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        return components.url
    }

    /// Dialable form: digits only, with a leading `+` for international
    /// numbers (`00` becomes `+`). "+964 770 123 4567" → "+9647701234567".
    public static func phone(_ raw: String) -> String {
        let text = digits(raw).trimmingCharacters(in: .whitespaces)
        let numerals = String(text.filter { ("0"..."9").contains($0) })
        if text.hasPrefix("+") { return "+" + numerals }
        if numerals.hasPrefix("00"), numerals.count > 9 { return "+" + numerals.dropFirst(2) }
        return numerals
    }

    /// Currency symbols and words mapped to ISO 4217 codes. `nil` marks a word
    /// that is a currency but shared by several countries (dinar).
    public static let currencySymbols: [String: String?] = [
        "$": "USD", "US$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR", "₩": "KRW", "₺": "TRY",
        "﷼": "SAR", "ر.س": "SAR", "ر.س.": "SAR", "ريال": "SAR", "د.إ": "AED", "درهم": "AED",
        "د.ع": "IQD", "د.ك": "KWD", "ج.م": "EGP", "دينار": nil, "دولار": "USD", "يورو": "EUR",
    ]

    /// ISO code for a currency symbol, word or code; nil when unknown or ambiguous.
    public static func currencyCode(_ unit: String) -> String? {
        let trimmed = unit.trimmingCharacters(in: .whitespaces)
        if let code = currencySymbols[trimmed] { return code }
        let upper = trimmed.uppercased()
        return Locale.commonISOCurrencyCodes.contains(upper) ? upper : nil
    }

    /// A decimal in POSIX format: "1,250.75" → 1250.75. Nil if not a plain number.
    public static func decimal(_ raw: String) -> Decimal? {
        let text = digits(raw).trimmingCharacters(in: .whitespaces)
        guard text.range(of: #"^[-+]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?$"#, options: .regularExpression) != nil
        else { return nil }
        return Decimal(string: text.replacingOccurrences(of: ",", with: ""), locale: posix)
    }

    /// Decimal as POSIX text, the form actions pass around ("1250.75").
    public static func string(_ decimal: Decimal) -> String {
        NSDecimalNumber(decimal: decimal).description(withLocale: posix)
    }

    /// ISO 8601 text for a date: "2026-10-15" for an all-day date,
    /// "2026-10-15T15:00:00Z" when the time matters.
    public static func date(_ date: Date, includesTime: Bool) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = includesTime ? [.withInternetDateTime] : [.withFullDate]
        if !includesTime { formatter.timeZone = .current }
        return formatter.string(from: date)
    }

    public static func fileMetadata(_ reference: FileReference) -> FileMetadata {
        let filename = reference.originalFilename ?? (reference.relativePath as NSString).lastPathComponent
        return FileMetadata(
            filename: filename,
            fileExtension: (filename as NSString).pathExtension.lowercased(),
            kind: reference.kind,
            typeIdentifier: reference.contentType,
            byteCount: reference.byteCount
        )
    }

    static let posix = Locale(identifier: "en_US_POSIX")
}
