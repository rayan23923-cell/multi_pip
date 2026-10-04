import DocumentsFeature
import Foundation
import PresentationFeature
import Testing
import TLCoreServices
import TLDomain
import TLNavigation
import UIKit
import UniformTypeIdentifiers

private func presentationDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("TaskLensPresentationTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

/// A PDF with `pages` pages.
private func pdf(pages: Int) -> Data {
    UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
        for page in 1...max(pages, 1) {
            context.beginPage()
            "Slide \(page)".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
    }
}

/// A `width` × `height` PNG.
private func png(width: Int, height: Int) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
        UIColor.systemOrange.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

@MainActor
@Suite("Presentation screen model")
struct PresentationModelTests {
    private let services = Services()
    private let directory = presentationDirectory()
    private var documents: DocumentService { services.documents(in: directory) }

    private func importPDF(pages: Int) async throws -> Document {
        try await documents.importData(pdf(pages: pages), filename: "Deck.pdf", contentType: .pdf)
    }

    private func importImages(_ names: [String]) async throws -> [Document] {
        var imported: [Document] = []
        for (index, name) in names.enumerated() {
            imported.append(try await documents.importData(png(width: 40 + index, height: 30), filename: "\(name).png", contentType: .png))
        }
        return imported
    }

    // MARK: PDF

    @Test(arguments: [1, 3, 10, 50])
    func pdfOpensOnTheFirstSlideAndStaysInBounds(pages: Int) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: pages)
        let model = PresentationModel(request: .pdf(document.id), documentService: documents)

        await model.load()
        #expect(model.phase == .ready)
        #expect(model.title == "Deck")
        #expect(model.pdf?.pageCount == pages)
        #expect(model.slideNumber == 1)
        #expect(model.slideCount == pages)
        #expect(model.currentSlide?.source == .pdfPage(document.id, pageIndex: 0))
        #expect(!model.canGoBack)
        #expect(model.canGoForward == (pages > 1))

        model.previous()
        #expect(model.slideNumber == 1)
        for expected in 2...max(pages, 2) where expected <= pages {
            model.next()
            #expect(model.slideNumber == expected)
        }
        #expect(model.slideNumber == pages)
        #expect(!model.canGoForward)
        model.next()
        #expect(model.slideNumber == pages, "Next on the last slide does not wrap")
        #expect(model.phase == .ready, "No auto play: the presentation never starts playing on its own")
    }

    @Test func goToSlideUsesOneBasedNumbersAndIgnoresOutOfRange() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 10)
        let model = PresentationModel(request: .pdf(document.id), documentService: documents)
        await model.load()

        model.goToSlide(number: 7)
        #expect(model.slideNumber == 7)
        #expect(model.engine.currentSlide == 6)
        model.goToSlide(number: 0)
        model.goToSlide(number: 11)
        #expect(model.slideNumber == 7)
        model.goToSlide(number: 10)
        #expect(!model.canGoForward)
    }

    @Test func presentingDoesNotMoveTheReadingPage() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 5)
        let reader = PDFViewerModel(documentID: document.id, documentService: documents, toolCapture: services.toolCapture)
        await reader.load()
        reader.goTo(page: 3)
        try await Task.sleep(for: .milliseconds(200)) // The reader saves its page in the background.
        #expect(try await documents.document(id: document.id).lastReadPage == 3)

        let model = PresentationModel(request: .pdf(document.id), documentService: documents)
        await model.load()
        model.next()
        model.goToSlide(number: 5)
        model.previous()
        #expect(model.slideNumber == 4)

        let stored = try await documents.document(id: document.id)
        #expect(stored.lastReadPage == 3)
        // A new reader opens where the user was reading, not where they presented.
        let reopened = PDFViewerModel(documentID: document.id, documentService: documents, toolCapture: services.toolCapture)
        await reopened.load()
        #expect(reopened.currentPage == 3)
    }

    // MARK: Images

    @Test(arguments: [1, 3, 10])
    func imagesKeepTheGivenOrder(count: Int) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = try await importImages((0..<count).map { "Image \($0)" })
        let order = Array(images.reversed())
        let model = PresentationModel(request: .images(order.map(\.id)), documentService: documents)

        await model.load()
        #expect(model.phase == .ready)
        #expect(model.slideCount == count)
        for (index, image) in order.enumerated() {
            #expect(model.currentSlide?.source == .image(image.id))
            #expect(model.slideNumber == index + 1)
            _ = await model.image(for: image.id, maxPixelSize: 100)
            #expect(model.currentSlideDescription == image.title)
            model.next()
        }
        #expect(model.slideNumber == count)
    }

    @Test func imagesAreDecodedForTheScreenNotAtFullSize() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let large = try await documents.importData(png(width: 1600, height: 900), filename: "Wide.png", contentType: .png)
        let model = PresentationModel(request: .images([large.id]), documentService: documents)
        await model.load()

        let image = try #require(await model.image(for: large.id, maxPixelSize: 400))
        #expect(image.width == 400)
        #expect(image.height == 225, "Aspect ratio is kept")
    }

    // MARK: Errors

    @Test func missingDocumentIsUnreadable() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PresentationModel(request: .pdf(DocumentID()), documentService: documents)
        await model.load()
        #expect(model.phase == .error(.unreadable))
        #expect(!model.hasSlides)
        #expect(model.pdf == nil)
        #expect(!model.canGoForward && !model.canGoBack)
    }

    @Test func emptyImageListIsEmpty() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PresentationModel(request: .images([]), documentService: documents)
        await model.load()
        #expect(model.phase == .error(.empty))
        #expect(model.slideNumber == 0)
    }

    @Test func wrongKindIsUnsupported() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = try await documents.importData(Data("hello".utf8), filename: "a.txt", contentType: .plainText)
        let image = try await importImages(["Photo"])[0]

        let asPDF = PresentationModel(request: .pdf(image.id), documentService: documents)
        await asPDF.load()
        #expect(asPDF.phase == .error(.unsupportedSource))

        let asImages = PresentationModel(request: .images([image.id, text.id]), documentService: documents)
        await asImages.load()
        #expect(asImages.phase == .error(.unsupportedSource))
    }

    @Test func damagedImageFailsToRenderWithoutCrashing() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try await importImages(["Photo"])[0]
        let model = PresentationModel(request: .images([image.id]), documentService: documents)
        await model.load()
        #expect(model.phase == .ready)
        // The file is removed after loading: the slide reports a rendering failure.
        try FileManager.default.removeItem(at: documents.fileURL(for: image))
        #expect(await model.image(for: image.id, maxPixelSize: 100) == nil)
    }

    // MARK: Auto play

    /// A countdown that never ends on its own, so a test sees states without slides moving.
    private static let neverEnds: PresentationAutoPlayer.Sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
    /// A countdown of a few milliseconds, standing in for the interval.
    private static let quick: PresentationAutoPlayer.Sleep = { _ in try await Task.sleep(for: .milliseconds(5)) }

    /// Returns as soon as `condition` holds. The limit is generous because the
    /// simulator can be slow when every suite runs in parallel on CI.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    @Test func playButtonFollowsThePlaybackState() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 5)
        let model = PresentationModel(request: .pdf(document.id), documentService: documents, autoPlaySleep: Self.neverEnds)
        await model.load()
        #expect(model.autoPlayButton == .start)
        #expect(!model.isAutoPlayActive)
        #expect(model.autoPlayInterval == 10)

        model.toggleAutoPlay()
        #expect(model.autoPlayButton == .pause)
        #expect(model.isAutoPlaying)
        #expect(model.isAutoPlayActive)
        model.toggleAutoPlay()
        #expect(model.autoPlayButton == .resume)
        #expect(!model.isAutoPlaying)
        #expect(!model.autoPlayer.hasCountdown)
        model.toggleAutoPlay()
        #expect(model.autoPlayButton == .pause)
        model.stopAutoPlay()
        #expect(model.autoPlayButton == .start)
        #expect(!model.isAutoPlayActive)
        #expect(!model.autoPlayer.hasCountdown)
        #expect(model.slideNumber == 1)

        model.setAutoPlayInterval(30)
        #expect(model.autoPlayInterval == 30)
    }

    @Test func autoPlayRunsToTheLastSlideAndStops() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 4)
        let model = PresentationModel(request: .pdf(document.id), documentService: documents, autoPlaySleep: Self.quick)
        await model.load()
        model.toggleAutoPlay()

        #expect(await waitUntil { model.phase == .completed })
        #expect(model.slideNumber == 4, "It stops on the last slide; it does not loop")
        #expect(!model.autoPlayer.hasCountdown)
        #expect(model.autoPlayButton == .start)
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.slideNumber == 4)
    }

    @Test func backgroundPausesAndLeavingStops() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 10)
        let model = PresentationModel(request: .pdf(document.id), documentService: documents, autoPlaySleep: Self.neverEnds)
        await model.load()
        model.next()
        model.toggleAutoPlay()

        model.didEnterBackground()
        #expect(model.phase == .paused, "A suspended app cannot count, so playback pauses")
        #expect(!model.autoPlayer.hasCountdown)
        #expect(model.slideNumber == 2)
        // Back in the foreground it waits for Resume, on the same slide.
        model.toggleAutoPlay()
        #expect(model.phase == .playing)
        #expect(model.slideNumber == 2)

        model.didLeave()
        #expect(model.phase == .ready)
        #expect(!model.autoPlayer.hasCountdown)
    }

    @Test func manualNavigationWhilePlayingKeepsPlaying() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 10)
        let model = PresentationModel(request: .pdf(document.id), documentService: documents, autoPlaySleep: Self.neverEnds)
        await model.load()
        model.toggleAutoPlay()
        model.next()
        model.goToSlide(number: 8)
        model.previous()
        #expect(model.slideNumber == 7)
        #expect(model.phase == .playing)
        #expect(model.autoPlayer.hasCountdown)
        model.stopAutoPlay()
    }

    @Test func autoPlayDoesNotMoveTheReadingPage() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 6)
        let reader = PDFViewerModel(documentID: document.id, documentService: documents, toolCapture: services.toolCapture)
        await reader.load()
        reader.goTo(page: 2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await documents.document(id: document.id).lastReadPage == 2)

        let model = PresentationModel(request: .pdf(document.id), documentService: documents, autoPlaySleep: Self.quick)
        await model.load()
        model.toggleAutoPlay()
        #expect(await waitUntil { model.phase == .completed })
        model.didLeave()

        #expect(try await documents.document(id: document.id).lastReadPage == 2)
        let reopened = PDFViewerModel(documentID: document.id, documentService: documents, toolCapture: services.toolCapture)
        await reopened.load()
        #expect(reopened.currentPage == 2)
    }

    @Test func reopeningStartsWithoutPlayback() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 10)
        let first = PresentationModel(request: .pdf(document.id), documentService: documents, autoPlaySleep: Self.neverEnds)
        await first.load()
        first.toggleAutoPlay()
        first.didLeave()

        let second = PresentationModel(request: .pdf(document.id), documentService: documents, autoPlaySleep: Self.neverEnds)
        await second.load()
        #expect(second.phase == .ready)
        #expect(second.slideNumber == 1)
        #expect(!second.autoPlayer.hasCountdown)
        #expect(second.autoPlayButton == .start)
    }

    // MARK: Session (A7)

    private var sessions: PresentationSessionStore {
        PresentationSessionStore(sessions: services.repositories.presentationSessions, clock: services.clock)
    }

    /// Opens a presentation the way the app does, with the shared session store.
    private func open(_ request: PresentationRequest, sleep: PresentationAutoPlayer.Sleep? = nil) async -> PresentationModel {
        let model = PresentationModel(request: request, documentService: documents, sessionStore: sessions, autoPlaySleep: sleep)
        await model.load()
        return model
    }

    /// Leaves like the screen does, and waits for the save.
    private func leave(_ model: PresentationModel) async {
        model.didLeave()
        await model.saveSession()
    }

    @Test func pdfReopensOnTheSlideWhereItWasLeft() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 48)

        let first = await open(.pdf(document.id))
        #expect(first.slideNumber == 1, "A new presentation starts on slide 1")
        #expect(try await sessions.allSessions().isEmpty, "Opening alone saves nothing")
        first.goToSlide(number: 12)
        await leave(first)
        #expect(await sessions.session(for: .pdf(document.id))?.currentSlide == 11, "Slide 12 is stored as index 11")

        let second = await open(.pdf(document.id))
        #expect(second.slideNumber == 12)
        #expect(second.slideCount == 48)
        #expect(second.engine.currentSlide == 11)
        #expect(second.phase == .ready)
        second.goToSlide(number: 20)
        await leave(second)

        let third = await open(.pdf(document.id))
        #expect(third.slideNumber == 20)
        #expect(try await sessions.allSessions().count == 1, "One record per presentation")
    }

    @Test func imagesReopenOnTheSlideWhereTheyWereLeft() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = try await importImages((0..<10).map { "Photo \($0)" }).map(\.id)

        let first = await open(.images(ids))
        first.goToSlide(number: 7)
        await leave(first)

        let second = await open(.images(ids))
        #expect(second.slideNumber == 7)
        #expect(second.currentSlide?.source == .image(ids[6]))

        // The same images in another order are another presentation.
        let reordered = await open(.images(ids.reversed()))
        #expect(reordered.slideNumber == 1)
    }

    @Test func eachPresentationKeepsItsOwnSlide() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await importPDF(pages: 10)
        let b = try await importPDF(pages: 10)

        let presentingA = await open(.pdf(a.id))
        presentingA.goToSlide(number: 5)
        await leave(presentingA)
        let presentingB = await open(.pdf(b.id))
        presentingB.goToSlide(number: 8)
        await leave(presentingB)

        #expect(await open(.pdf(a.id)).slideNumber == 5)
        #expect(await open(.pdf(b.id)).slideNumber == 8)
    }

    @Test func firstAndLastSlidesAreRestored() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 10)
        let model = await open(.pdf(document.id))
        model.goToSlide(number: 10)
        await leave(model)
        let atLast = await open(.pdf(document.id))
        #expect(atLast.slideNumber == 10)
        #expect(!atLast.canGoForward)

        atLast.goToSlide(number: 1)
        await leave(atLast)
        let atFirst = await open(.pdf(document.id))
        #expect(atFirst.slideNumber == 1)
        #expect(!atFirst.canGoBack)
    }

    @Test func aSlideThatNoLongerFitsOpensOnTheFirstSlide() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 20)
        // Saved when the document had 48 pages, on slide 40.
        try await sessions.save(.pdf(document.id), currentSlide: 39, slideCount: 48, autoPlayInterval: 30)

        let model = await open(.pdf(document.id))
        #expect(model.phase == .ready, "No crash, no error")
        #expect(model.slideNumber == 1)
        #expect(model.slideCount == 20)
        #expect(model.autoPlayInterval == 30, "The interval does not depend on the slides")
        await model.saveSession()
        let replaced = try #require(await sessions.session(for: .pdf(document.id)))
        #expect(replaced.currentSlide == 0)
        #expect(replaced.slideCount == 20, "The stale record is replaced")
    }

    @Test func aMissingDocumentForgetsItsSession() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let gone = DocumentID()
        try await sessions.save(.pdf(gone), currentSlide: 3, slideCount: 10, autoPlayInterval: nil)
        let images = [DocumentID(), DocumentID()]
        try await sessions.save(.images(images), currentSlide: 1, slideCount: 2, autoPlayInterval: nil)

        let pdf = await open(.pdf(gone))
        #expect(pdf.phase == .error(.unreadable))
        #expect(!pdf.hasSlides, "No phantom presentation")
        let slides = await open(.images(images))
        #expect(slides.phase == .error(.unreadable))
        #expect(try await sessions.allSessions().isEmpty)
    }

    @Test func autoPlayIntervalComesBackButPlaybackDoesNot() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 10)
        let first = await open(.pdf(document.id), sleep: Self.neverEnds)
        first.setAutoPlayInterval(30)
        first.goToSlide(number: 4)
        first.toggleAutoPlay()
        #expect(first.isAutoPlaying)
        await leave(first)
        #expect(!first.autoPlayer.hasCountdown)

        let second = await open(.pdf(document.id), sleep: Self.neverEnds)
        #expect(second.autoPlayInterval == 30)
        #expect(second.slideNumber == 4)
        #expect(second.phase == .ready, "Reopening never starts playing on its own")
        #expect(!second.isAutoPlaying)
        #expect(!second.autoPlayer.hasCountdown)
        #expect(second.autoPlayButton == .start)
    }

    @Test func autoPlayProgressIsSavedWithoutAWritePerTick() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 10)
        let model = await open(.pdf(document.id), sleep: Self.quick)
        model.toggleAutoPlay()
        #expect(await waitUntil { model.phase == .completed })
        await model.saveSession()

        #expect(await sessions.session(for: .pdf(document.id))?.currentSlide == 9)
        let writes = try #require(model.sessionRecorder?.writeCount)
        #expect(writes >= 1 && writes <= 10, "At most one write per slide change (\(writes))")
        #expect(try await sessions.allSessions().count == 1)
    }

    @Test func backgroundKeepsOneConsistentSession() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 20)
        let model = await open(.pdf(document.id), sleep: Self.neverEnds)
        model.goToSlide(number: 15)
        model.toggleAutoPlay()

        model.didEnterBackground()
        await model.saveSession()
        #expect(await sessions.session(for: .pdf(document.id))?.currentSlide == 14)
        #expect(!model.autoPlayer.hasCountdown)
        // Back in the foreground: same slide, one record, no playback loop.
        model.didEnterBackground()
        await model.saveSession()
        #expect(model.slideNumber == 15)
        #expect(try await sessions.allSessions().count == 1)
        model.toggleAutoPlay()
        #expect(model.isAutoPlaying)
        model.didLeave()
    }

    @Test func sessionAndReaderPageStaySeparate() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 20)
        let reader = PDFViewerModel(documentID: document.id, documentService: documents, toolCapture: services.toolCapture)
        await reader.load()
        reader.goTo(page: 3)
        try await Task.sleep(for: .milliseconds(200))

        let presenting = await open(.pdf(document.id))
        presenting.goToSlide(number: 12)
        await leave(presenting)
        #expect(try await documents.document(id: document.id).lastReadPage == 3, "Presenting does not move the reading page")

        reader.goTo(page: 7)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await sessions.session(for: .pdf(document.id))?.currentSlide == 11, "Reading does not move the slide")
        #expect(await open(.pdf(document.id)).slideNumber == 12)
        let reopenedReader = PDFViewerModel(documentID: document.id, documentService: documents, toolCapture: services.toolCapture)
        await reopenedReader.load()
        #expect(reopenedReader.currentPage == 7)
    }

    @Test func withoutAStoreNothingIsKept() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await importPDF(pages: 5)
        let model = PresentationModel(request: .pdf(document.id), documentService: documents)
        await model.load()
        model.goToSlide(number: 3)
        model.didLeave()
        #expect(model.sessionRecorder == nil)
        #expect(try await sessions.allSessions().isEmpty)
    }

    // MARK: Route

    @Test func routeCarriesTheRequest() {
        let ids = [DocumentID(), DocumentID()]
        #expect(AppRoute.presentation(.images(ids)) == .presentation(.images(ids)))
        #expect(AppRoute.presentation(.images(ids)) != .presentation(.images(ids.reversed())))
    }
}
