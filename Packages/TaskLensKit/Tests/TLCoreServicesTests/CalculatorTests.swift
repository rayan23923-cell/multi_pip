import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

@Suite("Calculator engine")
struct CalculatorEngineTests {
    private func run(_ keys: String) -> (CalculatorEngine, CalculatorEngine.Completion?) {
        var engine = CalculatorEngine()
        var completion: CalculatorEngine.Completion?
        for character in keys where character != " " {
            let key: CalculatorEngine.Key
            switch character {
            case "0"..."9": key = .digit(Int(String(character))!)
            case ".": key = .decimalPoint
            case "+": key = .op(.add)
            case "-": key = .op(.subtract)
            case "*": key = .op(.multiply)
            case "/": key = .op(.divide)
            case "%": key = .percent
            case "=": key = .equals
            case "n": key = .toggleSign
            case "C": key = .clear
            case "<": key = .backspace
            default: fatalError("unknown key \(character)")
            }
            completion = engine.press(key) ?? completion
        }
        return (engine, completion)
    }

    @Test(arguments: [
        ("12+30=", "42"),
        ("7-10=", "-3"),
        ("6*7=", "42"),
        ("1/4=", "0.25"),
        ("2+3*4=", "14"),
        ("10-4/2=", "8"),
        ("0.1+0.2=", "0.3"),
        ("1/3=", "0.3333333333"),
        ("5n*2=", "-10"),
    ])
    func basicArithmetic(keys: String, expected: String) {
        let (engine, completion) = run(keys)
        #expect(engine.display == expected)
        #expect(completion.map { CalculatorEngine.text(for: $0.result) } == expected)
    }

    @Test func percentages() {
        #expect(run("50+10%=").0.display == "55")
        #expect(run("200-25%=").0.display == "150")
        #expect(run("80*50%=").0.display == "40")
        #expect(run("15%").0.display == "0.15")
    }

    @Test func expressionShowsWhatWasTyped() {
        let (engine, completion) = run("50+10%=")
        #expect(completion?.expression == "50 + 10%")
        #expect(engine.expression.isEmpty)
        #expect(run("12+3*").0.expression == "12 + 3 ×")
    }

    @Test func divisionByZeroIsAnErrorUntilNextKey() {
        var (engine, completion) = run("8/0=")
        #expect(engine.isError)
        #expect(completion == nil)
        #expect(engine.displayValue == nil)
        engine.press(.digit(3))
        #expect(!engine.isError)
        #expect(engine.display == "3")
    }

    @Test func editingKeys() {
        #expect(run("123<").0.display == "12")
        #expect(run("1..5").0.display == "1.5")
        #expect(run("12+3C").0.display == "0")
        #expect(run("12+3C").0.expression.isEmpty)
        #expect(run("9<<").0.display == "0")
    }

    @Test func continuesFromResultOrStartsFresh() {
        #expect(run("2+3=*4=").0.display == "20")
        #expect(run("2+3=7").0.display == "7")
        #expect(run("2+*3=").0.display == "6") // operator replaced
    }

    @Test func limitsDigits() {
        let (engine, _) = run(String(repeating: "9", count: 20))
        #expect(engine.display.count == CalculatorEngine.maximumDigits)
    }
}

@Suite("Calculator service")
struct CalculatorServiceTests {
    @Test func recordsNewestFirstAndTrims() async throws {
        let env = TestEnvironment()
        let service = env.calculator(historyLimit: 2)
        for (index, value) in [1, 2, 3].enumerated() {
            env.clock.advance(by: Double(index + 1))
            try await service.record(.init(expression: "\(value) + 0", result: Decimal(value)))
        }
        let history = try await service.history()
        #expect(history.map(\.result) == [3, 2])

        try await service.clearHistory()
        #expect(try await service.history().isEmpty)
    }

    @Test func outputIsATextContextItem() async throws {
        let env = TestEnvironment()
        let output = CalculatorService.output(for: Decimal(string: "12.5")!, expression: "10 + 2.5")
        let item = try await env.capture.capture(output)
        #expect(item.content == .text("12.5"))
        #expect(item.source == .calculator)
        #expect(item.metadata["tool"] == .string("calculator"))
        #expect(item.metadata["expression"] == .string("10 + 2.5"))
    }
}
