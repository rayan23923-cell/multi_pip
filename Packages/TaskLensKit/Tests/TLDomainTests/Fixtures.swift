import Foundation
import TLDomain
import TLFoundation

enum Fixtures {
    static let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
