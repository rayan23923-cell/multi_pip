import Foundation
import TLFoundation

public typealias DetectedEntityID = Identifier<DetectedEntity>

/// Something meaningful found inside a context item: a phone number, a price, a date...
public struct DetectedEntity: Codable, Sendable, Hashable, Identifiable {
    public let id: DetectedEntityID
    public var type: EntityType
    public var confidence: Confidence
    public var value: EntityValue
    /// The exact text that produced this entity, when it came from text.
    public var matchedText: String?
    /// Location of `matchedText` in the source text, in UTF-16 units.
    public var range: TextRange?
    public var metadata: Metadata

    public init(
        id: DetectedEntityID = DetectedEntityID(),
        type: EntityType,
        confidence: Confidence,
        value: EntityValue,
        matchedText: String? = nil,
        range: TextRange? = nil,
        metadata: Metadata = [:]
    ) {
        self.id = id
        self.type = type
        self.confidence = confidence
        self.value = value
        self.matchedText = matchedText
        self.range = range
        self.metadata = metadata
    }
}

public struct EntityType: ExtensibleKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let url: EntityType = "url"
    public static let email: EntityType = "email"
    public static let phoneNumber: EntityType = "phoneNumber"
    public static let date: EntityType = "date"
    public static let address: EntityType = "address"
    public static let currencyAmount: EntityType = "currencyAmount"
    public static let number: EntityType = "number"
    public static let qrCode: EntityType = "qrCode"
    public static let barcode: EntityType = "barcode"
    public static let language: EntityType = "language"
    public static let json: EntityType = "json"
    public static let code: EntityType = "code"
}

/// Typed value of a detected entity.
public enum EntityValue: Codable, Sendable, Hashable {
    case text(String)
    case url(URL)
    case phoneNumber(String)
    case email(String)
    case date(Date)
    case currency(amount: Decimal, currencyCode: String?)
    case number(Decimal)
    case address([String: String])
}

/// A probability in `0...1`. Out-of-range input is clamped.
public struct Confidence: Codable, Sendable, Hashable, Comparable {
    public let value: Double

    public init(_ value: Double) {
        if value.isNaN {
            self.value = 0
        } else {
            self.value = min(max(value, 0), 1)
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(Double.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.value < rhs.value }

    public static let certain = Confidence(1)
    public static let high = Confidence(0.9)
    public static let medium = Confidence(0.6)
    public static let low = Confidence(0.3)
}

/// A range inside a text, in UTF-16 code units (compatible with `NSRange`).
public struct TextRange: Codable, Sendable, Hashable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}
