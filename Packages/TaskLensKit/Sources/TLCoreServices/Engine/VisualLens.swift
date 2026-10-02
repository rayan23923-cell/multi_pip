import Foundation
import TLDomain
import TLFoundation

// Action Lens for images: what Vision read from an image, turned into
// findings with recommended actions.
//
// Image → preprocessing → Vision (text, codes) → **this file**:
// normalized text → Context Engine detectors → entities → findings → actions.
//
// Everything here is pure and on device. Vision itself runs in the app
// (LensFeature); this part is plain data so it is tested without images.

/// One line of text Vision recognized.
public struct RecognizedLine: Sendable, Equatable {
    public var text: String
    /// Vision's confidence, 0...1.
    public var confidence: Double
    /// Position in the image, normalized 0...1 with the origin at the bottom left
    /// (Vision's convention). Nil when unknown.
    public var box: Box?

    public struct Box: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var midY: Double { y + height / 2 }
    }

    public init(text: String, confidence: Double, box: Box? = nil) {
        self.text = text
        self.confidence = confidence
        self.box = box
    }
}

/// A QR code or barcode Vision decoded.
public struct RecognizedCode: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case qr
        case barcode
    }

    public var payload: String
    public var kind: Kind
    /// The symbology Vision reported, e.g. "VNBarcodeSymbologyEAN13".
    public var symbology: String
    public var confidence: Double

    public init(payload: String, kind: Kind, symbology: String, confidence: Double) {
        self.payload = payload
        self.kind = kind
        self.symbology = symbology
        self.confidence = confidence
    }
}

/// Everything Vision found in one image.
public struct VisualRecognition: Sendable, Equatable {
    public var lines: [RecognizedLine]
    public var codes: [RecognizedCode]

    public init(lines: [RecognizedLine] = [], codes: [RecognizedCode] = []) {
        self.lines = lines
        self.codes = codes
    }

    public var isEmpty: Bool { lines.isEmpty && codes.isEmpty }
}

/// A simple reading of the page: a title when one line stands out, then
/// paragraphs separated by larger vertical gaps.
public struct DocumentStructure: Sendable, Equatable {
    public var title: String?
    public var paragraphs: [String]

    public init(title: String? = nil, paragraphs: [String] = []) {
        self.title = title
        self.paragraphs = paragraphs
    }
}

/// OCR text cleaned for the detectors, with the line each part came from.
public struct OCRText: Sendable, Equatable {
    public var text: String
    /// For each line in reading order: its UTF-16 range in `text`, its confidence,
    /// and whether characters were corrected (O→0 in a number).
    public var lines: [Line]

    public struct Line: Sendable, Equatable {
        public var range: NSRange
        public var confidence: Double
        public var corrected: Bool
    }
}

public enum OCRNormalizer {
    /// Lines whose centers are closer than this (as a fraction of line height)
    /// are on the same row.
    static let rowTolerance = 0.5

    /// Lines in reading order: top to bottom, then along the row. Arabic rows
    /// read right to left. Lines without positions keep Vision's order.
    public static func readingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        guard lines.allSatisfy({ $0.box != nil }) else { return lines }
        let sorted = lines.sorted { ($0.box!.midY) > ($1.box!.midY) }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if let last = rows.last?.first, let a = last.box, let b = line.box,
               abs(a.midY - b.midY) < max(a.height, b.height) * rowTolerance {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { row in
            let rightToLeft = row.contains { isRightToLeft($0.text) }
            return row.sorted { rightToLeft ? $0.box!.x > $1.box!.x : $0.box!.x < $1.box!.x }
        }
    }

    public static func normalize(_ lines: [RecognizedLine]) -> OCRText {
        var text = ""
        var ranges: [OCRText.Line] = []
        for line in readingOrder(lines) {
            let (cleaned, corrected) = correctNumbers(Normalizer.text(line.text))
            guard !cleaned.isEmpty else { continue }
            if !text.isEmpty { text += "\n" }
            let start = (text as NSString).length
            text += cleaned
            ranges.append(.init(range: NSRange(location: start, length: (cleaned as NSString).length),
                                confidence: line.confidence, corrected: corrected))
        }
        return OCRText(text: text, lines: ranges)
    }

    /// Common OCR slips inside numbers: "1O5" → "105", "$l2" → "$12".
    /// Only tokens that are mostly digits already are touched, so words stay as they are.
    public static func correctNumbers(_ line: String) -> (String, Bool) {
        var corrected = false
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false).map { token -> String in
            let digits = token.filter(\.isNumber).count
            let lookalikes = token.filter { "OoIl".contains($0) }.count
            guard digits >= 2, lookalikes > 0, lookalikes < digits,
                  token.allSatisfy({ $0.isNumber || "OoIl.,:/-+$€£¥%()".contains($0) }) else { return String(token) }
            corrected = true
            return String(token.map { character -> Character in
                switch character {
                case "O", "o": "0"
                case "I", "l": "1"
                default: character
                }
            })
        }
        return (tokens.joined(separator: " "), corrected)
    }

    /// Title and paragraphs from line positions.
    public static func structure(_ lines: [RecognizedLine]) -> DocumentStructure {
        let ordered = readingOrder(lines).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !ordered.isEmpty else { return DocumentStructure() }
        let heights = ordered.compactMap { $0.box?.height }.sorted()
        let median = heights.isEmpty ? 0 : heights[heights.count / 2]

        var title: String?
        var body = ordered
        if let first = ordered.first, let height = first.box?.height, median > 0,
           height >= median * 1.3, ordered.count > 1 {
            title = first.text
            body.removeFirst()
        }

        var paragraphs: [String] = []
        var current: [String] = []
        var previous: RecognizedLine?
        for line in body {
            if let previous, let a = previous.box, let b = line.box,
               a.y - (b.y + b.height) > max(a.height, b.height) * 0.8 {
                paragraphs.append(current.joined(separator: " "))
                current = []
            }
            current.append(line.text)
            previous = line
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return DocumentStructure(title: title, paragraphs: paragraphs)
    }

    static func isRightToLeft(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0590...0x08FF).contains($0.value) }
    }
}

/// Something the Lens found, ready to show under "What I found".
public struct LensFinding: Sendable, Equatable, Identifiable {
    public enum Certainty: String, Sendable, Equatable {
        /// Read clearly: actions are offered directly.
        case confident
        /// Probably right but the image was hard to read: shown as a
        /// "Possible match" the user checks before any action.
        case possible
    }

    public enum Source: Sendable, Equatable {
        case text
        case code(RecognizedCode.Kind)
        /// All the recognized text, for Translate / Copy / Save.
        case allText
    }

    public var id: String
    public var entityType: EntityType?
    /// The value as text: what the user sees and what actions act on.
    public var text: String
    public var confidence: Double
    public var certainty: Certainty
    public var source: Source

    public init(id: String, entityType: EntityType?, text: String, confidence: Double, certainty: Certainty, source: Source) {
        self.id = id
        self.entityType = entityType
        self.text = text
        self.confidence = confidence
        self.certainty = certainty
        self.source = source
    }

    /// The content actions are suggested for.
    public var content: ContextContent {
        if case .code = source, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return .url(url)
        }
        return .text(text)
    }
}

/// The Lens report for one image.
public struct LensReport: Sendable, Equatable {
    public var findings: [LensFinding]
    public var text: OCRText
    public var structure: DocumentStructure

    public var isEmpty: Bool { findings.isEmpty }
}

public enum VisualLensAnalyzer {
    /// Below this, a finding is only a "Possible match".
    public static let confidentThreshold = 0.6
    /// A corrected value (O read as 0) is less certain.
    static let correctionPenalty = 0.75
    /// Most findings shown; the rest of the text stays in "All text".
    public static let maximumFindings = 8

    /// The entity types worth their own finding, most useful first.
    static let order: [EntityType] = [
        .url, .phoneNumber, .email, .currencyAmount, .date, .address, .number, .code, .json,
    ]

    public static func report(for recognition: VisualRecognition) -> LensReport {
        let ocr = OCRNormalizer.normalize(recognition.lines)
        var findings: [LensFinding] = []

        for (index, code) in recognition.codes.enumerated() {
            let payload = code.payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { continue }
            findings.append(LensFinding(
                id: "code-\(index)",
                entityType: code.kind == .qr ? .qrCode : .barcode,
                text: String(payload.prefix(DeepLinkLimits.maximumPayload)),
                confidence: code.confidence,
                certainty: certainty(code.confidence),
                source: .code(code.kind)
            ))
        }

        let entities = ContextEngine.analyze(text: ocr.text).entities
            .filter { order.contains($0.type) }
        for entity in entities {
            let lineConfidence = confidence(of: entity, in: ocr)
            let value = entity.matchedText ?? entity.normalizedText ?? ""
            guard !value.isEmpty, !findings.contains(where: { $0.text == value }) else { continue }
            let combined = entity.confidence.value * lineConfidence
            findings.append(LensFinding(
                id: "entity-\(entity.range?.location ?? findings.count)-\(entity.type.rawValue)",
                entityType: entity.type,
                text: value,
                confidence: combined,
                certainty: certainty(combined),
                source: .text
            ))
        }

        findings.sort { lhs, rhs in
            if lhs.certainty != rhs.certainty { return lhs.certainty == .confident }
            let left = rank(lhs), right = rank(rhs)
            if left != right { return left < right }
            return lhs.confidence > rhs.confidence
        }
        findings = Array(findings.prefix(maximumFindings))

        if !ocr.text.isEmpty {
            let average = ocr.lines.map(\.confidence).reduce(0, +) / Double(max(ocr.lines.count, 1))
            findings.append(LensFinding(
                id: "all-text", entityType: nil, text: ocr.text, confidence: average,
                certainty: certainty(average), source: .allText
            ))
        }
        return LensReport(findings: findings, text: ocr, structure: OCRNormalizer.structure(recognition.lines))
    }

    public static func certainty(_ confidence: Double) -> LensFinding.Certainty {
        confidence >= confidentThreshold ? .confident : .possible
    }

    /// The weakest line the entity came from, lowered if a character was corrected.
    static func confidence(of entity: DetectedEntity, in ocr: OCRText) -> Double {
        guard let range = entity.range else { return ocr.lines.map(\.confidence).min() ?? 1 }
        let overlapping = ocr.lines.filter {
            $0.range.location < range.location + range.length && range.location < $0.range.location + $0.range.length
        }
        guard !overlapping.isEmpty else { return 1 }
        let base = overlapping.map(\.confidence).min() ?? 1
        return overlapping.contains(where: \.corrected) ? base * correctionPenalty : base
    }

    static func rank(_ finding: LensFinding) -> Int {
        if case .code = finding.source { return -1 }
        return finding.entityType.flatMap { order.firstIndex(of: $0) } ?? order.count
    }
}

/// Limits for text carried out of an image.
public enum DeepLinkLimits {
    /// Longest code payload kept (a QR code holds at most about 4 KB).
    public static let maximumPayload = 4_096
}
