import Foundation
import PresentationFeature
import Testing
import TLCoreServices
import TLDomain
import TLFoundation
import TLLocalization
import TLNavigation
import UIKit

/// A stored package TaskLens accepts as a .pptx; its slides come from `ScriptedSlides`.
private func powerPointPackage() -> Data {
    func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
    func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
    var body = Data(), directory = Data()
    let names = ["[Content_Types].xml", "_rels/.rels", "ppt/presentation.xml", "ppt/slides/slide1.xml"]
    for name in names {
        let nameData = Data(name.utf8), content = Data("<x/>".utf8), offset = body.count
        for part in [le32(0x0403_4B50), le16(20), le16(0), le16(0), le16(0), le16(0), le32(0),
                     le32(content.count), le32(content.count), le16(nameData.count), le16(0), nameData, content] { body += part }
        for part in [le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(0), le16(0), le16(0), le32(0),
                     le32(content.count), le32(content.count), le16(nameData.count), le16(0), le16(0),
                     le16(0), le16(0), le32(0), le32(offset), nameData] { directory += part }
    }
    var end = Data()
    for part in [le32(0x0605_4B50), le16(0), le16(0), le16(names.count), le16(names.count),
                 le32(directory.count), le32(body.count), le16(0)] { end += part }
    return body + directory + end
}

/// Slide images that fail, then succeed, in the order given: a stand-in for
/// the cache and renderer, throwing the same `PowerPointFailure` they throw.
private final class ScriptedSlides: PowerPointSlideImageProviding, @unchecked Sendable {
    enum Step { case fail(PowerPointFailure), slides(Int) }

    private let documents: DocumentService
    private let lock = NSLock()
    private var steps: [Step]
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(documents: DocumentService, _ steps: [Step]) {
        self.documents = documents
        self.steps = steps
    }

    func slideImage(for documentID: DocumentID, index: Int) -> URL {
        documents.generatedFilesDirectory(for: documentID).appendingPathComponent(String(format: "Slides/slide-%03d.png", index + 1))
    }

    func slideImages(for document: Document, fileURL: URL) async throws -> [URL] {
        let step: Step = lock.withLock {
            _calls += 1
            return steps.count > 1 ? steps.removeFirst() : steps[0]
        }
        switch step {
        case .fail(let failure):
            throw failure
        case .slides(let count):
            let urls = (0..<count).map { slideImage(for: document.id, index: $0) }
            try FileManager.default.createDirectory(at: urls[0].deletingLastPathComponent(), withIntermediateDirectories: true)
            for url in urls {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                try UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90), format: format).pngData { context in
                    UIColor.systemTeal.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
                }.write(to: url)
            }
            return urls
        }
    }
}

/// A9.5.2: what the PowerPoint failure screen says and offers for each A9.5.1
/// category. Plain values, so off the main actor the model tests share.
@Suite("PowerPoint failure content")
struct PowerPointFailureContentTests {
    // MARK: Category → screen

    @Test func everyCategoryHasItsScreen() throws {
        typealias A = PowerPointFailureContent.Action
        let expected: [(PowerPointFailure, L10nKey, L10nKey, [A])] = [
            (.speakerNotesUnsupported, .presentationPptxNotesTitle, .presentationPptxNotesMessage, [.importPDF, .cancel]),
            (.unsupportedPresentation, .presentationPptxUnsupportedTitle, .presentationPptxUnsupportedMessage, [.importPDF, .cancel]),
            (.renderingFailed, .presentationPptxFailedTitle, .presentationPptxFailedMessage, [.retry, .importPDF, .cancel]),
            (.invalidSource, .presentationPptxInvalidTitle, .presentationPptxInvalidMessage, [.retry, .cancel]),
            (.corruptedCache, .presentationPptxFailedTitle, .presentationPptxFailedMessage, [.retry, .importPDF, .cancel]),
            (.missingResource, .presentationPptxFailedTitle, .presentationPptxMissingMessage, [.retry, .cancel]),
            (.timeout, .presentationPptxTimeoutTitle, .presentationPptxTimeoutMessage, [.retry, .importPDF, .cancel]),
            (.securityRejected, .presentationPptxSecurityTitle, .presentationPptxSecurityMessage, [.cancel]),
            (.storageFailure, .presentationPptxStorageTitle, .presentationPptxStorageMessage, [.retry, .cancel]),
            (.unknown, .presentationPptxFailedTitle, .presentationPptxFailedMessage, [.retry, .importPDF, .cancel]),
        ]
        #expect(expected.count == PowerPointFailure.allCases.count - 1, "Every category but cancelled")
        for (failure, title, message, actions) in expected {
            let content = try #require(PowerPointFailureContent(failure), "\(failure)")
            #expect(content.title == title, "\(failure)")
            #expect(content.message == message, "\(failure)")
            #expect(content.actions == actions, "\(failure)")
            #expect(content.actions.last == .cancel, "\(failure): Cancel is always there, last")
        }
        #expect(PowerPointFailureContent(.cancelled) == nil, "Leaving is not a failure to show")
    }

    @Test func speakerNotesAreNamedOnlyForTheirCategory() throws {
        for failure in PowerPointFailure.allCases {
            guard let content = PowerPointFailureContent(failure) else { continue }
            for localization in ["en", "ar"] {
                let text = [content.title, content.message].compactMap { L10n.string($0, localization: localization) }.joined(separator: " ")
                let namesNotes = text.contains("Speaker Notes") || text.contains("ملاحظات")
                #expect(namesNotes == (failure == .speakerNotesUnsupported), "\(failure) \(localization): \(text)")
            }
        }
    }

    /// No category's text says anything technical, in English or Arabic, and none is missing.
    @Test func noTechnicalDetailReachesTheScreen() {
        let technical = ["912", "WebKit", "OfficeImport", "XML", "ZIP", "zip", "cache", "Cache", "renderer", "macro",
                         "path", "error", "Error", "/", "\\", "%@", "%lld"]
        for failure in PowerPointFailure.allCases {
            guard let content = PowerPointFailureContent(failure) else { continue }
            var keys = [content.title, content.message]
            keys += [.presentationPptxRetry, .presentationPptxRetryHint, .presentationPptxImportPDF, .presentationPptxImportPDFHint]
            for key in keys {
                for localization in ["en", "ar"] {
                    let text = L10n.string(key, localization: localization) ?? ""
                    #expect(!text.isEmpty && text != key.rawValue, "\(key.rawValue) \(localization) is translated")
                    let found = technical.filter { text.contains($0) }
                    #expect(found.isEmpty, "\(key.rawValue) \(localization) contains \(found)")
                }
            }
        }
    }

    @Test func importPDFIsOfferedOnlyWhereThePresentationCanBeExported() {
        let offered = PowerPointFailure.allCases.filter { PowerPointFailureContent($0)?.canImportPDF == true }
        #expect(Set(offered) == [.speakerNotesUnsupported, .unsupportedPresentation, .renderingFailed, .corruptedCache, .timeout, .unknown])
        // Not a presentation, unsafe, missing parts or no space: a PDF of it isn't the answer.
        for failure in [PowerPointFailure.invalidSource, .securityRejected, .missingResource, .storageFailure] {
            #expect(PowerPointFailureContent(failure)?.canImportPDF == false, "\(failure)")
        }
        #expect(PowerPointFailureContent(.securityRejected)?.canRetry == false, "No retry loop for a rejected file")
        #expect(PowerPointFailureContent(.speakerNotesUnsupported)?.canRetry == false, "Retrying can't change a notes refusal")
        #expect(PowerPointFailureContent(.unsupportedPresentation)?.canRetry == false)
    }
}

/// A9.5.2: the failure screen through the model: Try Again, Import PDF,
/// cancellation, sessions and the PDF reader's page.
@MainActor
@Suite("PowerPoint failure screen")
struct PowerPointFailureScreenTests {
    private let services = Services()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TaskLensPowerPointFailureScreen", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var documents: DocumentService { services.documents(in: directory) }
    private var sessions: PresentationSessionStore {
        PresentationSessionStore(sessions: services.repositories.presentationSessions, clock: services.clock)
    }

    // MARK: Through the model

    private func importDeck() async throws -> Document {
        try await documents.importData(powerPointPackage(), filename: "Deck.pptx", contentType: nil)
    }

    private func makeModel(_ deck: Document, _ slides: ScriptedSlides, onImportPDF: (@MainActor () -> Void)? = {}) -> PresentationModel {
        PresentationModel(request: .powerPoint(deck.id), documentService: documents, sessionStore: sessions,
                          slideImages: slides, onImportPDF: onImportPDF)
    }

    @Test func aFailureShowsItsScreenAndSavesNoSession() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let model = makeModel(deck, ScriptedSlides(documents: documents, [.fail(.speakerNotesUnsupported)]))
        await model.load()
        #expect(model.failureContent == PowerPointFailureContent(.speakerNotesUnsupported))
        #expect(model.phase == .error(.unsupportedSource))
        #expect(!model.hasSlides && model.slideCount == 0)
        await model.saveSession()
        model.didLeave()
        #expect(try await sessions.allSessions().isEmpty, "No session for a failed file")
    }

    @Test func tryAgainUsesTheSamePipelineAndThenPresentsNormally() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let slides = ScriptedSlides(documents: documents, [.fail(.renderingFailed), .fail(.timeout), .slides(4)])
        let model = makeModel(deck, slides)
        await model.load()
        #expect(model.failureContent?.title == .presentationPptxFailedTitle)

        await model.retry()
        #expect(model.failureContent?.title == .presentationPptxTimeoutTitle, "Failing again shows the screen again")
        #expect(try await sessions.allSessions().isEmpty)

        await model.retry()
        #expect(model.failureContent == nil)
        #expect(model.powerPointFailure == nil)
        #expect(model.phase == .ready)
        #expect(model.slideCount == 4)
        #expect(slides.calls == 3, "Each attempt goes through the provider once")
        model.goToSlide(number: 3)
        await model.saveSession()
        #expect(try await sessions.session(for: .powerPoint(deck.id))?.currentSlide == 2, "A normal session after success")
    }

    @Test func tryAgainIsIgnoredWhereItIsNotOffered() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        for failure in [PowerPointFailure.securityRejected, .speakerNotesUnsupported, .unsupportedPresentation] {
            let slides = ScriptedSlides(documents: documents, [.fail(failure), .slides(2)])
            let model = makeModel(deck, slides)
            await model.load()
            await model.retry()
            #expect(slides.calls == 1, "\(failure) is not loaded again")
            #expect(model.failureContent == PowerPointFailureContent(failure))
        }
    }

    @Test func importPDFReachesTheCallbackOnly() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        var calls = 0
        let model = makeModel(deck, ScriptedSlides(documents: documents, [.fail(.unsupportedPresentation)])) { calls += 1 }
        await model.load()
        model.importPDF()
        #expect(calls == 1)
        #expect(model.failureContent == PowerPointFailureContent(.unsupportedPresentation), "The screen stays until A9.5.3 acts on it")

        // Where Import PDF is not offered, the callback is never called.
        var other = 0
        let invalid = makeModel(deck, ScriptedSlides(documents: documents, [.fail(.invalidSource)])) { other += 1 }
        await invalid.load()
        invalid.importPDF()
        #expect(other == 0)

        // With no callback the action is not shown at all.
        let none = makeModel(deck, ScriptedSlides(documents: documents, [.fail(.speakerNotesUnsupported)]), onImportPDF: nil)
        await none.load()
        #expect(none.failureContent?.actions == [.cancel])
    }

    @Test func aCancelledLoadShowsNoFailure() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let model = makeModel(deck, ScriptedSlides(documents: documents, [.fail(.cancelled)]))
        await model.load()
        #expect(model.failureContent == nil)
        #expect(model.wasCancelled)
        #expect(try await sessions.allSessions().isEmpty)
    }

    @Test func otherSourcesKeepTheirOwnErrorScreens() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PresentationModel(request: .pdf(DocumentID()), documentService: documents, sessionStore: sessions)
        await model.load()
        #expect(model.phase == .error(.unreadable))
        #expect(model.failureContent == nil)
        #expect(model.powerPointFailure == nil)
    }

    /// The PDF reader's page stays where it was through a failure, Try Again and leaving.
    @Test func theReaderPageIsUntouched() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try await documents.importData(Data("%PDF-1.4".utf8), filename: "Report.pdf", contentType: .pdf)
        _ = try await documents.setLastReadPage(pdf.id, page: 19) // page 20
        let deck = try await importDeck()
        let model = makeModel(deck, ScriptedSlides(documents: documents, [.fail(.renderingFailed), .fail(.renderingFailed)]))
        await model.load()
        await model.retry()
        model.importPDF()
        model.didLeave()
        await model.saveSession()
        #expect(try await documents.document(id: pdf.id).lastReadPage == 19)
        #expect(try await documents.document(id: deck.id).lastReadPage == nil)
    }
}
