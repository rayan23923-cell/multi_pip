import DocumentsFeature
import Foundation
import PresentationFeature
import Testing
import TLCoreServices
import TLDomain
import TLFoundation
import TLNavigation
import UIKit

/// The smallest stored package TaskLens accepts as a .pptx. Its slides come
/// from `PreparedSlides`, not from WebKit.
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

/// Slide images standing in for the WebKit renderer: slide N is a PNG
/// 100 + N pixels wide, in the document's generated files folder. Renders once
/// per document, like the app's cache.
private final class PreparedSlides: PowerPointSlideImageProviding, @unchecked Sendable {
    private let documents: DocumentService
    private let count: Int
    private let lock = NSLock()
    private var _renders = 0
    var renders: Int { lock.withLock { _renders } }

    init(documents: DocumentService, count: Int) {
        self.documents = documents
        self.count = count
    }

    func slideImage(for documentID: DocumentID, index: Int) -> URL {
        documents.generatedFilesDirectory(for: documentID)
            .appendingPathComponent(String(format: "Slides/slide-%03d.png", index + 1))
    }

    func slideImages(for document: Document, fileURL: URL) async throws -> [URL] {
        let urls = (0..<count).map { slideImage(for: document.id, index: $0) }
        if urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return urls }
        lock.withLock { _renders += 1 }
        try FileManager.default.createDirectory(at: urls[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        for (index, url) in urls.enumerated() {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let data = UIGraphicsImageRenderer(size: CGSize(width: 101 + index, height: 50), format: format).pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 101 + index, height: 50))
            }
            try data.write(to: url)
        }
        return urls
    }
}

/// A9.3: an imported PowerPoint file presented through the existing model,
/// engine, Auto Play and session, from its rendered slide images.
@MainActor
@Suite("PowerPoint presentation model")
struct PowerPointPresentationModelTests {
    private let services = Services()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TaskLensPowerPointPresentationTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var documents: DocumentService { services.documents(in: directory) }
    private var sessions: PresentationSessionStore {
        PresentationSessionStore(sessions: services.repositories.presentationSessions, clock: services.clock)
    }

    private static let neverEnds: PresentationAutoPlayer.Sleep = { _ in try await Task.sleep(for: .seconds(3600)) }
    private static let quick: PresentationAutoPlayer.Sleep = { _ in try await Task.sleep(for: .milliseconds(5)) }

    private func importDeck(_ name: String = "Deck") async throws -> Document {
        try await documents.importData(powerPointPackage(), filename: "\(name).pptx", contentType: nil)
    }

    private func open(_ deck: Document, slides: PreparedSlides, sleep: PresentationAutoPlayer.Sleep? = nil) async -> PresentationModel {
        let model = PresentationModel(request: .powerPoint(deck.id), documentService: documents, sessionStore: sessions,
                                      slideImages: slides, autoPlaySleep: sleep)
        await model.load()
        return model
    }

    private func leave(_ model: PresentationModel) async {
        model.didLeave()
        await model.saveSession()
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    // MARK: Opening and navigation

    @Test(arguments: [1, 3, 10, 50, 100])
    func opensOnTheFirstSlideAndStaysInBounds(count: Int) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let model = await open(deck, slides: PreparedSlides(documents: documents, count: count))
        #expect(model.phase == .ready)
        #expect(model.title == "Deck")
        #expect(model.slideCount == count)
        #expect(model.slideNumber == 1, "Slide 1 of \(count)")
        #expect(model.engine.currentSlide == 0, "Zero-based inside")
        #expect(model.currentSlide?.source == .renderedImage(deck.id, index: 0))
        #expect(model.engine.document?.sourceType == .powerpoint)
        #expect(!model.canGoBack)
        #expect(model.canGoForward == (count > 1))

        model.previous()
        #expect(model.slideNumber == 1)
        model.next()
        #expect(model.slideNumber == min(2, count))
        model.previous()
        #expect(model.slideNumber == 1)
        model.goToSlide(number: count)
        #expect(model.slideNumber == count)
        #expect(!model.canGoForward)
        model.next()
        #expect(model.slideNumber == count, "No wrap-around")
        model.goToSlide(number: count + 1)
        model.goToSlide(number: 0)
        #expect(model.slideNumber == count, "Out-of-range numbers are ignored")
        model.goToSlide(number: 1)
        #expect(model.slideNumber == 1)
        model.didLeave()
    }

    @Test func eachSlideShowsItsOwnRenderedImage() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let slides = PreparedSlides(documents: documents, count: 3)
        let model = await open(deck, slides: slides)
        for index in 0..<3 {
            model.goToSlide(number: index + 1)
            let source = try #require(model.currentSlide?.source)
            let image = try #require(await model.image(for: source, maxPixelSize: 4000))
            #expect(image.width == 101 + index, "Slide \(index + 1) is slide-00\(index + 1).png, not re-rendered")
        }
        #expect(model.currentSlideDescription == "Deck")
        #expect(slides.renders == 1)
        model.didLeave()
    }

    @Test func reopeningUsesTheImagesAlreadyRendered() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let slides = PreparedSlides(documents: documents, count: 5)
        await leave(await open(deck, slides: slides))
        let again = await open(deck, slides: slides)
        #expect(again.slideCount == 5)
        #expect(slides.renders == 1, "No second render")
        again.didLeave()
    }

    @Test func withoutARendererItFailsCleanly() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let model = PresentationModel(request: .powerPoint(deck.id), documentService: documents, sessionStore: sessions)
        await model.load()
        #expect(model.phase == .error(.unsupportedSource))
        #expect(!model.hasSlides)
        #expect(try await sessions.allSessions().isEmpty, "No session for a presentation that never opened")
    }

    // MARK: Auto Play (A6)

    @Test func autoPlayPlaysPausesResumesAndStops() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let model = await open(deck, slides: PreparedSlides(documents: documents, count: 10), sleep: Self.neverEnds)
        #expect(model.autoPlayButton == .start)
        model.toggleAutoPlay()
        #expect(model.phase == .playing)
        #expect(model.autoPlayer.hasCountdown)
        model.toggleAutoPlay()
        #expect(model.phase == .paused)
        #expect(!model.autoPlayer.hasCountdown)
        model.toggleAutoPlay()
        #expect(model.phase == .playing)
        model.stopAutoPlay()
        #expect(model.phase == .ready)
        #expect(!model.autoPlayer.hasCountdown)
        #expect(model.slideNumber == 1)
        model.didLeave()
    }

    @Test(arguments: [5, 10, 15, 30, 60, 7])
    func autoPlayWaitsTheChosenInterval(seconds: Int) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let waits = DurationLog()
        let model = await open(deck, slides: PreparedSlides(documents: documents, count: 10), sleep: { duration in
            waits.append(duration)
            try await Task.sleep(for: .seconds(3600))
        })
        model.setAutoPlayInterval(seconds)
        model.toggleAutoPlay()
        #expect(await waitUntil { !waits.values.isEmpty })
        #expect(waits.values.first == .seconds(seconds))
        model.didLeave()
    }

    @Test func autoPlayRunsToTheLastSlideAndStops() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let model = await open(deck, slides: PreparedSlides(documents: documents, count: 10), sleep: Self.quick)
        model.toggleAutoPlay()
        #expect(await waitUntil { model.phase == .completed })
        #expect(model.slideNumber == 10)
        #expect(!model.autoPlayer.hasCountdown)
    }

    // MARK: Session (A7)

    @Test func reopensOnTheSlideWhereItWasLeft() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let slides = PreparedSlides(documents: documents, count: 20)
        let first = await open(deck, slides: slides)
        first.goToSlide(number: 8)
        await leave(first)
        let second = await open(deck, slides: slides)
        #expect(second.slideNumber == 8)
        second.goToSlide(number: 15)
        await leave(second)
        #expect(await open(deck, slides: slides).slideNumber == 15)
        #expect(await sessions.session(for: .powerPoint(deck.id))?.currentSlide == 14)
        #expect(try await sessions.allSessions().count == 1)
    }

    @Test func twoPowerPointFilesKeepTheirOwnSlides() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try await importDeck("A"), b = try await importDeck("B")
        let slides = PreparedSlides(documents: documents, count: 20)
        let modelA = await open(a, slides: slides)
        modelA.goToSlide(number: 5)
        await leave(modelA)
        let modelB = await open(b, slides: slides)
        modelB.goToSlide(number: 9)
        await leave(modelB)

        #expect(await open(a, slides: slides).slideNumber == 5)
        #expect(await open(b, slides: slides).slideNumber == 9)
        #expect(try await sessions.allSessions().count == 2)
    }

    @Test func backgroundKeepsTheSlideAndOneCountdown() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let model = await open(deck, slides: PreparedSlides(documents: documents, count: 10), sleep: Self.neverEnds)
        model.goToSlide(number: 6)
        model.toggleAutoPlay()
        model.didEnterBackground()
        await model.saveSession()
        #expect(model.phase == .paused, "A6: playback pauses in the background")
        #expect(model.slideNumber == 6)
        #expect(await sessions.session(for: .powerPoint(deck.id))?.currentSlide == 5)
        model.toggleAutoPlay()
        #expect(model.phase == .playing)
        #expect(model.slideNumber == 6)
        #expect(model.autoPlayer.hasCountdown)
        model.didLeave()
    }

    // MARK: PDF reader separation

    @Test func powerPointSlidesAndThePDFReadingPageStaySeparate() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            for _ in 0..<25 { context.beginPage() }
        }
        let pdf = try await documents.importData(pdfData, filename: "Report.pdf", contentType: .pdf)
        let reader = PDFViewerModel(documentID: pdf.id, documentService: documents, toolCapture: services.toolCapture)
        await reader.load()
        reader.goTo(page: 19)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await documents.document(id: pdf.id).lastReadPage == 19, "Page 20")

        let deck = try await importDeck()
        let slides = PreparedSlides(documents: documents, count: 20)
        let presenting = await open(deck, slides: slides)
        presenting.goToSlide(number: 8)
        presenting.next()
        await leave(presenting)
        #expect(try await documents.document(id: pdf.id).lastReadPage == 19, "Changing slides leaves the reader on page 20")
        #expect(try await documents.document(id: deck.id).lastReadPage == nil)

        reader.goTo(page: 4)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await open(deck, slides: slides).slideNumber == 9, "Reading leaves the presentation on its slide")
    }

    // MARK: Route

    @Test func powerPointRouteAndSession() {
        let id = DocumentID()
        #expect(AppRoute.presentation(.powerPoint(id)) == .presentation(.powerPoint(id)))
        #expect(PresentationRequest.powerPoint(id).sessionSource == .powerPoint(id))
        #expect(PresentationRequest.powerPoint(id) != .pdf(id))
    }
}

/// Durations the Auto Play countdown asked to wait.
private final class DurationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Duration] = []
    var values: [Duration] { lock.withLock { _values } }
    func append(_ value: Duration) { lock.withLock { _values.append(value) } }
}
