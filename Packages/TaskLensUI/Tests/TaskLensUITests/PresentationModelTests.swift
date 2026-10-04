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

    /// True once the stored reading page is `page`, checked for up to five seconds.
    private func savedPage(of id: DocumentID, becomes page: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if (try? await documents.document(id: id).lastReadPage) == page { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
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
        // The reader saves its page in the background; wait for it rather than for a fixed time.
        #expect(await savedPage(of: document.id, becomes: 3))

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

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
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
        // The reader saves its page in the background; wait for it rather than for a fixed time.
        #expect(await savedPage(of: document.id, becomes: 2))

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

    // MARK: Route

    @Test func routeCarriesTheRequest() {
        let ids = [DocumentID(), DocumentID()]
        #expect(AppRoute.presentation(.images(ids)) == .presentation(.images(ids)))
        #expect(AppRoute.presentation(.images(ids)) != .presentation(.images(ids.reversed())))
    }
}
