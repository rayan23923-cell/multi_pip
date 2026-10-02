import Foundation
import TLFoundation

/// A persisted domain model with a type-safe identifier.
public protocol Entity: Identifiable, Codable, Sendable, Equatable where ID == Identifier<Self> {
    /// Stable name used for storage file names and error messages.
    static var entityName: String { get }
}

/// A string-backed, open-ended kind.
///
/// Unlike a closed `enum`, an unknown raw value written by a newer app version
/// (or a future extension) still decodes, so stored data never becomes unreadable.
/// Coding uses the standard library's `RawRepresentable` implementation, which
/// cannot fail here because `init(rawValue:)` accepts any string.
public protocol ExtensibleKind: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral
where RawValue == String {
    init(rawValue: String)
}

extension ExtensibleKind {
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}
