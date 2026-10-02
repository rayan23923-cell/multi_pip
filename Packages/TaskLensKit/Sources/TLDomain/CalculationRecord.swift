import Foundation
import TLFoundation

public typealias CalculationRecordID = Identifier<CalculationRecord>

/// One finished calculation in the calculator history.
public struct CalculationRecord: Entity {
    public static let entityName = "calculation"

    public let id: CalculationRecordID
    /// The expression as entered, using ASCII digits and the symbols + − × ÷ %.
    public var expression: String
    public var result: Decimal
    public let createdAt: Date

    public init(id: CalculationRecordID = CalculationRecordID(), expression: String, result: Decimal, createdAt: Date) {
        self.id = id
        self.expression = expression
        self.result = result
        self.createdAt = createdAt
    }
}
