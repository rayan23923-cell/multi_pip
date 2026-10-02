import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

/// Runs one detector on text, as the engine does after normalizing.
private func detect(_ detector: some ContentDetector, _ text: String) -> [DetectedEntity] {
    detector.detect(in: Normalizer.normalize(.text(text)))
}

private func string(_ entity: DetectedEntity?, _ key: String) -> String? {
    entity?.metadata[key]?.stringValue
}

@Suite("URL detector")
struct URLDetectorTests {
    @Test func wholeLink() throws {
        let entity = try #require(detect(URLDetector(), "https://Example.com/docs").first)
        #expect(entity.type == .url)
        #expect(entity.value == .url(URL(string: "https://example.com/docs")!))
        #expect(entity.isPrimary)
        #expect(entity.confidence == .high)
        #expect(string(entity, DetectionKey.host) == "example.com")
        #expect(string(entity, DetectionKey.scheme) == "https")
    }

    @Test func linksInText() {
        let found = detect(URLDetector(), "Docs at www.example.com/guide. Or see example.org today")
        #expect(found.map(\.value) == [.url(URL(string: "https://www.example.com/guide")!), .url(URL(string: "http://example.org")!)])
        #expect(found.map(\.confidence) == [.high, .medium])
        #expect(found.allSatisfy { !$0.isPrimary })
    }

    @Test func linkContentIsCertain() {
        let found = URLDetector().detect(in: Normalizer.normalize(.url(URL(string: "https://example.com")!)))
        #expect(found.count == 1)
        #expect(found.first?.confidence == .certain)
        #expect(found.first?.isPrimary == true)
    }

    @Test func emailsAreNotLinks() {
        #expect(detect(URLDetector(), "hello@example.com").isEmpty)
        #expect(detect(URLDetector(), "no links here").isEmpty)
    }
}

@Suite("Phone detector")
struct PhoneDetectorTests {
    @Test(arguments: [
        ("+964 770 123 4567", "+9647701234567", true),
        ("٠٧٧٠ ١٢٣ ٤٥٦٧", "07701234567", false),
        ("(415) 555-0132", "4155550132", false),
        ("00964 770 123 4567", "+9647701234567", true),
    ])
    func wholeNumbers(text: String, dialable: String, international: Bool) throws {
        let entity = try #require(detect(PhoneDetector(), text).first)
        #expect(entity.value == .phoneNumber(dialable))
        #expect(entity.isPrimary)
        #expect(entity.confidence == .high)
        #expect(entity.metadata[DetectionKey.international] == .bool(international))
    }

    @Test func shortLocalNumbersAreLessCertain() throws {
        let entity = try #require(detect(PhoneDetector(), "555-0132").first)
        #expect(entity.confidence == .medium)
    }

    @Test func numberInsideText() throws {
        let entity = try #require(detect(PhoneDetector(), "Call me on +1 415 555 0132 tomorrow").first)
        #expect(entity.value == .phoneNumber("+14155550132"))
        #expect(!entity.isPrimary)
    }

    @Test(arguments: ["2026-10-15", "1,250.75", "12345", "3.14159265", "hello"])
    func notPhoneNumbers(text: String) {
        #expect(detect(PhoneDetector(), text).isEmpty, "\(text)")
    }
}

@Suite("Email detector")
struct EmailDetectorTests {
    @Test func wholeAddressIsLowercased() throws {
        let entity = try #require(detect(EmailDetector(), "Hello@Example.com").first)
        #expect(entity.value == .email("hello@example.com"))
        #expect(entity.isPrimary)
        #expect(string(entity, DetectionKey.domain) == "example.com")
    }

    @Test func mailtoAndSentences() {
        #expect(detect(EmailDetector(), "mailto:team@tasklens.app").first?.value == .email("team@tasklens.app"))
        let found = detect(EmailDetector(), "Write to a.b@mail.co or c+d@x.org.")
        #expect(found.map(\.value) == [.email("a.b@mail.co"), .email("c+d@x.org")])
        #expect(found.allSatisfy { !$0.isPrimary })
    }

    @Test(arguments: ["user@localhost", "@handle", "name@", "plain text"])
    func notEmails(text: String) {
        #expect(detect(EmailDetector(), text).isEmpty, "\(text)")
    }
}

@Suite("Currency detector")
struct CurrencyDetectorTests {
    @Test(arguments: [
        ("$125", "125", "USD"),
        ("125 €", "125", "EUR"),
        ("IQD 25,000", "25000", "IQD"),
        ("١٥٠ ر.س", "150", "SAR"),
        ("£9.99", "9.99", "GBP"),
    ])
    func amounts(text: String, amount: String, code: String) throws {
        let entity = try #require(detect(CurrencyDetector(), text).first)
        #expect(entity.value == .currency(amount: Decimal(string: amount)!, currencyCode: code))
        #expect(entity.isPrimary)
        #expect(entity.confidence == .high)
        #expect(string(entity, DetectionKey.currencyCode) == code)
        #expect(string(entity, DetectionKey.normalized) == amount)
    }

    @Test func ambiguousUnitIsLessCertain() throws {
        let entity = try #require(detect(CurrencyDetector(), "٢٥٠٠٠ دينار").first)
        #expect(entity.value == .currency(amount: 25000, currencyCode: nil))
        #expect(entity.confidence == .medium)
    }

    @Test func priceInsideText() throws {
        let entity = try #require(detect(CurrencyDetector(), "The plan costs $40 a month").first)
        #expect(entity.matchedText == "$40")
        #expect(!entity.isPrimary)
    }

    @Test(arguments: ["125", "USD", "the dollar fell"])
    func notAmounts(text: String) {
        #expect(detect(CurrencyDetector(), text).isEmpty, "\(text)")
    }
}

@Suite("Number detector")
struct NumberDetectorTests {
    @Test(arguments: [("42", "42", true), ("-3.5", "-3.5", false), ("1,250.75", "1250.75", false), ("١٢٣٫٥", "123.5", false)])
    func wholeNumbers(text: String, value: String, isInteger: Bool) throws {
        let entity = try #require(detect(NumberDetector(), text).first)
        #expect(entity.value == .number(Decimal(string: value)!))
        #expect(entity.isPrimary)
        #expect(entity.confidence == .high)
        #expect(entity.metadata[DetectionKey.isInteger] == .bool(isInteger))
    }

    @Test func numbersInSentencesAreWeak() {
        let found = detect(NumberDetector(), "We need 3 chairs and 12 cups")
        #expect(found.map(\.value) == [.number(3), .number(12)])
        #expect(found.allSatisfy { $0.confidence == .low && !$0.isPrimary })
    }

    @Test(arguments: ["v1.2.3", "ABC123", "12,34", "hello"])
    func notNumbers(text: String) {
        #expect(detect(NumberDetector(), text).isEmpty, "\(text)")
    }
}

@Suite("Date detector")
struct DateDetectorTests {
    @Test func allDayDate() throws {
        let entity = try #require(detect(DateDetector(), "2026-10-15").first)
        #expect(entity.isPrimary)
        #expect(entity.confidence == .high)
        #expect(entity.metadata[DetectionKey.includesTime] == .bool(false))
        #expect(string(entity, DetectionKey.normalized) == "2026-10-15")
    }

    @Test func dateWithTime() throws {
        let entity = try #require(detect(DateDetector(), "October 15, 2026 at 3:00 PM").first)
        #expect(entity.isPrimary)
        #expect(entity.metadata[DetectionKey.includesTime] == .bool(true))
        guard case .date(let date) = entity.value else {
            Issue.record("Expected a date value")
            return
        }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 15 && parts.hour == 15)
    }

    @Test func relativeDateIsLessCertain() throws {
        let entity = try #require(detect(DateDetector(), "tomorrow at 5pm").first)
        #expect(entity.confidence == .medium)
        #expect(entity.metadata[DetectionKey.includesTime] == .bool(true))
    }

    @Test func dateInsideText() throws {
        let entity = try #require(detect(DateDetector(), "The dentist appointment is on October 20, 2026, please remember").first)
        #expect(!entity.isPrimary)
    }

    @Test func noDate() {
        #expect(detect(DateDetector(), "Nothing scheduled here").isEmpty)
    }
}

@Suite("Address detector")
struct AddressDetectorTests {
    @Test func wholeAddress() throws {
        let entity = try #require(detect(AddressDetector(), "1 Apple Park Way, Cupertino, CA 95014").first)
        #expect(entity.type == .address)
        #expect(entity.isPrimary)
        #expect(entity.confidence == .high)
        guard case .address(let parts) = entity.value else {
            Issue.record("Expected address parts")
            return
        }
        #expect(parts.values.contains { $0.contains("Cupertino") })
    }

    @Test func addressInsideText() throws {
        let text = "Meet me at 1 Apple Park Way, Cupertino, CA 95014 after lunch tomorrow, and bring the printed slides"
        let entity = try #require(detect(AddressDetector(), text).first)
        #expect(!entity.isPrimary)
    }

    @Test func noAddress() {
        #expect(detect(AddressDetector(), "Just some words").isEmpty)
    }
}

@Suite("JSON detector")
struct JSONDetectorTests {
    @Test func object() throws {
        let entity = try #require(detect(JSONDetector(), #"{"b": 1, "a": [1, 2]}"#).first)
        #expect(entity.isPrimary)
        #expect(entity.confidence == .certain)
        #expect(string(entity, DetectionKey.structure) == "object")
        #expect(entity.metadata[DetectionKey.count] == .number(2))
        guard case .text(let pretty) = entity.value else {
            Issue.record("Expected pretty JSON")
            return
        }
        // Pretty-printed with sorted keys.
        let a = try #require(pretty.range(of: "\"a\"")), b = try #require(pretty.range(of: "\"b\""))
        #expect(a.lowerBound < b.lowerBound)
        #expect(pretty.contains("\n"))
    }

    @Test func array() throws {
        let entity = try #require(detect(JSONDetector(), "[1, 2, 3]").first)
        #expect(string(entity, DetectionKey.structure) == "array")
        #expect(entity.metadata[DetectionKey.count] == .number(3))
    }

    @Test(arguments: ["{not json}", "\"just a string\"", "42", "[1, 2", "hello {\"a\":1}"])
    func notJSON(text: String) {
        #expect(detect(JSONDetector(), text).isEmpty, "\(text)")
    }
}

@Suite("Code detector")
struct CodeDetectorTests {
    @Test func swift() throws {
        let entity = try #require(detect(CodeDetector(), "func add(a: Int) -> Int {\n    return a + 1\n}").first)
        #expect(entity.isPrimary)
        #expect(string(entity, DetectionKey.language) == "swift")
        #expect(entity.confidence >= .medium)
    }

    @Test func python() throws {
        let entity = try #require(detect(CodeDetector(), "def total(items):\n    return sum(items) == 0\n").first)
        #expect(string(entity, DetectionKey.language) == "python")
    }

    @Test func moreSignalsMoreConfidence() throws {
        let weak = try #require(detect(CodeDetector(), "x == y;").first)
        let strong = try #require(detect(CodeDetector(), "func f() -> Int {\n    return g(x) == 1;\n}").first)
        #expect(strong.confidence > weak.confidence)
    }

    @Test(arguments: ["Hello (world).", "Meet at 5 => maybe", "Just a sentence."])
    func prose(text: String) {
        #expect(detect(CodeDetector(), text).isEmpty, "\(text)")
    }
}
