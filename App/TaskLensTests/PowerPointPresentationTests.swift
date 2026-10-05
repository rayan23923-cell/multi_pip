import CoreGraphics
import Foundation
import ImageIO
import PresentationFeature
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLNavigation
@_spi(Testing) import TLPowerPointRendering
import UIKit

/// A9.3: imported PowerPoint files presented through the existing presentation
/// model, engine, Auto Play and session, from the slide images the A9.2
/// renderer leaves with the document. Runs in the app so WebKit has a window
/// scene. `PPTX A93` lines carry timings; `PROBEIMG` lines carry what the
/// presentation shows, to check by eye from the log.
@MainActor
@Suite("PowerPoint presentation", .serialized)
struct PowerPointPresentationTests {
    private let repositories = Repositories.inMemory()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TaskLensPowerPointPresentation-\(UUID().uuidString)", isDirectory: true)
    private var documents: DocumentService { DocumentService(documents: repositories.documents, filesDirectory: directory) }
    private var sessions: PresentationSessionStore { PresentationSessionStore(sessions: repositories.presentationSessions) }
    private var cache: PowerPointSlideCache { PowerPointSlideCache(documentService: documents) }

    private static let quick: PresentationAutoPlayer.Sleep = { _ in try await Task.sleep(for: .milliseconds(5)) }
    private static let neverEnds: PresentationAutoPlayer.Sleep = { _ in try await Task.sleep(for: .seconds(3600)) }

    // MARK: Test matrix

    @Test func oneSlideOpensAndShowsItsImage() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("scale-1")
        let model = await open(deck)
        #expect(model.phase == .ready)
        #expect(model.slideCount == 1)
        #expect(model.slideNumber == 1)
        #expect(!model.canGoBack && !model.canGoForward)
        let image = try #require(await shownImage(model))
        #expect(image.width == 1920)
        try await expectSameAsRendered(model, deck: deck)
        model.didLeave()
    }

    @Test func threeSlidesNavigate() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("scale-3")
        let model = await open(deck)
        #expect(model.slideCount == 3)
        model.previous()
        #expect(model.slideNumber == 1)
        model.next()
        model.next()
        #expect(model.slideNumber == 3)
        model.next()
        #expect(model.slideNumber == 3, "No wrap-around")
        model.goToSlide(number: 2)
        #expect(model.slideNumber == 2)
        try await expectSameAsRendered(model, deck: deck)
        model.didLeave()
    }

    @Test func tenSlidesNavigateAutoPlayAndReopen() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("scale-10")
        let model = await open(deck, sleep: Self.quick)
        #expect(model.slideCount == 10)
        model.goToSlide(number: 4)
        model.setAutoPlayInterval(5)
        model.toggleAutoPlay()
        #expect(await waitUntil { model.phase == .completed })
        #expect(model.slideNumber == 10, "Auto Play stops on the last slide")
        model.goToSlide(number: 7)
        await leave(model)

        let reopened = await open(deck, sleep: Self.neverEnds)
        #expect(reopened.slideNumber == 7)
        #expect(reopened.autoPlayInterval == 5)
        #expect(reopened.phase == .ready, "Playback never restarts on its own")
        reopened.toggleAutoPlay()
        reopened.toggleAutoPlay()
        #expect(reopened.phase == .paused)
        reopened.toggleAutoPlay()
        reopened.stopAutoPlay()
        #expect(reopened.phase == .ready)
        #expect(reopened.slideNumber == 7)
        reopened.didLeave()
    }

    @Test func fiftySlidesNavigateAndReopen() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("scale-50")
        let model = await open(deck)
        #expect(model.slideCount == 50)
        model.goToSlide(number: 50)
        #expect(!model.canGoForward)
        model.goToSlide(number: 33)
        model.previous()
        #expect(model.slideNumber == 32)
        await leave(model)
        #expect(await open(deck).slideNumber == 32)
    }

    @Test func hundredSlidesOpenNavigateAndReopenWithoutRendering() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("scale-100")
        let clock = ContinuousClock()
        var started = clock.now
        let model = await open(deck)
        let firstOpen = clock.now - started
        #expect(model.slideCount == 100)
        #expect(model.slideNumber == 1)
        started = clock.now
        for _ in 0..<99 { model.next() }
        #expect(model.slideNumber == 100)
        for _ in 0..<99 { model.previous() }
        #expect(model.slideNumber == 1)
        model.goToSlide(number: 64)
        let navigation = clock.now - started
        let image = try #require(await shownImage(model))
        #expect(image.width == 1920)
        await leave(model)

        let renderedAt = try modificationDates(deck)
        started = clock.now
        let reopened = await open(deck)
        let secondOpen = clock.now - started
        #expect(reopened.slideNumber == 64)
        #expect(try modificationDates(deck) == renderedAt, "Opening again uses the images already rendered")
        #expect(secondOpen < .seconds(5))
        print("PPTX A93 scale-100 firstOpen=\(seconds(firstOpen))s navigation198=\(seconds(navigation))s secondOpen=\(seconds(secondOpen))s")
        reopened.didLeave()
    }

    // MARK: Content

    @Test func everyKindOfContentShowsTheRenderedImage() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("audit-15")
        let model = await open(deck)
        #expect(model.slideCount == 15)
        for number in 1...15 {
            model.goToSlide(number: number)
            try await expectSameAsRendered(model, deck: deck)
        }
        model.didLeave()
    }

    @Test func arabicShowsExactlyTheRenderedImage() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("arabic")
        let model = await open(deck)
        #expect(model.slideCount == 4)
        for number in 1...4 {
            model.goToSlide(number: number)
            try await expectSameAsRendered(model, deck: deck)
            // What the presentation shows for "مرحبا بكم في العرض" (1) and "TaskLens — عرض تقديمي" (2).
            if let shown = await shownImage(model, maxPixelSize: 960) { emit("a93-arabic-\(number)", shown) }
        }
        model.didLeave()
    }

    // MARK: Failures and lifecycle

    @Test func aDeckWithSpeakerNotesFailsCleanly() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("audit-with-notes")
        let model = await open(deck)
        #expect(model.phase == .error(.unsupportedSource))
        #expect(!model.hasSlides)
        #expect(model.slideCount == 0, "No empty or partial presentation")
        #expect(!FileManager.default.fileExists(atPath: cache.slidesDirectory(for: deck.id).path), "Nothing left behind")
        #expect(try await sessions.allSessions().isEmpty, "No session")
        #expect(PowerPointRenderer.liveWebViewCount == 0)
    }

    @Test func aDeckWithAMissingSlideFailsCleanly() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("missing-slide")
        let model = await open(deck)
        #expect(model.phase == .error(.unreadable))
        #expect(model.slideCount == 0)
        #expect(!FileManager.default.fileExists(atPath: cache.slidesDirectory(for: deck.id).path))
        #expect(try await sessions.allSessions().isEmpty)
    }

    @Test func openingTwiceAtOnceRendersOnce() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("scale-3")
        let first = Task { await open(deck) }
        let second = Task { await open(deck) }
        let a = await first.value, b = await second.value
        #expect(a.slideCount == 3 && b.slideCount == 3)
        #expect(PowerPointRenderer.peakWebViewCount <= 1)
        a.didLeave()
        b.didLeave()
    }

    @Test func deletingTheDeckDeletesItsSlideImages() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("scale-3")
        await leave(await open(deck))
        let slides = cache.slidesDirectory(for: deck.id)
        #expect(FileManager.default.fileExists(atPath: slides.path))
        try await documents.delete(deck.id)
        #expect(!FileManager.default.fileExists(atPath: slides.path))
        #expect(!FileManager.default.fileExists(atPath: documents.generatedFilesDirectory(for: deck.id).path))
        let gone = await open(deck)
        #expect(gone.phase == .error(.unreadable))
        #expect(try await sessions.allSessions().isEmpty, "The saved slide goes with it on the next open")
    }

    @Test func aNewScreenSizeRedrawsTheSameSlideWithoutRendering() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("scale-3")
        let model = await open(deck)
        model.goToSlide(number: 2)
        let renderedAt = try modificationDates(deck)
        // Portrait, landscape, portrait on an iPhone 11 (828 × 1792 pixels).
        for longestSide in [1792.0, 1792.0, 828.0, 1792.0] {
            let image = try #require(await shownImage(model, maxPixelSize: longestSide))
            #expect(CGFloat(max(image.width, image.height)) <= longestSide)
            #expect(model.slideNumber == 2)
        }
        #expect(try modificationDates(deck) == renderedAt)
        model.didLeave()
    }

    // MARK: Helpers

    private func open(_ deck: Document, sleep: PresentationAutoPlayer.Sleep? = nil) async -> PresentationModel {
        let model = PresentationModel(request: .powerPoint(deck.id), documentService: documents, sessionStore: sessions,
                                      slideImages: cache, autoPlaySleep: sleep)
        await model.load()
        if case .error = model.phase {
            print("PPTX A93 open failed: \(PowerPointRenderer.lastFailureDetail ?? "-")")
        }
        return model
    }

    private func leave(_ model: PresentationModel) async {
        model.didLeave()
        await model.saveSession()
    }

    private func importFixture(_ name: String) async throws -> Document {
        let bundle = Bundle(for: FixtureToken.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "pptx")
            ?? bundle.url(forResource: name, withExtension: "pptx", subdirectory: "Fixtures"), "fixture \(name)")
        return try await documents.importFile(at: url, filename: "\(name).pptx")
    }

    private func shownImage(_ model: PresentationModel, maxPixelSize: CGFloat = 1920) async -> CGImage? {
        guard let source = model.currentSlide?.source else { return nil }
        return await model.image(for: source, maxPixelSize: maxPixelSize)
    }

    /// The slide on screen is the renderer's PNG for that slide, unchanged.
    private func expectSameAsRendered(_ model: PresentationModel, deck: Document,
                                      sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let index = model.engine.currentSlide
        #expect(model.currentSlide?.source == .renderedImage(deck.id, index: index), sourceLocation: sourceLocation)
        let file = cache.slideImage(for: deck.id, index: index)
        #expect(file.lastPathComponent == String(format: "slide-%03d.png", index + 1), sourceLocation: sourceLocation)
        let rendered = try #require(CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) },
                                    sourceLocation: sourceLocation)
        let shown = try #require(await shownImage(model), sourceLocation: sourceLocation)
        #expect(shown.width == rendered.width && shown.height == rendered.height, "slide \(index + 1)", sourceLocation: sourceLocation)
        #expect(samples(shown) == samples(rendered), "slide \(index + 1) pixels", sourceLocation: sourceLocation)
    }

    /// Colors on a 12 × 12 grid.
    private func samples(_ image: CGImage) -> [UInt32] {
        let size = 12
        var pixels = [UInt32](repeating: 0, count: size * size)
        pixels.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        return pixels
    }

    private func modificationDates(_ deck: Document) throws -> [Date] {
        let folder = cache.slidesDirectory(for: deck.id)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private func seconds(_ duration: Duration) -> String {
        String(format: "%.2f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    /// Prints a JPEG of the image, base64 in 8,000-character lines.
    private func emit(_ name: String, _ image: CGImage) {
        guard let encoded = UIImage(cgImage: image).jpegData(compressionQuality: 0.7)?.base64EncodedString() else { return }
        let parts = stride(from: 0, to: encoded.count, by: 8000).map { start in
            let from = encoded.index(encoded.startIndex, offsetBy: start)
            return String(encoded[from..<encoded.index(from, offsetBy: min(8000, encoded.count - start))])
        }
        for (index, part) in parts.enumerated() { print("PROBEIMG \(name) \(index)/\(parts.count) \(part)") }
    }
}

private final class FixtureToken {}
