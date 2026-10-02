import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

@MainActor
@Observable
public final class CalculatorModel: ContextProducing {
    public let workspaceID: WorkspaceID?
    public private(set) var engine = CalculatorEngine()
    public private(set) var history: [CalculationRecord] = []
    /// The last calculation finished with `=`, while its result is still on screen.
    public private(set) var lastCompletion: CalculatorEngine.Completion?
    public private(set) var savedItem: ContextItem?
    public var errorMessage: String?

    private let calculatorService: CalculatorService
    private let toolCapture: ToolCaptureService

    public init(
        workspaceID: WorkspaceID?,
        calculatorService: CalculatorService,
        toolCapture: ToolCaptureService,
        initialValue: Decimal? = nil
    ) {
        self.workspaceID = workspaceID
        self.calculatorService = calculatorService
        self.toolCapture = toolCapture
        if let initialValue {
            engine = CalculatorEngine(value: initialValue)
        }
    }

    /// Main display text, or nil while showing an error.
    public var display: String? { engine.isError ? nil : engine.display }
    public var expression: String { engine.expression }
    public var result: Decimal? { engine.displayValue }

    public func load() async {
        do {
            history = try await calculatorService.history()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    public func press(_ key: CalculatorEngine.Key) async {
        savedItem = nil
        let completion = engine.press(key)
        if let completion {
            lastCompletion = completion
            do {
                try await calculatorService.record(completion)
                history = try await calculatorService.history()
            } catch {
                errorMessage = L10n.message(for: error)
            }
        } else if key != .equals {
            lastCompletion = nil
        }
    }

    /// Continues from a history result.
    public func use(_ record: CalculationRecord) {
        engine = CalculatorEngine(value: record.result)
        lastCompletion = CalculatorEngine.Completion(expression: record.expression, result: record.result)
        savedItem = nil
    }

    public func clearHistory() async {
        do {
            try await calculatorService.clearHistory()
            history = []
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    /// Plain-text result for copy, share and sending to actions.
    public var resultText: String? {
        result.map(CalculatorEngine.text(for:))
    }

    public var toolOutput: ToolOutput? {
        guard let result else { return nil }
        return CalculatorService.output(for: result, expression: lastCompletion?.expression)
    }

    public func save() async {
        guard let output = toolOutput else { return }
        do {
            savedItem = try await toolCapture.save(output, preferring: workspaceID)
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }
}
