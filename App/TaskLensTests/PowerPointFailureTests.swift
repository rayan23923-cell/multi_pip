import Foundation
import PresentationFeature
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import TLNavigation
@_spi(Testing) import TLPowerPointRendering

/// A9.5.1: why a PowerPoint file fails, classified from the real renderer and
/// cache. Every failure leaves no cache and no staging folder behind.
@MainActor
@Suite("PowerPoint failure classification", .serialized)
struct PowerPointFailureAppTests {
    private let repositories = Repositories.inMemory()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TaskLensPowerPointFailure-\(UUID().uuidString)", isDirectory: true)
    private var documents: DocumentService { DocumentService(documents: repositories.documents, filesDirectory: directory) }
    private var sessions: PresentationSessionStore { PresentationSessionStore(sessions: repositories.presentationSessions) }

    // MARK: Source

    @Test func aCorruptFileIsInvalidAndNeverRendered() async throws {
        defer { cleanUp() }
        let cache = PowerPointSlideCache(documentService: documents)
        let deck = try await importFixture("scale-3")
        // Damaged after import: the stored file is cut short.
        let file = documents.fileURL(for: deck)
        try Data(contentsOf: file).dropLast(200).write(to: file)
        try await expectFailure(.invalidSource, deck, cache)
        #expect(cache.events.renders == 0, "The import check rejects it first")
    }

    @Test func anInvalidPresentationInsideAValidPackageIsInvalid() async throws {
        defer { cleanUp() }
        let cache = PowerPointSlideCache(documentService: documents)
        let data = MiniZip.make([("[Content_Types].xml", "<Types/>"), ("ppt/presentation.xml", "this is not XML <<<")])
        let deck = try await documents.importData(data, filename: "Broken.pptx", contentType: nil)
        try await expectFailure(.invalidSource, deck, cache)
    }

    @Test func aFileTheImportCheckRejectsIsNeverRendered() async throws {
        defer { cleanUp() }
        let cache = PowerPointSlideCache(documentService: documents)
        let deck = try await importFixture("scale-3")
        // Replaced after import by a package with a macro project (A9.1 rejects it).
        let macro = MiniZip.make([("[Content_Types].xml", "<Types/>"), ("ppt/presentation.xml", "<p:presentation/>"),
                                  ("ppt/vbaProject.bin", "macro")])
        try macro.write(to: documents.fileURL(for: deck))
        try await expectFailure(.securityRejected, deck, cache)
        #expect(cache.events.renders == 0)
    }

    @Test func aMissingSlideIsAMissingResource() async throws {
        defer { cleanUp() }
        let cache = PowerPointSlideCache(documentService: documents)
        try await expectFailure(.missingResource, try await importFixture("missing-slide"), cache)
    }

    // MARK: Speaker notes

    @Test func speakerNotesAreNamedWhenTheRendererIdentifiesThem() async throws {
        defer { cleanUp() }
        let cache = PowerPointSlideCache(documentService: documents)
        let deck = try await importFixture("audit-with-notes")
        #expect(try PowerPointDeck.read(contentsOf: documents.fileURL(for: deck)).hasSpeakerNotes)
        try await expectFailure(.speakerNotesUnsupported, deck, cache)
        print("PPTX A951 notes webKit=\(PowerPointRenderer.lastFailureDetail ?? "-")")
    }

    // MARK: Rendering

    @Test func aWebViewFailureIsARenderingFailure() async throws {
        defer { cleanUp() }
        var options = PowerPointRenderer.Options()
        options.simulatesWebViewFailure = true
        let cache = PowerPointSlideCache(documentService: documents, options: options)
        try await expectFailure(.renderingFailed, try await importFixture("scale-3"), cache)
    }

    @Test func aRenderPastItsTimeLimitTimesOut() async throws {
        defer { cleanUp() }
        let cache = PowerPointSlideCache(documentService: documents, options: .init(timeout: .milliseconds(1)))
        try await expectFailure(.timeout, try await importFixture("scale-10"), cache)
    }

    @Test func slidesThatCannotBeStoredAreAStorageFailure() async throws {
        defer { cleanUp() }
        let cache = PowerPointSlideCache(documentService: documents)
        let deck = try await importFixture("scale-1")
        // A file where the document's generated folder should be.
        let generated = documents.generatedFilesDirectory(for: deck.id)
        try FileManager.default.createDirectory(at: generated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: generated)
        await #expect(throws: PowerPointFailure.storageFailure) {
            try await cache.slideImages(for: deck, fileURL: documents.fileURL(for: deck))
        }
        #expect(try Data(contentsOf: generated) == Data("in the way".utf8))
    }

    // MARK: Cancellation

    @Test func leavingDuringTheRenderCancelsItAndLeavesNothing() async throws {
        defer { cleanUp() }
        let cache = PowerPointSlideCache(documentService: documents)
        let deck = try await importFixture("scale-50")
        let file = documents.fileURL(for: deck)
        let open = Task { try await cache.slideImages(for: deck, fileURL: file) }
        try await Task.sleep(for: .milliseconds(500))
        open.cancel()
        await #expect(throws: PowerPointFailure.cancelled) { try await open.value }
        // The render stops: nothing is left, and opening again renders from scratch.
        #expect(await waitUntil { (try? listing(generated(deck))) ?? [] == [] })
        let slides = try await cache.slideImages(for: deck, fileURL: file)
        #expect(slides.count == 50)
        #expect(cache.events.renders == 2)
    }

    @Test func oneOpenLeavingDoesNotCancelAnotherWaitingForTheSameRender() async throws {
        defer { cleanUp() }
        let cache = PowerPointSlideCache(documentService: documents)
        let deck = try await importFixture("scale-10")
        let file = documents.fileURL(for: deck)
        let leaving = Task { try await cache.slideImages(for: deck, fileURL: file) }
        let staying = Task { try await cache.slideImages(for: deck, fileURL: file) }
        try await Task.sleep(for: .milliseconds(300))
        leaving.cancel()
        await #expect(throws: PowerPointFailure.cancelled) { try await leaving.value }
        #expect(try await staying.value.count == 10)
        #expect(cache.events.renders == 1)
    }

    // MARK: Presentation

    @Test func thePresentationKeepsTheCategoryAndItsPhase() async throws {
        defer { cleanUp() }
        let cache = PowerPointSlideCache(documentService: documents)
        let notes = try await importFixture("audit-with-notes")
        let failed = await open(notes, cache)
        #expect(failed.powerPointFailure == .speakerNotesUnsupported)
        #expect(failed.phase == .error(.unsupportedSource), "Unchanged from A9.3")
        #expect(failed.slideCount == 0, "No partial presentation")
        #expect(try await sessions.allSessions().isEmpty)

        let missing = await open(try await importFixture("missing-slide"), cache)
        #expect(missing.powerPointFailure == .missingResource)
        #expect(missing.phase == .error(.unreadable))

        let fine = await open(try await importFixture("scale-1"), cache)
        #expect(fine.powerPointFailure == nil)
        #expect(fine.slideCount == 1)
        fine.didLeave()
    }

    @Test func slideImagesThatNoLongerReadAreACorruptedCache() async throws {
        defer { cleanUp() }
        let deck = try await importFixture("scale-1")
        let model = await open(deck, UnreadableSlides(documents: documents))
        #expect(model.powerPointFailure == .corruptedCache)
        #expect(model.phase == .error(.unreadable))
    }

    // MARK: Helpers

    private func expectFailure(_ expected: PowerPointFailure, _ deck: Document, _ cache: PowerPointSlideCache,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        do {
            _ = try await cache.slideImages(for: deck, fileURL: documents.fileURL(for: deck))
            Issue.record("Expected \(expected)", sourceLocation: sourceLocation)
        } catch {
            #expect(error as? PowerPointFailure == expected, "\(error)", sourceLocation: sourceLocation)
        }
        #expect((try? listing(generated(deck))) ?? [] == [], "No cache or staging left", sourceLocation: sourceLocation)
    }

    private func open(_ deck: Document, _ slides: any PowerPointSlideImageProviding) async -> PresentationModel {
        let model = PresentationModel(request: .powerPoint(deck.id), documentService: documents, sessionStore: sessions,
                                      slideImages: slides)
        await model.load()
        return model
    }

    private func importFixture(_ name: String) async throws -> Document {
        let bundle = Bundle(for: FailureFixtureToken.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "pptx")
            ?? bundle.url(forResource: name, withExtension: "pptx", subdirectory: "Fixtures"), "fixture \(name)")
        return try await documents.importFile(at: url, filename: "\(name).pptx")
    }

    private func generated(_ deck: Document) -> URL { documents.generatedFilesDirectory(for: deck.id) }

    private func listing(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

/// "Rendered" slides whose file is not an image, as if the cache was damaged after it was checked.
private struct UnreadableSlides: PowerPointSlideImageProviding {
    let documents: DocumentService

    func slideImages(for document: Document, fileURL: URL) async throws -> [URL] {
        let url = slideImage(for: document.id, index: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: url)
        return [url]
    }

    func slideImage(for documentID: DocumentID, index: Int) -> URL {
        documents.generatedFilesDirectory(for: documentID).appendingPathComponent("Test/slide-\(index + 1).png")
    }
}

private final class FailureFixtureToken {}
