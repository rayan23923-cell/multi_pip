import CoreGraphics
import Foundation
import ImageIO
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import UniformTypeIdentifiers

/// Slide images made by the test instead of WebKit: `count` PNGs in the
/// document's generated files folder, or a chosen failure.
private final class StubSlideImages: PowerPointSlideImageProviding, @unchecked Sendable {
    enum Result { case images(Int), unreadableImage, failure(any Error) }

    private let service: DocumentService
    private let result: Result
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(service: DocumentService, result: Result) {
        self.service = service
        self.result = result
    }

    func slideImage(for documentID: DocumentID, index: Int) -> URL {
        service.generatedFilesDirectory(for: documentID)
            .appendingPathComponent(String(format: "Slides/slide-%03d.png", index + 1))
    }

    func slideImages(for document: Document, fileURL: URL) async throws -> [URL] {
        lock.withLock { _calls += 1 }
        let count: Int
        switch result {
        case .images(let value): count = value
        case .unreadableImage: count = 2
        case .failure(let error): throw error
        }
        let urls = (0..<count).map { slideImage(for: document.id, index: $0) }
        guard let first = urls.first else { return [] }
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (index, url) in urls.enumerated() {
            let data = if case .unreadableImage = result, index == 1 { Data("not an image".utf8) } else { Self.png(width: index + 1) }
            try data.write(to: url)
        }
        return urls
    }

    static func png(width: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 10))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

@MainActor
@Suite("PowerPoint presentation")
struct PowerPointPresentationTests {
    private let env = TestEnvironment()
    private let directory = TemporaryDirectory.make()
    private var service: DocumentService { env.documents(in: directory) }

    private func importDeck(_ name: String = "Deck") async throws -> Document {
        try await service.importData(TestZip.powerPoint(slides: 3), filename: "\(name).pptx", contentType: nil)
    }

    private func loader(_ id: DocumentID, _ images: StubSlideImages) -> ImagePresentationLoader {
        ImagePresentationLoader(powerPoint: id, slideImages: images, documentService: service, clock: env.clock)
    }

    // MARK: Loading

    @Test(arguments: [1, 3, 10, 50, 100])
    func oneSlidePerRenderedImage(count: Int) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let images = StubSlideImages(service: service, result: .images(count))
        let presentation = try await loader(deck.id, images).loadPresentation()
        #expect(presentation.sourceType == .powerpoint)
        #expect(presentation.documentID == deck.id)
        #expect(presentation.title == "Deck")
        #expect(presentation.slideCount == count)
        #expect(presentation.slides.map(\.source) == (0..<count).map { .renderedImage(deck.id, index: $0) })
        #expect(presentation.slides.first?.displayNumber == 1)
        #expect(presentation.slides.last?.displayNumber == count)
        #expect(images.calls == 1)
    }

    @Test func theEngineRunsAPowerPointLikeAnyPresentation() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let engine = PresentationEngine()
        #expect(await engine.load(from: loader(deck.id, StubSlideImages(service: service, result: .images(3)))))
        #expect(engine.phase == .ready)
        #expect(engine.slideCount == 3)
        #expect(!engine.previous(), "No slide before the first")
        #expect(engine.next() && engine.next())
        #expect(!engine.next(), "No wrap after the last")
        #expect(engine.currentSlideContent?.source == .renderedImage(deck.id, index: 2))
        #expect(engine.goToSlide(0))
        #expect(!engine.goToSlide(3))
    }

    // MARK: Failures

    @Test func renderingFailuresMakeNoPresentation() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let deck = try await importDeck()
        let cases: [(StubSlideImages.Result, PresentationFailure)] = [
            (.failure(TaskLensError.unsupportedContent(type: "pptx")), .unsupportedSource), // e.g. speaker notes
            (.failure(TaskLensError.persistenceFailed(operation: .read, details: "render")), .unreadable),
            (.images(0), .empty),
            (.unreadableImage, .unreadable),
        ]
        for (result, failure) in cases {
            let engine = PresentationEngine()
            let loaded = await engine.load(from: loader(deck.id, StubSlideImages(service: service, result: result)))
            #expect(!loaded)
            #expect(engine.phase == .error(failure))
            #expect(engine.document == nil, "No partial or empty presentation")
            #expect(engine.slideCount == 0)
        }
    }

    @Test func onlyPowerPointFilesAreRendered() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try await service.importData(Data("%PDF-1.4".utf8), filename: "Report.pdf", contentType: .pdf)
        let images = StubSlideImages(service: service, result: .images(3))
        await #expect(throws: TaskLensError.unsupportedContent(type: "pdf")) {
            try await loader(pdf.id, images).loadPresentation()
        }
        #expect(images.calls == 0)
        await #expect(throws: TaskLensError.self) {
            try await loader(DocumentID(), images).loadPresentation()
        }
    }

    // MARK: Session identity

    @Test func eachPowerPointFileHasItsOwnSession() async throws {
        let a = DocumentID(), b = DocumentID()
        #expect(PresentationSessionSource.powerPoint(a).sessionID.rawValue == a.rawValue)
        #expect(PresentationSessionSource.powerPoint(a).sessionID != PresentationSessionSource.powerPoint(b).sessionID)
        #expect(PresentationSessionSource.powerPoint(a).sessionID != PresentationSessionSource.images([a]).sessionID)
        #expect(PresentationSessionSource.powerPoint(a).documentIDs == [a])

        let store = PresentationSessionStore(sessions: env.repositories.presentationSessions, clock: env.clock)
        try await store.save(.powerPoint(a), currentSlide: 4, slideCount: 20, autoPlayInterval: nil)
        try await store.save(.powerPoint(b), currentSlide: 8, slideCount: 20, autoPlayInterval: 10)
        #expect(await store.session(for: .powerPoint(a))?.currentSlide == 4)
        #expect(await store.session(for: .powerPoint(b))?.currentSlide == 8)
        #expect(await store.session(for: .powerPoint(b))?.autoPlayInterval == 10)
    }

    // MARK: Generated files

    @Test func slideImagesAreDeletedWithTheirDocument() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = try await importDeck("Kept")
        let deleted = try await importDeck("Deleted")
        for deck in [kept, deleted] {
            _ = try await loader(deck.id, StubSlideImages(service: service, result: .images(2))).loadPresentation()
        }
        try await service.delete(deleted.id)
        #expect(!FileManager.default.fileExists(atPath: service.generatedFilesDirectory(for: deleted.id).path))
        #expect(FileManager.default.fileExists(atPath: service.generatedFilesDirectory(for: kept.id).path))
    }

    @Test func orphanedSlideImagesAreSweptLikeOrphanedFiles() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = try await importDeck("Kept")
        _ = try await loader(kept.id, StubSlideImages(service: service, result: .images(2))).loadPresentation()
        // Slides of a document that no longer exists (e.g. its workspace was deleted).
        let orphan = service.generatedFilesDirectory(for: DocumentID())
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data([1]).write(to: orphan.appendingPathComponent("slide-001.png"))

        let anyAge: TimeInterval = -1e10 // the test clock is in 2001
        #expect(try await service.removeOrphanedFiles() == 0, "Too new to touch")
        #expect(try await service.removeOrphanedFiles(minimumAge: anyAge) == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: service.generatedFilesDirectory(for: kept.id).path))
        #expect(FileManager.default.fileExists(atPath: service.fileURL(for: kept).path))
    }
}
