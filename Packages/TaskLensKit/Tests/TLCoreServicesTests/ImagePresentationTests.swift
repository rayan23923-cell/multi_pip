import CoreGraphics
import Foundation
import ImageIO
import Testing
import TLCoreServices
import TLDomain
import TLFoundation
import UniformTypeIdentifiers

/// Encodes a `width` × 10 image (one frame per entry in `frames`) in the given
/// format, or nil when this system cannot write that format.
private func makeImage(width: Int, type: UTType = .png, frames: Int = 1) -> Data? {
    guard let context = CGContext(
        data: nil, width: width, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: 10))
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil) else { return nil }
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

/// A document service in a fresh folder, plus the folder to delete.
private struct ImageLibrary {
    let env = TestEnvironment()
    let directory = TemporaryDirectory.make()
    var service: DocumentService { env.documents(in: directory) }

    /// Imports a PNG named `name` whose width is `width`, so a test can tell images apart.
    func importImage(_ name: String, width: Int) async throws -> Document {
        let data = try #require(makeImage(width: width))
        return try await service.importData(data, filename: "\(name).png", contentType: .png)
    }

    func loader(_ ids: [DocumentID], title: String? = nil) -> ImagePresentationLoader {
        ImagePresentationLoader(documentIDs: ids, title: title, documentService: service, clock: env.clock)
    }

    /// The pixel width stored in a document's file.
    func width(of id: DocumentID) async throws -> Int? {
        let document = try await service.document(id: id)
        let source = CGImageSourceCreateWithURL(service.fileURL(for: document) as CFURL, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
        return properties?[kCGImagePropertyPixelWidth] as? Int
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
@Suite("Image presentation")
struct ImagePresentationTests {
    // MARK: Basic and order

    @Test(arguments: [1, 2, 5, 10, 50, 100])
    func oneImageBecomesOneSlide(count: Int) async throws {
        let library = ImageLibrary()
        defer { library.cleanUp() }
        var images: [Document] = []
        for index in 0..<count {
            images.append(try await library.importImage("Photo \(index)", width: 10 + index))
        }

        let presentation = try await library.loader(images.map(\.id)).loadPresentation()
        #expect(presentation.sourceType == .image)
        #expect(presentation.slideCount == count)
        #expect(presentation.documentID == images[0].id)
        #expect(presentation.title == "Photo 0")
        #expect(presentation.createdAt == library.env.clock.now())
        #expect(presentation.slides.map(\.index) == Array(0..<count))
        #expect(presentation.slides.map(\.source) == images.map { PresentationSlideSource.image($0.id) })
    }

    @Test func keepsTheCallersOrderExactly() async throws {
        let library = ImageLibrary()
        defer { library.cleanUp() }
        // Imported A, B, C, D (so import date and name both say A first), each with its own width.
        let a = try await library.importImage("A", width: 11)
        let b = try await library.importImage("B", width: 22)
        let c = try await library.importImage("C", width: 33)
        let d = try await library.importImage("D", width: 44)

        let presentation = try await library.loader([c.id, a.id, d.id, b.id], title: "Trip").loadPresentation()
        #expect(presentation.title == "Trip")
        #expect(presentation.slides.map(\.source.documentID) == [c.id, a.id, d.id, b.id])

        // Each slide's file is the image the caller put there.
        var widths: [Int?] = []
        for slide in presentation.slides { widths.append(try await library.width(of: slide.source.documentID)) }
        #expect(widths == [33, 11, 44, 22])
    }

    @Test func theSameImageCanAppearTwice() async throws {
        let library = ImageLibrary()
        defer { library.cleanUp() }
        let a = try await library.importImage("A", width: 11)
        let b = try await library.importImage("B", width: 22)

        let presentation = try await library.loader([a.id, b.id, a.id]).loadPresentation()
        #expect(presentation.slides.map(\.source) == [.image(a.id), .image(b.id), .image(a.id)])
    }

    // MARK: Formats

    @Test(arguments: [UTType.jpeg, .png, .heic, .gif, .tiff])
    func readsFormatsTheSystemCanWrite(type: UTType) async throws {
        guard let data = makeImage(width: 40, type: type) else {
            print("IMAGE format \(type.identifier) cannot be written on this system; not checked")
            return
        }
        let library = ImageLibrary()
        defer { library.cleanUp() }
        let image = try await library.service.importData(
            data, filename: "Picture.\(type.preferredFilenameExtension ?? "img")", contentType: type
        )
        #expect(image.kind == .image)

        let presentation = try await library.loader([image.id]).loadPresentation()
        #expect(presentation.slides.map(\.source) == [.image(image.id)])
    }

    @Test func animatedGIFIsOneSlide() async throws {
        let data = try #require(makeImage(width: 30, type: .gif, frames: 3))
        let library = ImageLibrary()
        defer { library.cleanUp() }
        let gif = try await library.service.importData(data, filename: "Loop.gif", contentType: .gif)

        let presentation = try await library.loader([gif.id]).loadPresentation()
        #expect(presentation.slideCount == 1)
    }

    // MARK: Invalid input

    @Test func emptyListIsEmpty() async {
        let library = ImageLibrary()
        defer { library.cleanUp() }
        await #expect(throws: TaskLensError.validationFailed(.emptyContent)) {
            try await library.loader([]).loadPresentation()
        }
        let engine = PresentationEngine()
        let loaded = await engine.load(from: library.loader([]))
        #expect(!loaded)
        #expect(engine.phase == .error(.empty))
    }

    @Test func nonImageDocumentIsUnsupported() async throws {
        let library = ImageLibrary()
        defer { library.cleanUp() }
        let photo = try await library.importImage("Photo", width: 20)
        let text = try await library.service.importData(Data("hello".utf8), filename: "a.txt", contentType: .plainText)

        let engine = PresentationEngine()
        let loaded = await engine.load(from: library.loader([photo.id, text.id]))
        #expect(!loaded)
        #expect(engine.phase == .error(.unsupportedSource))
        #expect(engine.document == nil)
    }

    @Test func unknownImageIsUnreadable() async throws {
        let library = ImageLibrary()
        defer { library.cleanUp() }
        let photo = try await library.importImage("Photo", width: 20)

        await #expect(throws: TaskLensError.self) {
            try await library.loader([photo.id, DocumentID()]).loadPresentation()
        }
        let engine = PresentationEngine()
        let loaded = await engine.load(from: library.loader([photo.id, DocumentID()]))
        #expect(!loaded)
        #expect(engine.phase == .error(.unreadable))
    }

    @Test func corruptedImageIsUnreadable() async throws {
        let library = ImageLibrary()
        defer { library.cleanUp() }
        // The import accepts it by its type; its bytes are not a picture.
        let file = try await library.service.importData(Data("not an image".utf8), filename: "Broken.png", contentType: .png)
        #expect(file.kind == .image)

        await #expect(throws: TaskLensError.persistenceFailed(operation: .read, details: "The image could not be opened.")) {
            try await library.loader([file.id]).loadPresentation()
        }
        let engine = PresentationEngine()
        let loaded = await engine.load(from: library.loader([file.id]))
        #expect(!loaded)
        #expect(engine.phase == .error(.unreadable))
    }

    // MARK: Engine

    @Test func loadedImagesDriveTheEngine() async throws {
        let library = ImageLibrary()
        defer { library.cleanUp() }
        var images: [Document] = []
        for index in 0..<5 { images.append(try await library.importImage("P\(index)", width: 10 + index)) }
        let engine = PresentationEngine()

        let loaded = await engine.load(from: library.loader(images.map(\.id)))
        #expect(loaded)
        #expect(engine.phase == .ready)
        #expect(engine.currentSlide == 0)
        #expect(engine.currentSlideContent?.source == .image(images[0].id))

        let backAtFirst = engine.previous()
        #expect(!backAtFirst)
        let forward = engine.next()
        #expect(forward)
        #expect(engine.currentSlideContent?.source == .image(images[1].id))
        let back = engine.previous()
        #expect(back)
        #expect(engine.currentSlide == 0)

        let jumped = engine.goToSlide(4)
        #expect(jumped)
        #expect(engine.state.displaySlideNumber == 5)
        let pastLast = engine.next(), outOfRange = engine.goToSlide(5)
        #expect(!pastLast && !outOfRange)
        #expect(engine.currentSlideContent?.source == .image(images[4].id))

        engine.play()
        let stopped = engine.stop()
        #expect(stopped)
        #expect(engine.phase == .ready)
        #expect(engine.currentSlide == 4)
    }

    // MARK: Separation

    @Test func presentingLeavesStoredDocumentsUnchanged() async throws {
        let library = ImageLibrary()
        defer { library.cleanUp() }
        let service = library.service
        let pdf = try await service.importData(Data("%PDF-1.4".utf8), filename: "Notes.pdf", contentType: .pdf)
        _ = try await service.setLastReadPage(pdf.id, page: 19)
        var images: [Document] = []
        for index in 0..<4 { images.append(try await library.importImage("P\(index)", width: 10 + index)) }
        let before = try await service.documents(in: nil)

        let engine = PresentationEngine()
        await engine.load(from: library.loader(images.map(\.id)), startAt: 2)
        engine.next()
        engine.goToSlide(0)

        // Every stored document, the PDF's reading page included, is as it was.
        #expect(try await service.documents(in: nil) == before)
        #expect(try await service.document(id: pdf.id).lastReadPage == 19)
        #expect(engine.currentSlide == 0)
    }
}
