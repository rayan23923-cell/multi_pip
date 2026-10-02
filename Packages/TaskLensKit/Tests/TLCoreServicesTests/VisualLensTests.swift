import Foundation
import Testing
import TLCoreServices
import TLDomain

@Suite("Action Lens for images")
struct VisualLensTests {
    typealias Box = RecognizedLine.Box

    func line(_ text: String, _ confidence: Double = 0.95, y: Double, x: Double = 0.1, height: Double = 0.04) -> RecognizedLine {
        RecognizedLine(text: text, confidence: confidence, box: Box(x: x, y: y, width: 0.5, height: height))
    }

    @Test func readingOrderIsTopToBottomThenAlongTheRow() {
        let lines = [
            line("second", y: 0.5),
            line("right", y: 0.8, x: 0.6),
            line("left", y: 0.805, x: 0.1),
        ]
        #expect(OCRNormalizer.readingOrder(lines).map(\.text) == ["left", "right", "second"])

        // Arabic rows read right to left.
        let arabic = [line("مرحبا", y: 0.8, x: 0.1), line("السعر", y: 0.8, x: 0.6)]
        #expect(OCRNormalizer.readingOrder(arabic).map(\.text) == ["السعر", "مرحبا"])
    }

    @Test func numbersAreCorrectedButWordsAreNot() {
        #expect(OCRNormalizer.correctNumbers("Total $1O5") == ("Total $105", true))
        #expect(OCRNormalizer.correctNumbers("Call 0770 l23 4567") == ("Call 0770 123 4567", true))
        #expect(OCRNormalizer.correctNumbers("077O123") == ("0770123", true))
        #expect(OCRNormalizer.correctNumbers("Hello World") == ("Hello World", false))
        #expect(OCRNormalizer.correctNumbers("OIL") == ("OIL", false))
    }

    @Test func screenshotOfAPriceRecommendsMoneyActions() throws {
        let report = VisualLensAnalyzer.report(for: VisualRecognition(lines: [line("$125", y: 0.5)]))
        let money = try #require(report.findings.first)
        #expect(money.entityType == .currencyAmount)
        #expect(money.certainty == .confident)
        #expect(money.text == "$125")
        let actions = ActionEngine.analyze(money.content).suggestions.primary.map(\.type)
        #expect(actions == [.convertCurrency, .calculate, .saveToSession])
    }

    @Test func eachKindOfValueBecomesAFinding() {
        let recognition = VisualRecognition(lines: [
            line("Call 0770 123 4567", y: 0.9),
            line("hello@example.com", y: 0.8),
            line("https://apple.com/store", y: 0.7),
            line("Meeting tomorrow 10 AM", y: 0.6),
            line("Total $199", y: 0.5),
        ])
        let report = VisualLensAnalyzer.report(for: recognition)
        let types = Set(report.findings.compactMap(\.entityType))
        #expect(types.isSuperset(of: [.phoneNumber, .email, .url, .date, .currencyAmount]))
        #expect(report.findings.last?.source == .allText)
        #expect(report.findings.last?.text.contains("Meeting tomorrow") == true)
        // Links come before phones and money.
        let order = report.findings.compactMap(\.entityType)
        #expect(order.firstIndex(of: .url)! < order.firstIndex(of: .currencyAmount)!)
    }

    @Test func blurryTextIsOnlyAPossibleMatch() throws {
        let report = VisualLensAnalyzer.report(for: VisualRecognition(lines: [line("$125", 0.4, y: 0.5)]))
        let money = try #require(report.findings.first { $0.entityType == .currencyAmount })
        #expect(money.certainty == .possible)
        #expect(money.confidence < VisualLensAnalyzer.confidentThreshold)
    }

    @Test func correctedCharactersLowerConfidence() throws {
        let clean = VisualLensAnalyzer.report(for: VisualRecognition(lines: [line("$105", 0.7, y: 0.5)]))
        let fixed = VisualLensAnalyzer.report(for: VisualRecognition(lines: [line("$1O5", 0.7, y: 0.5)]))
        let a = try #require(clean.findings.first { $0.entityType == .currencyAmount })
        let b = try #require(fixed.findings.first { $0.entityType == .currencyAmount })
        #expect(b.text == "$105")
        #expect(b.confidence < a.confidence)
        #expect(b.certainty == .possible)
    }

    @Test func codesComeFirstAndLinksOpen() throws {
        let recognition = VisualRecognition(
            lines: [line("Scan to order", y: 0.2)],
            codes: [
                RecognizedCode(payload: "https://example.com/menu", kind: .qr, symbology: "QR", confidence: 1),
                RecognizedCode(payload: "4006381333931", kind: .barcode, symbology: "EAN13", confidence: 0.3),
            ]
        )
        let report = VisualLensAnalyzer.report(for: recognition)
        let qr = try #require(report.findings.first)
        #expect(qr.entityType == .qrCode)
        #expect(qr.content == .url(URL(string: "https://example.com/menu")!))
        let qrActions = ActionEngine.analyze(qr.content).suggestions.primary.map(\.type)
        #expect(qrActions.first == .openURL)
        #expect(qrActions.contains(.saveToSession))

        let barcode = try #require(report.findings.first { $0.entityType == .barcode })
        #expect(barcode.certainty == .possible)
        #expect(barcode.content == .text("4006381333931"))
    }

    @Test func nonWebCodesAreNeverOpenedAsLinks() throws {
        let report = VisualLensAnalyzer.report(for: VisualRecognition(codes: [
            RecognizedCode(payload: "javascript:alert(1)", kind: .qr, symbology: "QR", confidence: 1),
        ]))
        let code = try #require(report.findings.first)
        #expect(code.content == .text("javascript:alert(1)"))
    }

    @Test func emptyImageHasNoFindings() {
        #expect(VisualLensAnalyzer.report(for: VisualRecognition()).isEmpty)
        #expect(VisualLensAnalyzer.report(for: VisualRecognition(lines: [line("   ", y: 0.5)])).isEmpty)
    }

    @Test func plainTextOffersCopySaveAndTheAIPlaceholder() throws {
        let report = VisualLensAnalyzer.report(for: VisualRecognition(lines: [line("The quick brown fox jumps", y: 0.5)]))
        let all = try #require(report.findings.first { $0.source == .allText })
        let types = ActionEngine.analyze(all.content).actions.map(\.type)
        #expect(types.contains(.copy))
        #expect(types.contains(.saveToSession))
        #expect(types.contains(.askAI))
    }

    @Test func documentStructureFindsTitleAndParagraphs() {
        let lines = [
            line("Invoice", y: 0.88, height: 0.08),
            line("Item one", y: 0.7),
            line("Item two", y: 0.65),
            line("Thank you", y: 0.3),
        ]
        let structure = OCRNormalizer.structure(lines)
        #expect(structure.title == "Invoice")
        #expect(structure.paragraphs == ["Item one Item two", "Thank you"])
    }

    @Test func arabicDigitsAreNormalized() throws {
        let report = VisualLensAnalyzer.report(for: VisualRecognition(lines: [line("٠٧٧٠١٢٣٤٥٦٧", y: 0.5)]))
        let phone = try #require(report.findings.first { $0.entityType == .phoneNumber })
        #expect(phone.text.contains("07701234567"))
    }
}
