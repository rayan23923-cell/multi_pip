import CoreGraphics
import Foundation
import PresentationFeature
import Testing
import TLCoreServices
import TLDomain
import TLFoundation
import TLLocalization
import TLNavigation
import UIKit

private func pdfData(pages: Int) -> Data {
    UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 792, height: 612)).pdfData { context in
        for page in 1...pages {
            context.beginPage()
            "Exported slide \(page)".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 32)])
        }
    }
}

/// A one-page PDF that opens only with a password.
private func lockedPDFData() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    let info = [kCGPDFContextUserPassword: "secret", kCGPDFContextOwnerPassword: "owner"] as CFDictionary
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &box, info)
    else { return Data() }
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

/// A9.5.3: Import PDF on the PowerPoint failure screen imports a PDF the person
/// picked through the library's import and opens it as an ordinary PDF presentation.
@MainActor
@Suite("PowerPoint PDF fallback")
struct PDFFallbackImportTests {
    private let services = Services()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TaskLensPDFFallback", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var documents: DocumentService { services.documents(in: directory.appendingPathComponent("Store", isDirectory: true)) }
    private var sessions: PresentationSessionStore {
        PresentationSessionStore(sessions: services.repositories.presentationSessions, clock: services.clock)
    }

    // MARK: Helpers

    /// A file on disk, as the file picker hands it over.
    private func pickedFile(_ data: Data, named name: String) throws -> URL {
        let folder = directory.appendingPathComponent("Picked", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func pickedPDF(pages: Int, named name: String) throws -> URL {
        try pickedFile(pdfData(pages: pages), named: name)
    }

    private func importDeck(_ name: String = "Deck", workspaceID: WorkspaceID? = nil) async throws -> Document {
        try await documents.importData(scriptedDeckPackage(), filename: "\(name).pptx", contentType: nil, workspaceID: workspaceID)
    }

    /// The failed PowerPoint screen and its fallback, wired as the app wires them.
    private func failedScreen(_ deck: Document, _ failure: PowerPointFailure) async -> (PresentationModel, PDFFallbackImport) {
        let fallback = PDFFallbackImport(failedPresentation: deck.id, documentService: documents)
        let model = PresentationModel(request: .powerPoint(deck.id), documentService: documents, sessionStore: sessions,
                                      slideImages: ScriptedSlides(documents: documents, [.fail(failure)]),
                                      onImportPDF: { fallback.choosePDF() })
        await model.load()
        return (model, fallback)
    }

    /// Taps Import PDF, then the file picker closes with `url` (nil = Cancel),
    /// as the screen's file importer reports it.
    @discardableResult
    private func importPDF(_ model: PresentationModel, _ fallback: PDFFallbackImport, picking url: URL?) async -> DocumentID? {
        model.importPDF()
        #expect(fallback.isChoosing, "Import PDF shows the file picker")
        return await fallback.picked(url)
    }

    private func pdfPresentation(_ id: DocumentID, sleep: PresentationAutoPlayer.Sleep? = nil) async -> PresentationModel {
        let model = PresentationModel(request: .pdf(id), documentService: documents, sessionStore: sessions, autoPlaySleep: sleep)
        await model.load()
        return model
    }

    private func storedFiles() -> Set<String> {
        let folder = directory.appendingPathComponent("Store/Documents", isDirectory: true)
        return Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    // MARK: A, B, E: the picked PDF opens as a normal presentation

    @Test(arguments: [PowerPointFailure.speakerNotesUnsupported, .renderingFailed, .unsupportedPresentation, .timeout, .unknown, .corruptedCache])
    func importPDFOpensThePickedPDFAsANormalPresentation(failure: PowerPointFailure) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceID()
        let deck = try await importDeck(workspaceID: workspace)
        let picked = try pickedPDF(pages: 3, named: "Deck exported.pdf")
        let (model, fallback) = await failedScreen(deck, failure)
        #expect(model.failureContent?.canImportPDF == true)

        let id = try #require(await importPDF(model, fallback, picking: picked))
        #expect(fallback.importedPDF == id, "The screen opens it")
        #expect(fallback.errorMessage == nil)
        #expect(!fallback.isChoosing && !fallback.isImporting)

        // An ordinary PDF document in the same library, with no link to the PowerPoint file.
        let pdf = try await documents.document(id: id)
        #expect(pdf.kind == .pdf)
        #expect(pdf.title == "Deck exported")
        #expect(pdf.workspaceID == workspace)
        #expect(pdf.sessionID == nil)
        #expect(pdf.lastReadPage == nil)
        #expect(try await documents.documents(in: workspace).map(\.id).contains(id))
        #expect(try await documents.document(id: deck.id).kind == .powerpoint, "The PowerPoint file stays as it was")

        // Presented through the ordinary PDF path.
        let presentation = await pdfPresentation(id)
        #expect(presentation.phase == .ready)
        #expect(presentation.title == "Deck exported")
        #expect(presentation.slideCount == 3)
        #expect(presentation.pdf?.pageCount == 3)
        #expect(presentation.currentSlide?.source == .pdfPage(id, pageIndex: 0))

        // The failed PowerPoint file gets no session.
        model.didLeave()
        await model.saveSession()
        #expect(await sessions.session(for: .powerPoint(deck.id)) == nil)
    }

    // MARK: Real PDF files

    @Test(arguments: [1, 3, 10, 50])
    func realPDFsOfEverySizePresent(pages: Int) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let picked = try pickedPDF(pages: pages, named: "Export \(pages).pdf")
        let size = try Data(contentsOf: picked).count
        let (model, fallback) = await failedScreen(deck, .speakerNotesUnsupported)
        let id = try #require(await importPDF(model, fallback, picking: picked))
        #expect(try await documents.document(id: id).file.byteCount == Int64(size))

        let presentation = await pdfPresentation(id)
        #expect(presentation.slideCount == pages)
        #expect(presentation.pdf?.pageCount == pages)
        presentation.goToSlide(number: pages)
        #expect(presentation.slideNumber == pages)
        #expect(presentation.currentSlide?.source == .pdfPage(id, pageIndex: pages - 1))
        presentation.next()
        #expect(presentation.slideNumber == pages, "Stays on the last slide")
        presentation.goToSlide(number: 1)
        presentation.previous()
        #expect(presentation.slideNumber == 1)
    }

    // MARK: C: cancelling the picker

    @Test func cancellingThePickerLeavesTheFailureScreenUsable() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let (model, fallback) = await failedScreen(deck, .speakerNotesUnsupported)
        let filesBefore = storedFiles()

        #expect(await importPDF(model, fallback, picking: nil) == nil)
        #expect(fallback.importedPDF == nil)
        #expect(fallback.errorMessage == nil, "Cancelling is not an error")
        #expect(!fallback.isChoosing && !fallback.isImporting)
        #expect(model.failureContent == PowerPointFailureContent(.speakerNotesUnsupported), "The failure screen stays")
        #expect(try await documents.documents(in: nil).map(\.id) == [deck.id], "No document")
        #expect(storedFiles() == filesBefore)
        #expect(try await sessions.allSessions().isEmpty, "No session")
        #expect(!FileManager.default.fileExists(atPath: documents.generatedFilesDirectory(for: deck.id).path), "No cache")

        // Import PDF still works afterwards.
        let picked = try pickedPDF(pages: 2, named: "Later.pdf")
        #expect(await importPDF(model, fallback, picking: picked) != nil)
    }

    @Test func aPickerErrorUsesTheLibraryMessage() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let (model, fallback) = await failedScreen(deck, .renderingFailed)
        model.importPDF()
        fallback.pickerFailed()
        #expect(!fallback.isChoosing)
        #expect(fallback.errorMessage == L10n.string(.documentsOpenFailed))
        #expect(model.failureContent == PowerPointFailureContent(.renderingFailed))
        #expect(try await documents.documents(in: nil).map(\.id) == [deck.id])
    }

    // MARK: D, 22: invalid files, then a valid PDF

    @Test func invalidFilesAreRejectedAndLeaveNothingBehind() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let (model, fallback) = await failedScreen(deck, .renderingFailed)
        let filesBefore = storedFiles()
        let rejected: [(URL, String)] = [
            (try pickedFile(Data("not a pdf".utf8), named: "Damaged.pdf"), L10n.string(.documentsOpenFailed)),
            (try pickedFile(lockedPDFData(), named: "Locked.pdf"), L10n.string(.documentsOpenFailed)),
            (try pickedFile(Data("hello".utf8), named: "Notes.txt"), L10n.string(.documentsOpenFailed)),
            (try pickedFile(Data(), named: "Empty.pdf"), L10n.message(for: TaskLensError.validationFailed(.emptyContent))),
        ]
        for (url, message) in rejected {
            #expect(await importPDF(model, fallback, picking: url) == nil, "\(url.lastPathComponent)")
            #expect(fallback.importedPDF == nil)
            #expect(fallback.errorMessage == message, "\(url.lastPathComponent): the library's message")
            #expect(try await documents.documents(in: nil).map(\.id) == [deck.id], "\(url.lastPathComponent): no library item")
            #expect(storedFiles() == filesBefore, "\(url.lastPathComponent): no stored file")
            #expect(try await sessions.allSessions().isEmpty, "No session")
            #expect(model.failureContent == PowerPointFailureContent(.renderingFailed), "The failure screen stays")
            fallback.errorMessage = nil // the alert's OK
        }

        // Then a valid PDF: only that one is added, and it presents.
        let picked = try pickedPDF(pages: 4, named: "Good.pdf")
        let id = try #require(await importPDF(model, fallback, picking: picked))
        #expect(try await documents.documents(in: nil).count == 2)
        #expect(storedFiles().count == filesBefore.count + 1)
        #expect(await pdfPresentation(id).slideCount == 4)
    }

    // MARK: F, G, H: session, auto play and the reader's page

    @Test func theFallbackPDFHasItsOwnSessionAndRestoresIt() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let (model, fallback) = await failedScreen(deck, .speakerNotesUnsupported)
        let picked = try pickedPDF(pages: 20, named: "Lecture.pdf")
        let id = try #require(await importPDF(model, fallback, picking: picked))
        #expect(try await sessions.allSessions().isEmpty, "Importing creates no session")

        let first = await pdfPresentation(id)
        first.goToSlide(number: 12)
        first.setAutoPlayInterval(30)
        first.didLeave()
        await first.saveSession()
        let saved = try #require(await sessions.session(for: .pdf(id)))
        #expect(saved.currentSlide == 11)
        #expect(saved.autoPlayInterval == 30)
        #expect(await sessions.session(for: .powerPoint(deck.id)) == nil, "Nothing for the PowerPoint file")
        #expect(try await sessions.allSessions().count == 1)

        let reopened = await pdfPresentation(id)
        #expect(reopened.slideNumber == 12)
        #expect(reopened.autoPlayInterval == 30)
    }

    @Test func autoPlayRunsOnTheFallbackPDF() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let (model, fallback) = await failedScreen(deck, .timeout)
        let picked = try pickedPDF(pages: 4, named: "Auto.pdf")
        let id = try #require(await importPDF(model, fallback, picking: picked))

        let presentation = await pdfPresentation(id, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
        presentation.toggleAutoPlay()
        #expect(presentation.autoPlayButton == .pause)
        presentation.toggleAutoPlay()
        #expect(presentation.autoPlayButton == .resume)
        presentation.toggleAutoPlay()
        let deadline = ContinuousClock.now + .seconds(180)
        while presentation.phase != .completed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(presentation.phase == .completed)
        #expect(presentation.slideNumber == 4, "Stops on the last slide")
        presentation.stopAutoPlay()
        #expect(presentation.autoPlayButton == .start)
    }

    @Test func theReaderPageIsUntouched() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let readingFile = try pickedPDF(pages: 30, named: "Reading.pdf")
        let reading = try await documents.importFile(at: readingFile)
        _ = try await documents.setLastReadPage(reading.id, page: 19) // page 20
        let deck = try await importDeck()
        let (model, fallback) = await failedScreen(deck, .speakerNotesUnsupported)
        let picked = try pickedPDF(pages: 10, named: "Slides.pdf")
        let id = try #require(await importPDF(model, fallback, picking: picked))

        let presentation = await pdfPresentation(id)
        presentation.goToSlide(number: 7)
        presentation.next()
        presentation.didLeave()
        await presentation.saveSession()
        #expect(try await documents.document(id: reading.id).lastReadPage == 19, "The reader is still on page 20")
        #expect(try await documents.document(id: id).lastReadPage == nil, "Presenting doesn't set a reading page")
        #expect(try await documents.document(id: deck.id).lastReadPage == nil)
    }

    // MARK: I: several fallbacks

    @Test func severalFallbacksStayIndependent() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deckA = try await importDeck("Deck A")
        let deckB = try await importDeck("Deck B")

        let (modelA, fallbackA) = await failedScreen(deckA, .speakerNotesUnsupported)
        let pickedA = try pickedPDF(pages: 3, named: "A.pdf")
        let pdfA = try #require(await importPDF(modelA, fallbackA, picking: pickedA))
        let presentationA = await pdfPresentation(pdfA)
        presentationA.goToSlide(number: 2)
        await presentationA.saveSession()

        let (modelB, fallbackB) = await failedScreen(deckB, .renderingFailed)
        #expect(fallbackB.importedPDF == nil, "B starts with nothing from A")
        let pickedB = try pickedPDF(pages: 10, named: "B.pdf")
        let pdfB = try #require(await importPDF(modelB, fallbackB, picking: pickedB))
        #expect(pdfA != pdfB)
        let presentationB = await pdfPresentation(pdfB)
        #expect(presentationB.slideNumber == 1, "B doesn't open on A's slide")
        #expect(presentationB.slideCount == 10)
        presentationB.goToSlide(number: 9)
        await presentationB.saveSession()

        #expect(await sessions.session(for: .pdf(pdfA))?.currentSlide == 1)
        #expect(await sessions.session(for: .pdf(pdfB))?.currentSlide == 8)
        #expect(await sessions.session(for: .powerPoint(deckA.id)) == nil)
        #expect(await sessions.session(for: .powerPoint(deckB.id)) == nil)
        #expect(try await documents.document(id: pdfA).title == "A")
        #expect(try await documents.document(id: pdfB).title == "B")
        #expect(await pdfPresentation(pdfA).slideNumber == 2)
        #expect(await pdfPresentation(pdfB).slideNumber == 9)
    }

    // MARK: Duplicates and cache

    /// Picking a PDF already in the library does what the library import does:
    /// it adds another document and leaves the existing one as it was.
    @Test func aDuplicatePDFFollowsTheLibraryImport() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let picked = try pickedPDF(pages: 2, named: "Same.pdf")
        let existing = try await documents.importFile(at: picked)
        _ = try await documents.setLastReadPage(existing.id, page: 1)
        let deck = try await importDeck()
        let (model, fallback) = await failedScreen(deck, .speakerNotesUnsupported)
        let id = try #require(await importPDF(model, fallback, picking: picked))
        #expect(id != existing.id)
        #expect(try await documents.documents(in: nil).filter { $0.kind == .pdf }.count == 2)
        #expect(try await documents.document(id: existing.id) == existing.with(lastReadPage: 1))
    }

    /// The PDF never goes into the PowerPoint file's slide cache, and gets no cache of its own.
    @Test func theFallbackPDFStaysOutOfThePowerPointCache() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let (model, fallback) = await failedScreen(deck, .speakerNotesUnsupported)
        let picked = try pickedPDF(pages: 3, named: "C.pdf")
        let id = try #require(await importPDF(model, fallback, picking: picked))
        _ = await pdfPresentation(id)
        #expect(!FileManager.default.fileExists(atPath: documents.generatedFilesDirectory(for: deck.id).path))
        #expect(!FileManager.default.fileExists(atPath: documents.generatedFilesDirectory(for: id).path))
        #expect(try await documents.document(id: id).file.relativePath.hasPrefix("Documents/"), "Stored with the other documents")
    }

    // MARK: Where Import PDF is not offered

    @Test func importPDFIsIgnoredWhereItIsNotOffered() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        for failure in [PowerPointFailure.invalidSource, .securityRejected, .missingResource, .storageFailure] {
            let (model, fallback) = await failedScreen(deck, failure)
            model.importPDF()
            #expect(!fallback.isChoosing, "\(failure): no picker")
        }
    }

    // MARK: The UI test seam

    @Test func aScriptedPickGoesThroughTheSameImport() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        var picks: [URL?] = [nil, try pickedPDF(pages: 5, named: "Scripted.pdf")]
        let fallback = PDFFallbackImport(failedPresentation: deck.id, documentService: documents, picker: .scripted {
            picks.isEmpty ? nil : picks.removeFirst()
        })
        fallback.choosePDF()
        #expect(!fallback.isChoosing, "No system picker")
        try await Task.sleep(for: .milliseconds(50))
        #expect(fallback.importedPDF == nil, "The first pick is a cancel")

        fallback.choosePDF()
        let deadline = ContinuousClock.now + .seconds(30)
        while fallback.importedPDF == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let id = try #require(fallback.importedPDF,
                              "error: \(fallback.errorMessage ?? "none"), importing: \(fallback.isImporting)")
        #expect(await pdfPresentation(id).slideCount == 5)
    }

    // MARK: Navigation

    @Test func theImportedPDFReplacesTheFailedScreen() {
        let router = AppRouter(selectedTab: .workspaces)
        let deck = DocumentID(), pdf = DocumentID(), workspace = WorkspaceID()
        router.workspacesPath = [.workspace(workspace), .documents(workspace), .powerPoint(deck)]
        router.replaceTop(with: .presentation(.pdf(pdf)))
        #expect(router.workspacesPath == [.workspace(workspace), .documents(workspace), .presentation(.pdf(pdf))],
                "Back from the PDF goes to the library, as it would have from the PowerPoint file")
        #expect(router.commandCenterPath.isEmpty)

        let root = AppRouter()
        root.replaceTop(with: .presentation(.pdf(pdf)))
        #expect(root.commandCenterPath == [.presentation(.pdf(pdf))])
    }
}

private extension Document {
    func with(lastReadPage: Int) -> Document {
        var copy = self
        copy.lastReadPage = lastReadPage
        return copy
    }
}
