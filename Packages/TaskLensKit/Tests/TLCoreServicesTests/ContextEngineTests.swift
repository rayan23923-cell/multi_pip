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

    @Test func primaryEntityCarriesTheValue() throws {
        let phone = ContextEngine.analyze(text: "+964 770 123 4567")
        #expect(phone.entities.first?.type == .phoneNumber)
        #expect(phone.entities.first?.value == .phoneNumber("+964 770 123 4567"))

        let price = ContextEngine.analyze(text: "$25.99")
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
        #expect(entities.allSatisfy { $0.metadata[ContextAnalysis.primaryKey] == nil })
    }

    @Test func filesUseTheirKind() {
        let pdf = ContextContent.file(FileReference(relativePath: "a.pdf", contentType: "com.adobe.pdf", kind: .pdf))
        #expect(ContextEngine.analyze(pdf).category == .pdf)
        let image = ContextContent.file(FileReference(relativePath: "a.png", contentType: "public.png", kind: .image))
        #expect(ContextEngine.analyze(image).category == .image)
    }

    @Test func captureStoresDetectedEntities() async throws {
        let env = TestEnvironment(detector: ContextEngine())
        let item = try await env.capture.capture(.text("hello@example.com"), source: .clipboard)
        #expect(item.entities.map(\.type) == [.email])
    }

    @Test func normalizesArabicDigits() {
        #expect(ContextEngine.normalizeDigits("٠١٢٣٤٥٦٧٨٩ ۴۵ ١٫٥ ١٬٠٠٠") == "0123456789 45 1.5 1,000")
    }
}

@Suite("Rule Action Engine")
struct RuleActionEngineTests {
    private func types(_ text: String) -> [ActionType] {
        RuleActionEngine.analyze(.text(text)).actions.map(\.type)
    }

    @Test func phoneOffersCallMessageSave() {
        let actions = RuleActionEngine.analyze(.text("+964 770 123 4567")).actions
        #expect(Array(actions.map(\.type).prefix(3)) == [.call, .sendMessage, .saveToSession])
        #expect(actions.first?.valueText == "+964 770 123 4567")
        #expect(actions.first?.requiresConfirmation == true)
    }

    @Test func urlOffersOpenSaveShare() {
        #expect(Array(types("https://example.com").prefix(3)) == [.openURL, .saveToSession, .share])
    }

    @Test func currencyOffersConvertCalculateSave() {
        let actions = RuleActionEngine.analyze(.text("$25")).actions
        #expect(Array(actions.map(\.type).prefix(3)) == [.convertCurrency, .calculate, .saveToSession])
        #expect(actions.first?.isPlaceholder == true)
        #expect(actions.first?.parameters[Action.ParameterKey.currencyCode] == .string("USD"))
        #expect(actions[1].valueText == "25")
    }

    @Test func textOffersTranslateSummarizeSaveCopy() {
        let actions = RuleActionEngine.analyze(.text("Meeting notes for the team")).actions
        let byType = Dictionary(uniqueKeysWithValues: actions.map { ($0.type, $0) })
        for type: ActionType in [.translate, .summarize, .saveToSession, .copy] {
            #expect(byType[type] != nil, "missing \(type.rawValue)")
        }
        #expect(byType[.summarize]?.isPlaceholder == true)
        #expect(byType[.translate]?.isPlaceholder == false)
    }

    @Test func dateOffersReminderAndCalendarPlaceholders() {
        let actions = RuleActionEngine.analyze(.text("2026-10-15")).actions
        #expect(Array(actions.map(\.type).prefix(3)) == [.createReminder, .addToCalendar, .saveToSession])
        #expect(actions.prefix(2).allSatisfy { $0.isPlaceholder })
    }

    @Test func everyCategoryCanBeSaved() {
        for text in ["x y z", "42", "a@b.co", "{\"a\":1}", "   "] {
            #expect(types(text).contains(.saveToSession), "\(text)")
        }
        let pdf = ContextContent.file(FileReference(relativePath: "a.pdf", contentType: "com.adobe.pdf", kind: .pdf))
        #expect(RuleActionEngine.analyze(pdf).actions.first?.type == .saveToSession)
    }

    @Test func suggestsForStoredItems() async throws {
        let env = TestEnvironment()
        let item = try await env.capture.capture(.text("42"), source: .manualEntry)
        let actions = await RuleActionEngine().suggestActions(for: item)
        #expect(actions.first?.type == .calculate)
        #expect(actions.allSatisfy { $0.targetItemID == item.id })
    }
}
