import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PDFKit
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import UIKit
@testable import LensFeature

/// Returns what it was told to, so the pipeline after Vision is tested exactly.
struct FakeRecognizer: ImageRecognizing {
    var result: VisualRecognition
    var fails = false

    struct Failure: Error {}

    func recognize(_ image: CGImage) async throws -> VisualRecognition {
        if fails { throw Failure() }
        return result
    }
}

@MainActor
@Suite("Image Lens model")
struct ImageLensModelTests {
    let repositories = Repositories.inMemory()
    let clock = ManualDateProvider(Date(timeIntervalSinceReferenceDate: 9_000))

    var sessions: SessionService {
        SessionService(workspaces: repositories.workspaces, sessions: repositories.sessions, clock: clock, logger: .disabled())
    }

    var capture: CaptureService {
        CaptureService(sessions: repositories.sessions, contextItems: repositories.contextItems, clock: clock, logger: .disabled())
    }

    func model(_ recognition: VisualRecognition, fails: Bool = false) -> ImageLensModel {
        ImageLensModel(recognizer: FakeRecognizer(result: recognition, fails: fails), captureService: capture, sessionService: sessions)
    }

    static func picture(_ text: String = "Total $125", size: CGSize = CGSize(width: 600, height: 200)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            (text as NSString).draw(at: CGPoint(x: 30, y: 60), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 56), .foregroundColor: UIColor.black,
            ])
        }
    }

    static let box = RecognizedLine.Box(x: 0.1, y: 0.4, width: 0.6, height: 0.1)

    @Test func clearPriceOffersActionsButRunsNothing() async throws {
        let model = model(VisualRecognition(lines: [RecognizedLine(text: "$125", confidence: 0.98, box: Self.box)]))
        await model.read(Self.picture(), source: .photoLibrary)

        #expect(model.phase == .done)
        let finding = try #require(model.selected)
        #expect(finding.entityType == .currencyAmount)
        let analysis = try #require(model.analysis(for: finding))
        #expect(analysis.suggestions.primary.map(\.type) == [.convertCurrency, .calculate, .saveToSession])
        // Nothing was saved or performed on its own.
        #expect(model.savedIDs.isEmpty)
    }

    @Test func possibleMatchNeedsConfirmationAndCanBeCorrected() async throws {
        let model = model(VisualRecognition(lines: [RecognizedLine(text: "$1O5", confidence: 0.5, box: Self.box)]))
        await model.read(Self.picture(), source: .camera)

        let money = try #require(model.findings.first { $0.entityType == .currencyAmount })
        #expect(money.certainty == .possible)
        #expect(model.selectedID == nil, "A possible match is never preselected")
        #expect(model.analysis(for: money) == nil)
        await model.save(money)
        #expect(model.savedIDs.isEmpty)

        model.confirm(money, text: "$165")
        #expect(model.isActionable(money))
        #expect(model.content(for: money) == .text("$165"))
        #expect(model.analysis(for: money)?.actions.first?.type == .convertCurrency)
    }

    @Test func savingStoresTheTextNotTheImage() async throws {
        let workspace = try await WorkspaceService(
            workspaces: repositories.workspaces, sessions: repositories.sessions, contextItems: repositories.contextItems,
            documents: repositories.documents, notes: repositories.notes, actionRecords: repositories.actionRecords,
            clock: clock, logger: .disabled()
        ).create(WorkspaceDraft(name: "Trip"))
        let session = try await sessions.start(in: workspace.id)
        let model = model(VisualRecognition(lines: [RecognizedLine(text: "Call 0770 123 4567", confidence: 0.95, box: Self.box)]))
        await model.read(Self.picture(), source: .camera)

        let phone = try #require(model.findings.first { $0.entityType == .phoneNumber })
        await model.save(phone)
        let items = try await capture.items(in: session.id)
        #expect(items.count == 1)
        #expect(items.first?.source == .camera)
        if case .text(let text) = items.first?.content {
            #expect(text.contains("0770"))
        } else {
            Issue.record("Saved content should be text")
        }

        model.clear()
        #expect(model.preview == nil)
        #expect(model.report == nil)
        #expect(model.phase == .idle)
    }

    @Test func failuresAndEmptyImagesAreReported() async {
        let failing = model(VisualRecognition(), fails: true)
        await failing.read(Self.picture(), source: .photoLibrary)
        #expect(failing.phase == .failed)

        let empty = model(VisualRecognition())
        await empty.read(Self.picture(), source: .photoLibrary)
        #expect(empty.phase == .done)
        #expect(empty.findings.isEmpty)

        let broken = model(VisualRecognition())
        await broken.read(data: Data("not an image".utf8), source: .fileImport)
        #expect(broken.phase == .failed)
    }

    @Test func pdfTextLayerIsUsedWithoutOCR() async throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            ("Invoice total $480\nhttps://example.com/pay" as NSString).draw(
                at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 20)]
            )
        }
        let document = try #require(PDFDocument(data: data))
        // The recognizer would fail: proves the text layer was read instead.
        let model = model(VisualRecognition(), fails: true)
        await model.read(pdf: document, source: .fileImport)
        #expect(model.phase == .done)
        let types = Set(model.findings.compactMap(\.entityType))
        #expect(types.contains(.currencyAmount))
        #expect(types.contains(.url))
    }

    @Test func preprocessingScalesDownAndKeepsUpright() throws {
        let large = Self.picture(size: CGSize(width: 4_000, height: 1_000))
        let prepared = try #require(ImagePreprocessor.prepare(large))
        #expect(max(prepared.width, prepared.height) <= Int(ImagePreprocessor.maximumDimension))

        let rotated = UIImage(cgImage: try #require(Self.picture().cgImage), scale: 1, orientation: .right)
        let upright = try #require(ImagePreprocessor.prepare(rotated))
        #expect(upright.height > upright.width, "Rotation is applied before reading")
    }

    // MARK: Apple Vision on the simulator

    @Test func visionReadsPrintedText() async throws {
        let image = try #require(ImagePreprocessor.prepare(Self.picture("Total $125")))
        let recognition = try await VisionImageRecognizer().recognize(image)
        let text = recognition.lines.map(\.text).joined(separator: " ")
        #expect(text.contains("125"), "Vision read: \(text)")
        let report = VisualLensAnalyzer.report(for: recognition)
        #expect(report.findings.contains { $0.entityType == .currencyAmount })
    }

    @Test func visionReadsQRCodes() async throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("https://example.com/menu".utf8)
        let output = try #require(filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)))
        let image = try #require(CIContext().createCGImage(output, from: output.extent))
        let recognition = try await VisionImageRecognizer().recognize(image)
        withKnownIssue("Barcode detection may be unavailable on some simulators", isIntermittent: true) {
            #expect(recognition.codes.first?.payload == "https://example.com/menu")
            #expect(recognition.codes.first?.kind == .qr)
        }
    }
}
