import Foundation
import TLDomain
import TLFoundation

/// Stores calculator history on device.
public struct CalculatorService: Sendable {
    public static let defaultHistoryLimit = 100

    private let records: any Repository<CalculationRecord>
    private let clock: any DateProviding
    private let historyLimit: Int
    private let logger: TLLogger

    public init(
        records: any Repository<CalculationRecord>,
        clock: any DateProviding = SystemDateProvider(),
        historyLimit: Int = CalculatorService.defaultHistoryLimit,
        logger: TLLogger = TLLogger(category: "calculator")
    ) {
        self.records = records
        self.clock = clock
        self.historyLimit = max(historyLimit, 1)
        self.logger = logger
    }

    /// Newest first.
    public func history() async throws -> [CalculationRecord] {
        try await records.fetchAll().sorted { $0.createdAt > $1.createdAt }
    }

    /// Saves a finished calculation and trims history to the limit.
    @discardableResult
    public func record(_ completion: CalculatorEngine.Completion) async throws -> CalculationRecord {
        let record = CalculationRecord(expression: completion.expression, result: completion.result, createdAt: clock.now())
        try await records.upsert(record)
        let all = try await history()
        if all.count > historyLimit {
            try await records.delete(ids: all.dropFirst(historyLimit).map(\.id))
        }
        return record
    }

    public func delete(_ id: CalculationRecordID) async throws {
        try await records.delete(id: id)
    }

    public func clearHistory() async throws {
        try await records.delete(ids: try await records.fetchAll().map(\.id))
        logger.info("Cleared calculator history")
    }

    /// The result as a context item payload, ready to save or send to actions.
    public static func output(for result: Decimal, expression: String?) -> ToolOutput {
        var metadata: Metadata = ["result": .string(CalculatorEngine.text(for: result))]
        if let expression, !expression.isEmpty { metadata["expression"] = .string(expression) }
        return ToolOutput(
            tool: .calculator,
            source: .calculator,
            content: .text(CalculatorEngine.text(for: result)),
            metadata: metadata
        )
    }
}
