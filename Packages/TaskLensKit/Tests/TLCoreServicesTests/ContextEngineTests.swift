import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

@Suite("Context Engine")
struct ContextEngineTests {
    @Test(arguments: [
        ("Meeting notes for the team", ContentCategory.plainText),
        ("ملاحظات الاجتماع مع الفريق", .plainText),
        ("https://apple.com/iphone", .url),
        ("hello@example.com", .email),
        ("+964 770 123 4567", .phone),
        ("0770 123 4567", .phone),
        ("(415) 555-0132", .phone),
        ("$25.99", .currency),
        ("25 USD", .currency),
        ("١٥٠ ر.س", .currency),
        ("€1,200", .currency),
        ("42", .number),
        ("-3.5", .number),
        ("1,250.75", .number),
        ("١٢٣٫٥", .number),
        ("{\"name\": \"TaskLens\", \"tags\": [1, 2]}", .json),
        ("[1, 2, 3]", .json),
        ("func add(a: Int) -> Int {\n    return a + 1\n}", .code),
        ("let total = items.map { $0.price };\nprint(total)", .code),
        ("   ", .unknown),
        ("12345 !!!", .unknown),
        ("\u{200F}$125\u{00A0}", .currency),
    ])
    func classifiesWholeContent(text: String, expected: ContentCategory) {
        #expect(ContextEngine.analyze(text: text).category == expected, "\(text)")
    }

    @Test func datesAreRecognized() {
        for text in ["2026-10-15", "October 15, 2026 at 3:00 PM", "tomorrow at 5pm"] {
            #expect(ContextEngine.analyze(text: text).category == .date, "\(text)")
        }
        // An ISO date is never a phone number.
        #expect(ContextEngine.analyze(text: "2026-10-15").category != .phone)
    }

    @Test func primaryEntityCarriesTheNormalizedValue() throws {
        let phone = ContextEngine.analyze(text: "+964 770 123 4567")
        #expect(phone.entities.first?.type == .phoneNumber)
        #expect(phone.entities.first?.value == .phoneNumber("+9647701234567"))
        #expect(phone.entities.first?.matchedText == "+964 770 123 4567")

        let price = ContextEngine.analyze(text: "$25.99")
        #expect(price.entities.map(\.type) == [.currencyAmount])
        #expect(price.entities.first?.value == .currency(amount: Decimal(string: "25.99")!, currencyCode: "USD"))

        let arabicPrice = ContextEngine.analyze(text: "١٥٠ ر.س")
        #expect(arabicPrice.entities.first?.value == .currency(amount: 150, currencyCode: "SAR"))

        let number = ContextEngine.analyze(text: "١٢٣٫٥")
        #expect(number.entities.first?.value == .number(Decimal(string: "123.5")!))
    }

    @Test func findsEntitiesInsideSentences() {
        let text = "Call me on +1 415 555 0132 or visit https://example.com, it costs $25"
        let (category, entities) = ContextEngine.analyze(text: text)
        #expect(category == .plainText)
        let types = Set(entities.map(\.type))
        #expect(types.contains(.phoneNumber))
        #expect(types.contains(.url))
        #expect(types.contains(.currencyAmount))
        #expect(entities.allSatisfy { !$0.isPrimary })
        // In text order.
        let locations = entities.compactMap(\.range?.location)
        #expect(locations == locations.sorted())
    }

    @Test func overlappingMatchesKeepTheStrongest() {
        // "$25" is money, not also the number 25; the date is not also 2026.
        #expect(ContextEngine.analyze(text: "$25").entities.map(\.type) == [.currencyAmount])
        #expect(ContextEngine.analyze(text: "2026-10-15").entities.map(\.type) == [.date])
        // JSON is reported alone, not the link inside it.
        let json = ContextEngine.analyze(text: #"{"site": "https://example.com"}"#)
        #expect(json.entities.map(\.type) == [.json])
    }

    @Test func codeKeepsTheEntitiesInsideIt() {
        let code = "let url = \"https://example.com\";\nfunc load() -> Data {\n    return fetch(url)\n}"
        let (category, entities) = ContextEngine.analyze(text: code)
        #expect(category == .code)
        #expect(entities.contains { $0.type == .code && $0.isPrimary })
        #expect(entities.contains { $0.type == .url })
    }

    @Test func linksAreNormalized() {
        let (category, entities) = ContextEngine.analyze(.url(URL(string: "HTTPS://WWW.Apple.com:443/iphone")!))
        #expect(category == .url)
        #expect(entities.first?.value == .url(URL(string: "https://www.apple.com/iphone")!))
        #expect(entities.first?.confidence == .certain)
    }

    @Test func sameInputSameResult() {
        let text = "Lunch with Sara tomorrow at 1pm at 1 Apple Park Way, Cupertino. Call +1 415 555 0132, budget $40"
        let first = ContextEngine.analyze(text: text)
        let second = ContextEngine.analyze(text: text)
        #expect(first.category == second.category)
        #expect(first.entities.map(\.type) == second.entities.map(\.type))
        #expect(first.entities.map(\.value) == second.entities.map(\.value))
    }

    @Test func filesUseTheirKind() {
        let pdf = ContextContent.file(FileReference(relativePath: "a.pdf", contentType: "com.adobe.pdf", kind: .pdf))
        #expect(ContextEngine.analyze(pdf).category == .pdf)
        let image = ContextContent.file(FileReference(relativePath: "a.png", contentType: "public.png", kind: .image))
        #expect(ContextEngine.analyze(image).category == .image)
        let doc = ContextContent.file(FileReference(relativePath: "a.docx", contentType: "org.openxmlformats.wordprocessingml.document", kind: .document))
        #expect(ContextEngine.analyze(doc).category == .document)
    }

    @Test func captureStoresDetectedEntities() async throws {
        let env = TestEnvironment(detector: ContextEngine())
        let item = try await env.capture.capture(.text("hello@example.com"), source: .clipboard)
        #expect(item.entities.map(\.type) == [.email])
    }

    @Test func everyDetectorHasItsOwnType() {
        let types = ContextEngine.detectors.map(\.entityType)
        #expect(Set(types).count == 9)
        #expect(types == [.json, .url, .email, .phoneNumber, .currencyAmount, .number, .date, .address, .code])
    }
}

@Suite("Normalizer")
struct NormalizerTests {
    @Test func whitespace() {
        #expect(Normalizer.whitespace("  a\u{00A0}\u{00A0}b \t c  ") == "a b c")
        #expect(Normalizer.whitespace("one\r\ntwo\rthree") == "one\ntwo\nthree")
        #expect(Normalizer.whitespace("a\n\n\n\nb") == "a\n\nb")
        #expect(Normalizer.whitespace("\u{200F}\u{200B}مرحبا\u{FEFF}") == "مرحبا")
        // Emoji sequences keep their joiners.
        #expect(Normalizer.whitespace("👩‍💻") == "👩‍💻")
    }

    @Test func digits() {
        #expect(Normalizer.digits("٠١٢٣٤٥٦٧٨٩ ۴۵ ١٫٥ ١٬٠٠٠") == "0123456789 45 1.5 1,000")
        #expect(ContextEngine.normalizeDigits("٤٢") == "42")
    }

    @Test func urls() {
        #expect(Normalizer.url("www.Example.com/a") == URL(string: "https://www.example.com/a"))
        #expect(Normalizer.url("HTTP://EXAMPLE.com:80/Path") == URL(string: "http://example.com/Path"))
        #expect(Normalizer.url("https://example.com/a).") == URL(string: "https://example.com/a"))
        #expect(Normalizer.url("https://en.wikipedia.org/wiki/Swift_(language)")
                == URL(string: "https://en.wikipedia.org/wiki/Swift_(language)"))
        #expect(Normalizer.url("https://example.com/#") == URL(string: "https://example.com/"))
        #expect(Normalizer.url("javascript:alert(1)") == nil)
        #expect(Normalizer.url("ftp://example.com") == nil)
        #expect(Normalizer.url("not a link") == nil)
    }

    @Test func phones() {
        #expect(Normalizer.phone("+964 770 123 4567") == "+9647701234567")
        #expect(Normalizer.phone("٠٧٧٠ ١٢٣ ٤٥٦٧") == "07701234567")
        #expect(Normalizer.phone("00964 770 123 4567") == "+9647701234567")
        #expect(Normalizer.phone("(415) 555-0132") == "4155550132")
    }

    @Test func currencies() {
        #expect(Normalizer.currencyCode("$") == "USD")
        #expect(Normalizer.currencyCode("ر.س") == "SAR")
        #expect(Normalizer.currencyCode("eur") == "EUR")
        #expect(Normalizer.currencyCode("دينار") == nil)
        #expect(Normalizer.currencyCode("XYZ") == nil)
    }

    @Test func numbersAndDates() {
        #expect(Normalizer.decimal("1,250.75") == Decimal(string: "1250.75"))
        #expect(Normalizer.decimal("١٢٣٫٥") == Decimal(string: "123.5"))
        #expect(Normalizer.decimal("12,34") == nil)
        #expect(Normalizer.string(Decimal(string: "1250.50")!) == "1250.5")
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        #expect(Normalizer.date(day, includesTime: false) == "2026-10-15")
        #expect(Normalizer.date(Date(timeIntervalSince1970: 0), includesTime: true) == "1970-01-01T00:00:00Z")
    }

    @Test func content() {
        let text = Normalizer.normalize(.text("  ٤٢\u{00A0} "), source: .clipboard)
        #expect(text.text == "42")
        #expect(text.kind == .text)
        #expect(text.source == .clipboard)

        let file = Normalizer.normalize(.file(FileReference(
            relativePath: "files/x.PDF", originalFilename: "Report.PDF", contentType: "com.adobe.pdf", kind: .pdf, byteCount: 10
        )))
        #expect(file.text.isEmpty)
        #expect(file.kind == .file(FileMetadata(filename: "Report.PDF", fileExtension: "pdf", kind: .pdf,
                                                typeIdentifier: "com.adobe.pdf", byteCount: 10)))
    }
}
