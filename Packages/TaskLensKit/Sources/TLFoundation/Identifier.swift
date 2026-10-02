import Foundation

/// A type-safe identifier. `Tag` is a phantom type so a `Identifier<Workspace>`
/// can never be passed where an `Identifier<Session>` is expected.
public struct Identifier<Tag>: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var uuidString: String { rawValue.uuidString }
}

extension Identifier: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Identifier: CustomStringConvertible {
    public var description: String { rawValue.uuidString }
}
