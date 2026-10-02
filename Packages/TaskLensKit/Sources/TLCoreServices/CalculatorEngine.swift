import Foundation

/// A basic calculator with operator precedence and iOS-style percentages.
///
/// The engine is a value type with no UI or persistence, so every behavior
/// is unit tested. Numbers are `Decimal`, so 0.1 + 0.2 is exactly 0.3.
/// Text uses ASCII digits and `.` as the decimal separator; the UI formats it.
public struct CalculatorEngine: Sendable, Equatable {
    public enum Operator: String, Sendable, CaseIterable {
        case add = "+"
        case subtract = "−"
        case multiply = "×"
        case divide = "÷"

        var precedence: Int {
            switch self {
            case .add, .subtract: 1
            case .multiply, .divide: 2
            }
        }
    }

    public enum Key: Sendable, Hashable {
        case digit(Int)
        case decimalPoint
        case op(Operator)
        case equals
        case percent
        case toggleSign
        case clear
        case backspace
    }

    /// A calculation completed with `=`.
    public struct Completion: Sendable, Equatable {
        public let expression: String
        public let result: Decimal

        public init(expression: String, result: Decimal) {
            self.expression = expression
            self.result = result
        }
    }

    public static let maximumDigits = 16
    /// Fraction digits kept after division and percentages.
    public static let resultScale = 10

    fileprivate enum Token: Sendable, Equatable {
        case number(Decimal, text: String)
        case op(Operator)
    }

    private var tokens: [Token] = []
    /// Number being typed, as text (e.g. "12.", "-0.5"). `nil` when no entry is in progress.
    private var entry: String?
    /// Display text of the entry when it was turned into a percentage.
    private var entryLabel: String?
    private var lastResult: Decimal?

    public private(set) var isError = false

    public init() {}

    /// Starts from a value, e.g. a result picked from history.
    public init(value: Decimal) {
        lastResult = Self.rounded(value)
    }

    // MARK: Output

    /// What the main display shows: the current entry, else the last result, else 0.
    public var display: String {
        if isError { return "" }
        if let entry { return entry }
        if let lastResult, tokens.isEmpty { return Self.text(for: lastResult) }
        if case .number(_, let text)? = tokens.last { return text }
        if let value = try? Self.evaluate(tokens.dropLastOperator()) { return Self.text(for: value) }
        return "0"
    }

    /// The expression typed so far, e.g. "12 + 3 ×".
    public var expression: String {
        var parts = tokens.map { token -> String in
            switch token {
            case .number(_, let text): text
            case .op(let op): op.rawValue
            }
        }
        if let entry { parts.append(entryLabel ?? entry) }
        return parts.joined(separator: " ")
    }

    /// Current value shown, as a number (for copy and send).
    public var displayValue: Decimal? {
        if isError { return nil }
        return Decimal(string: display, locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: Input

    @discardableResult
    public mutating func press(_ key: Key) -> Completion? {
        if isError, key != .clear {
            reset()
        }
        switch key {
        case .digit(let digit): appendDigit(digit)
        case .decimalPoint: appendDecimalPoint()
        case .op(let op): applyOperator(op)
        case .equals: return evaluateAll()
        case .percent: applyPercent()
        case .toggleSign: toggleSign()
        case .clear: reset()
        case .backspace: deleteLast()
        }
        return nil
    }

    @discardableResult
    public mutating func press(_ keys: [Key]) -> Completion? {
        var completion: Completion?
        for key in keys { completion = press(key) ?? completion }
        return completion
    }

    private mutating func reset() {
        tokens = []
        entry = nil
        entryLabel = nil
        lastResult = nil
        isError = false
    }

    private mutating func appendDigit(_ digit: Int) {
        guard (0...9).contains(digit) else { return }
        if entry == nil, tokens.isEmpty { lastResult = nil }
        var text = entry ?? "0"
        if entryLabel != nil { text = "0"; entryLabel = nil }
        guard Self.digitCount(text) < Self.maximumDigits else { return }
        if text == "0" { text = "\(digit)" } else if text == "-0" { text = "-\(digit)" } else { text += "\(digit)" }
        entry = text
    }

    private mutating func appendDecimalPoint() {
        if entry == nil, tokens.isEmpty { lastResult = nil }
        var text = entry ?? "0"
        if entryLabel != nil { text = "0"; entryLabel = nil }
        guard !text.contains(".") else { return }
        text += "."
        entry = text
    }

    private mutating func applyOperator(_ op: Operator) {
        if let value = commitEntry() {
            tokens.append(value)
        } else if case .op? = tokens.last {
            tokens.removeLast()
        } else if tokens.isEmpty {
            tokens.append(.number(lastResult ?? 0, text: Self.text(for: lastResult ?? 0)))
        }
        tokens.append(.op(op))
        lastResult = nil
    }

    private mutating func evaluateAll() -> Completion? {
        if let value = commitEntry() {
            tokens.append(value)
        }
        let terms = tokens.dropLastOperator()
        guard !terms.isEmpty, terms.contains(where: { if case .op = $0 { true } else { false } }) else {
            // Nothing to calculate (a lone number or empty input).
            if case .number(let value, _)? = terms.first { lastResult = value }
            tokens = []
            return nil
        }
        let expression = terms.map { token -> String in
            switch token {
            case .number(_, let text): text
            case .op(let op): op.rawValue
            }
        }.joined(separator: " ")
        do {
            let result = try Self.evaluate(terms)
            tokens = []
            lastResult = result
            return Completion(expression: expression, result: result)
        } catch {
            tokens = []
            lastResult = nil
            isError = true
            return nil
        }
    }

    /// 50 + 10% → 50 + 5 (a share of the left side); 10% alone or after × ÷ → 0.1.
    private mutating func applyPercent() {
        let current: Decimal
        if let entry, let value = Self.number(entry) {
            current = value
        } else if tokens.isEmpty, let lastResult {
            current = lastResult
        } else {
            return
        }
        var value = current / 100
        if case .op(let op)? = tokens.last, op == .add || op == .subtract,
           let base = try? Self.evaluate(Array(tokens.dropLast())) {
            value = base * current / 100
        }
        value = Self.rounded(value)
        entryLabel = Self.text(for: current) + "%"
        entry = Self.text(for: value)
        lastResult = nil
    }

    private mutating func toggleSign() {
        if entry == nil, tokens.isEmpty, let lastResult {
            entry = Self.text(for: lastResult)
            self.lastResult = nil
        }
        guard var text = entry else { return }
        if text.hasPrefix("-") { text.removeFirst() } else { text = "-" + text }
        entry = text
        entryLabel = nil
    }

    private mutating func deleteLast() {
        guard var text = entry, entryLabel == nil else {
            entry = nil
            entryLabel = nil
            return
        }
        text.removeLast()
        if text.isEmpty || text == "-" { entry = "0" } else { entry = text }
    }

    private mutating func commitEntry() -> Token? {
        guard let entry, let value = Self.number(entry) else { return nil }
        let label = entryLabel ?? Self.text(for: value)
        self.entry = nil
        entryLabel = nil
        return .number(value, text: label)
    }

    // MARK: Evaluation

    private struct DivisionByZero: Error {}

    private static func evaluate(_ tokens: [Token]) throws -> Decimal {
        var values: [Decimal] = []
        var operators: [Operator] = []

        func reduce() throws {
            let op = operators.removeLast()
            let rhs = values.removeLast()
            let lhs = values.removeLast()
            switch op {
            case .add: values.append(lhs + rhs)
            case .subtract: values.append(lhs - rhs)
            case .multiply: values.append(lhs * rhs)
            case .divide:
                guard rhs != 0 else { throw DivisionByZero() }
                values.append(lhs / rhs)
            }
        }

        for token in tokens {
            switch token {
            case .number(let value, _):
                values.append(value)
            case .op(let op):
                while let top = operators.last, top.precedence >= op.precedence { try reduce() }
                operators.append(op)
            }
        }
        while !operators.isEmpty, values.count >= 2 { try reduce() }
        return rounded(values.last ?? 0)
    }

    // MARK: Number text

    private static let posix = Locale(identifier: "en_US_POSIX")

    static func number(_ text: String) -> Decimal? {
        var text = text
        if text.hasSuffix(".") { text.removeLast() }
        return Decimal(string: text, locale: posix)
    }

    /// Evaluates typed text such as "12*3+4" or "١٢ × ٣" with the same rules as
    /// the keypad. Nil for anything that is not a plain calculation.
    public static func evaluate(_ text: String) -> Completion? {
        var engine = CalculatorEngine()
        var keys: [Key] = []
        for character in text where !character.isWhitespace {
            if let digit = character.wholeNumberValue, (0...9).contains(digit) {
                keys.append(.digit(digit))
                continue
            }
            switch character {
            case ".", ",", "٫": keys.append(.decimalPoint)
            case "+": keys.append(.op(.add))
            case "-", "−", "–": keys.append(.op(.subtract))
            case "*", "×", "x", "X": keys.append(.op(.multiply))
            case "/", "÷": keys.append(.op(.divide))
            case "%", "٪": keys.append(.percent)
            case "=": continue
            default: return nil
            }
        }
        guard keys.contains(where: { if case .digit = $0 { true } else { false } }) else { return nil }
        if case .op(.subtract) = keys.first {
            // A leading minus negates the first number.
            keys.removeFirst()
            if let index = keys.firstIndex(where: { if case .digit = $0 { false } else if case .decimalPoint = $0 { false } else { true } }) {
                keys.insert(.toggleSign, at: index)
            } else {
                keys.append(.toggleSign)
            }
        }
        _ = engine.press(keys)
        guard let completion = engine.press(.equals), !engine.isError else { return nil }
        return completion
    }

    public static func text(for value: Decimal) -> String {
        var value = value
        if value.isZero { value = 0 } // normalizes -0
        return NSDecimalNumber(decimal: value).description(withLocale: posix)
    }

    static func rounded(_ value: Decimal) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, resultScale, .plain)
        return output
    }

    private static func digitCount(_ text: String) -> Int {
        text.filter(\.isNumber).count
    }
}

private extension Array where Element == CalculatorEngine.Token {
    func dropLastOperator() -> [Element] {
        if case .op? = last { return Array(dropLast()) }
        return self
    }
}
