import CoreGraphics
import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation
import UniformTypeIdentifiers

/// A real PDF whose page `i` is `100 + i` points wide, so a test can tell pages apart.
private func makePDF(pages: Int) -> Data {
    let data = NSMutableData()
    var firstBox = CGRect(x: 0, y: 0, width: 100, height: 100)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &firstBox, nil)
    else { return Data() }
    for index in 0..<pages {
        var box = CGRect(x: 0, y: 0, width: CGFloat(100 + index), height: 100)
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// A well-formed PDF whose page tree has no pages. Core Graphics adds a blank
/// page to a context that draws none, so this one is written by hand.
private func emptyPDF() -> Data {
    let objects = [
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
        "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n",
    ]
    var body = "%PDF-1.4\n"
    var offsets: [Int] = []
    for object in objects {
        offsets.append(body.utf8.count)
        body += object
    }
    let xrefOffset = body.utf8.count
    body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets {
        body += String(repeating: "0", count: 10 - String(offset).count) + "\(offset) 00000 n \n"
    }
    body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
    return Data(body.utf8)
}

/// A document service in a fresh folder, plus the folder to delete.
private struct Library {
    let env = TestEnvironment()
    let directory = TemporaryDirectory.make()
    var service: DocumentService { env.documents(in: directory) }

    func importPDF(pages: Int) async throws -> Document {
        try await service.importData(makePDF(pages: pages), filename: "Deck.pdf", contentType: .pdf)
    }

    func loader(for document: Document) -> PDFPresentationLoader {
        PDFPresentationLoader(documentID: document.id, documentService: service, clock: env.clock)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
@Suite("PDF presentation")
struct PDFPresentationTests {
    // MARK: Loading

    @Test(arguments: [1, 3, 10, 50])
    func onePageBecomesOneSlideInOrder(pages: Int) async throws {
        let library = Library()
        defer { library.cleanUp() }
        let document = try await library.importPDF(pages: pages)

        let presentation = try await library.loader(for: document).loadPresentation()
        #expect(presentation.sourceType == .pdf)
        #expect(presentation.documentID == document.id)
        #expect(presentation.title == "Deck")
        #expect(presentation.slideCount == pages)
        #expect(presentation.createdAt == library.env.clock.now())

        // Each slide names its page, and that page is the matching page in the file.
        let pdf = try #require(CGPDFDocument(library.service.fileURL(for: document) as CFURL))
        #expect(pdf.numberOfPages == pages)
        for slide in presentation.slides {
            #expect(slide.source == .pdfPage(document.id, pageIndex: slide.index))
            let page = try #require(pdf.page(at: slide.index + 1))
            #expect(page.getBoxRect(.mediaBox).width == CGFloat(100 + slide.index))
        }
    }

    @Test func damagedFileIsUnreadable() async throws {
        let library = Library()
        defer { library.cleanUp() }
        let document = try await library.service.importData(Data("not a pdf".utf8), filename: "Broken.pdf", contentType: .pdf)

        await #expect(throws: TaskLensError.persistenceFailed(operation: .read, details: "The PDF could not be opened.")) {
            try await library.loader(for: document).loadPresentation()
        }
        let engine = PresentationEngine()
        let loaded = await engine.load(from: library.loader(for: document))
        #expect(!loaded)
        #expect(engine.phase == .error(.unreadable))
    }

    @Test func pdfWithoutPagesCannotBePresented() async throws {
        let library = Library()
        defer { library.cleanUp() }
        let document = try await library.service.importData(emptyPDF(), filename: "Empty.pdf", contentType: .pdf)
        // Core Graphics (like PDFKit) refuses to open a PDF with no pages, so there is nothing to present.
        #expect(CGPDFDocument(library.service.fileURL(for: document) as CFURL) == nil)

        await #expect(throws: TaskLensError.persistenceFailed(operation: .read, details: "The PDF could not be opened.")) {
            try await library.loader(for: document).loadPresentation()
        }
        let engine = PresentationEngine()
        let loaded = await engine.load(from: library.loader(for: document))
        #expect(!loaded)
        #expect(engine.phase == .error(.unreadable))
        #expect(engine.document == nil)
    }

    @Test func otherKindsAreUnsupported() async throws {
        let library = Library()
        defer { library.cleanUp() }
        let text = try await library.service.importData(Data("hello".utf8), filename: "a.txt", contentType: .plainText)

        let engine = PresentationEngine()
        let loaded = await engine.load(from: library.loader(for: text))
        #expect(!loaded)
        #expect(engine.phase == .error(.unsupportedSource))
    }

    @Test func unknownDocumentIsUnreadable() async {
        let library = Library()
        defer { library.cleanUp() }
        let loader = PDFPresentationLoader(documentID: DocumentID(), documentService: library.service)

        let engine = PresentationEngine()
        let loaded = await engine.load(from: loader)
        #expect(!loaded)
        #expect(engine.phase == .error(.unreadable))
    }

    // MARK: Engine

    @Test func loadedPDFDrivesTheEngine() async throws {
        let library = Library()
        defer { library.cleanUp() }
        let document = try await library.importPDF(pages: 10)
        let engine = PresentationEngine()

        let loaded = await engine.load(from: library.loader(for: document))
        #expect(loaded)
        #expect(engine.phase == .ready)
        #expect(engine.currentSlide == 0)
        #expect(engine.slideCount == 10)
        #expect(engine.currentSlideContent?.source == .pdfPage(document.id, pageIndex: 0))

        let backAtFirst = engine.previous()
        #expect(!backAtFirst)
        let forward = engine.next()
        #expect(forward)
        #expect(engine.currentSlideContent?.source == .pdfPage(document.id, pageIndex: 1))
        let back = engine.previous()
        #expect(back)
        #expect(engine.currentSlide == 0)

        let jumped = engine.goToSlide(9)
        #expect(jumped)
        #expect(engine.state.displaySlideNumber == 10)
        let pastLast = engine.next(), outOfRange = engine.goToSlide(10)
        #expect(!pastLast && !outOfRange)
        #expect(engine.currentSlide == 9)
    }

    // MARK: Separation from the reader

    @Test func presentingAndReadingKeepTheirOwnPositions() async throws {
        let library = Library()
        defer { library.cleanUp() }
        let service = library.service
        let imported = try await library.importPDF(pages: 30)
        // The reader is on page 20 (zero-based 19).
        _ = try await service.setLastReadPage(imported.id, page: 19)
        let before = try await service.document(id: imported.id)

        let engine = PresentationEngine()
        await engine.load(from: library.loader(for: imported), startAt: 4)
        #expect(engine.currentSlide == 4)
        engine.play()
        engine.next()
        engine.goToSlide(12)

        // Presenting changed nothing the reader stores.
        let afterPresenting = try await service.document(id: imported.id)
        #expect(afterPresenting.lastReadPage == 19)
        #expect(afterPresenting.lastOpenedAt == before.lastOpenedAt)
        #expect(afterPresenting == before)

        // Reading moves the reader only.
        _ = try await service.setLastReadPage(imported.id, page: 25)
        #expect(engine.currentSlide == 12)
        #expect(try await service.document(id: imported.id).lastReadPage == 25)
    }
}
