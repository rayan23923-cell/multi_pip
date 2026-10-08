import Foundation
import PresentationFeature
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import TLNavigation
@_spi(Testing) import TLPowerPointRendering
import UIKit

/// A9.5.5: A9.1–A9.5.4 working together, end to end, in the app with the real
/// import check, renderer, cache, classification, failure screen model, PDF
/// fallback, engine, Auto Play and sessions, over a file-backed store (a
/// "launch" is everything built fresh over the same folder).
@MainActor
@Suite("Presentation integration", .serialized)
struct PresentationIntegrationTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TaskLensPresentationIntegration-\(UUID().uuidString)", isDirectory: true)

    private static let quick: PresentationAutoPlayer.Sleep = { _ in try await Task.sleep(for: .milliseconds(5)) }
    private static let neverEnds: PresentationAutoPlayer.Sleep = { _ in try await Task.sleep(for: .seconds(3600)) }

    @MainActor
    private struct Launch {
        let documents: DocumentService
        let sessions: PresentationSessionStore
        let cache: PowerPointSlideCache

        init(root: URL, options: PowerPointRenderer.Options = .init()) throws {
            let location = StoreLocation(rootURL: root)
            let repositories = try Repositories.fileBacked(at: location)
            documents = DocumentService(documents: repositories.documents, filesDirectory: location.filesDirectory)
            sessions = PresentationSessionStore(sessions: repositories.presentationSessions)
            cache = PowerPointSlideCache(documentService: documents, options: options)
        }

        func open(_ request: PresentationRequest, sleep: PresentationAutoPlayer.Sleep? = nil,
                  slides: (any PowerPointSlideImageProviding)? = nil, onImportPDF: (@MainActor () -> Void)? = {}) async -> PresentationModel {
            let model = PresentationModel(request: request, documentService: documents, sessionStore: sessions,
                                          slideImages: slides ?? cache, autoPlaySleep: sleep, onImportPDF: onImportPDF)
            await model.load()
            return model
        }

        func generated(_ id: DocumentID) -> URL { documents.generatedFilesDirectory(for: id) }
    }

    // MARK: PowerPoint happy path

    /// Import → check → render → cache → present → navigate → Auto Play → leave → reopen from the cache, restored.
    @Test func powerPointLifecycleFromImportToRestoredSession() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-50", into: app)
        #expect(deck.kind == .powerpoint)

        let model = await app.open(.powerPoint(deck.id), sleep: Self.neverEnds)
        #expect(model.phase == .ready)
        #expect(model.failureContent == nil)
        #expect(model.slideCount == 50 && model.slideNumber == 1)
        #expect(app.cache.events.renders == 1 && app.cache.events.hits == 0)
        model.next()
        #expect(model.slideNumber == 2)
        model.previous()
        #expect(model.slideNumber == 1)
        model.goToSlide(number: 12)
        #expect(model.slideNumber == 12)
        let shown = try #require(model.currentSlide?.source)
        #expect(await model.image(for: shown, maxPixelSize: 828) != nil, "Slide 12's image is drawn")

        model.setAutoPlayInterval(15)
        model.toggleAutoPlay()
        #expect(model.autoPlayButton == .pause && model.isAutoPlaying)
        model.toggleAutoPlay()
        #expect(model.autoPlayButton == .resume && !model.isAutoPlaying)
        model.toggleAutoPlay()
        #expect(model.autoPlayButton == .pause)
        model.stopAutoPlay()
        #expect(model.autoPlayButton == .start && !model.isAutoPlayActive)
        #expect(model.slideNumber == 12)
        model.didLeave()
        await model.saveSession()

        let restarted = try Launch(root: root)
        let reopened = await restarted.open(.powerPoint(deck.id), sleep: Self.neverEnds)
        #expect(reopened.slideNumber == 12, "Session restored")
        #expect(reopened.autoPlayInterval == 15)
        #expect(reopened.autoPlayButton == .start, "Auto Play never starts on its own")
        #expect(restarted.cache.events.renders == 0 && restarted.cache.events.hits == 1, "Opened from the cache")
        #expect(try await restarted.documents.document(id: deck.id).lastReadPage == nil)
        reopened.didLeave()
    }

    // MARK: Failure → classification → screen → Try Again / Import PDF

    /// Every category the real pipeline produces reaches the failure screen with its own content.
    @Test func realFailuresReachTheirFailureScreens() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)

        let invalid = try await importFixture("scale-3", into: app)
        let invalidFile = app.documents.fileURL(for: invalid)
        try Data(contentsOf: invalidFile).dropLast(200).write(to: invalidFile)
        let rejected = try await importFixture("scale-3", into: app)
        try PowerPointRendererTests.hostileFiles[1].1.write(to: app.documents.fileURL(for: rejected))
        let notes = try await importFixture("audit-with-notes", into: app)
        let missing = try await importFixture("missing-slide", into: app)
        let blocked = try await importFixture("scale-1", into: app)
        try FileManager.default.createDirectory(at: app.generated(blocked.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: app.generated(blocked.id))

        var web = PowerPointRenderer.Options()
        web.simulatesWebViewFailure = true
        let webFailure = PowerPointSlideCache(documentService: app.documents, options: web)
        let slow = PowerPointSlideCache(documentService: app.documents, options: .init(timeout: .milliseconds(1)))
        let failing = try await importFixture("scale-3", into: app)

        let cases: [(Document, (any PowerPointSlideImageProviding)?, PowerPointFailure)] = [
            (invalid, nil, .invalidSource), (rejected, nil, .securityRejected), (notes, nil, .speakerNotesUnsupported),
            (missing, nil, .missingResource), (blocked, nil, .storageFailure),
            (failing, webFailure, .renderingFailed), (failing, slow, .timeout),
        ]
        for (deck, slides, expected) in cases {
            let model = await app.open(.powerPoint(deck.id), slides: slides)
            #expect(model.powerPointFailure == expected, "\(deck.title)")
            #expect(model.failureContent == PowerPointFailureContent(expected), "\(expected): its own screen")
            #expect(model.slideCount == 0 && !model.hasSlides, "\(expected): no partial presentation")
            model.didLeave()
            await model.saveSession()
        }
        #expect(try await app.sessions.allSessions().isEmpty, "No session for any failure")
        for deck in [invalid, rejected, notes, missing, failing] {
            #expect(try listing(app.generated(deck.id)).isEmpty, "\(deck.title): no cache left")
        }

        // Cancelled: no screen at all.
        let big = try await importFixture("scale-50", into: app)
        let cancelled = PresentationModel(request: .powerPoint(big.id), documentService: app.documents,
                                          sessionStore: app.sessions, slideImages: app.cache, onImportPDF: {})
        let load = Task { await cancelled.load() }
        try await Task.sleep(for: .milliseconds(400))
        load.cancel()
        await load.value
        #expect(cancelled.wasCancelled && cancelled.failureContent == nil)
        #expect(await waitUntil { !PowerPointSlideCache.isRendering(big.id) })
        #expect(try listing(app.generated(big.id)).isEmpty)
    }

    /// Render failure → screen → Try Again → the same pipeline renders → presentation, cache and session.
    @Test func tryAgainAfterARealFailureOpensThePresentation() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-10", into: app)
        try FileManager.default.createDirectory(at: app.generated(deck.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: app.generated(deck.id))
        let model = await app.open(.powerPoint(deck.id), sleep: Self.quick)
        #expect(model.failureContent?.canRetry == true)

        try FileManager.default.removeItem(at: app.generated(deck.id))
        await model.retry()
        #expect(model.phase == .ready && model.slideCount == 10)
        model.goToSlide(number: 8)
        model.toggleAutoPlay()
        #expect(await waitUntil { model.phase == .completed })
        #expect(model.slideNumber == 10)
        model.goToSlide(number: 6)
        model.didLeave()
        await model.saveSession()
        #expect(await app.sessions.session(for: .powerPoint(deck.id))?.currentSlide == 5)
        #expect(try listing(app.cache.slidesDirectory(for: deck.id)).count == 11, "Ten slides and cache.json")
    }

    /// Speaker notes → screen → Import PDF → a PDF the person picked → an ordinary PDF presentation.
    @Test func speakerNotesFallBackToAPickedPDF() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let reading = try await app.documents.importData(pdf(pages: 30), filename: "Reading.pdf", contentType: .pdf)
        _ = try await app.documents.setLastReadPage(reading.id, page: 19)
        let notes = try await importFixture("audit-with-notes", into: app)

        let fallback = PDFFallbackImport(failedPresentation: notes.id, documentService: app.documents)
        let failed = await app.open(.powerPoint(notes.id), onImportPDF: { fallback.choosePDF() })
        #expect(failed.failureContent == PowerPointFailureContent(.speakerNotesUnsupported))
        failed.importPDF()
        #expect(fallback.isChoosing)
        #expect(await fallback.picked(nil) == nil, "Cancelled picker")
        #expect(failed.failureContent != nil, "The screen stays")

        failed.importPDF()
        let picked = root.appendingPathComponent("Exported.pdf")
        try pdf(pages: 15).write(to: picked)
        let id = try #require(await fallback.picked(picked))
        let presented = await app.open(.pdf(id), sleep: Self.neverEnds)
        #expect(presented.slideCount == 15)
        presented.goToSlide(number: 12)
        presented.didLeave()
        await presented.saveSession()

        #expect(try await app.documents.document(id: id).kind == .pdf)
        #expect(await app.sessions.session(for: .pdf(id))?.currentSlide == 11)
        #expect(await app.sessions.session(for: .powerPoint(notes.id)) == nil)
        #expect(!FileManager.default.fileExists(atPath: app.generated(id).path), "No PowerPoint cache for the PDF")
        #expect(try await app.documents.document(id: reading.id).lastReadPage == 19)
        #expect(try await app.documents.document(id: id).lastReadPage == nil)
    }

    // MARK: Several documents

    /// PowerPoint A and B, PDF A and B, image sets A and B: each keeps its own slide, interval and cache.
    @Test func everyPresentationKeepsItsOwnState() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let pptA = try await importFixture("scale-3", into: app)
        let pptB = try await importFixture("scale-10", into: app)
        let pdfA = try await app.documents.importData(pdf(pages: 5), filename: "A.pdf", contentType: .pdf)
        let pdfB = try await app.documents.importData(pdf(pages: 20), filename: "B.pdf", contentType: .pdf)
        _ = try await app.documents.setLastReadPage(pdfA.id, page: 3)
        var images: [DocumentID] = []
        for index in 0..<4 {
            images.append(try await app.documents.importData(png(index), filename: "Image \(index).png", contentType: .png).id)
        }
        let requests: [(PresentationRequest, Int, Int)] = [
            (.powerPoint(pptA.id), 2, 5), (.powerPoint(pptB.id), 9, 10), (.pdf(pdfA.id), 4, 15),
            (.pdf(pdfB.id), 17, 30), (.images(Array(images[0..<2])), 2, 60), (.images(Array(images[2..<4])), 1, 5),
        ]
        for (request, slide, interval) in requests {
            let model = await app.open(request, sleep: Self.neverEnds)
            #expect(model.phase == .ready, "\(request)")
            model.goToSlide(number: slide)
            model.setAutoPlayInterval(interval)
            model.didLeave()
            await model.saveSession()
        }
        let restarted = try Launch(root: root)
        for (request, slide, interval) in requests {
            let model = await restarted.open(request, sleep: Self.neverEnds)
            #expect(model.slideNumber == slide, "\(request)")
            #expect(model.autoPlayInterval == interval, "\(request)")
            model.didLeave()
        }
        #expect(try await restarted.sessions.allSessions().count == requests.count)
        #expect(restarted.cache.events.renders == 0, "Both decks open from their own caches")
        #expect(try await restarted.documents.document(id: pdfA.id).lastReadPage == 3, "The reader's page is separate")
        #expect(try await restarted.documents.document(id: pdfB.id).lastReadPage == nil)
    }

    /// The same deck imported twice is two documents, as for any file, each with its own cache and session.
    @Test func aDeckImportedTwiceFollowsTheLibraryRules() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let first = try await importFixture("scale-3", into: app)
        let second = try await importFixture("scale-3", into: app)
        #expect(first.id != second.id)
        let one = await app.open(.powerPoint(first.id))
        one.goToSlide(number: 3)
        one.didLeave()
        await one.saveSession()
        let two = await app.open(.powerPoint(second.id))
        #expect(two.slideNumber == 1, "Not the other copy's slide")
        two.didLeave()
        #expect(app.cache.events.renders == 2)
        #expect(app.cache.slidesDirectory(for: first.id) != app.cache.slidesDirectory(for: second.id))
    }

    // MARK: Security

    /// Hostile packages: the import check refuses what it can see in the ZIP
    /// directory; swapped in after import, the same check refuses them again
    /// before rendering. A package that only its XML gives away (an entity) is
    /// refused when the deck is read, before WebKit loads anything (A9.2).
    @Test(arguments: PowerPointRendererTests.hostileFiles.indices)
    func hostilePackagesNeverReachWebKit(index: Int) async throws {
        defer { cleanUp() }
        let (label, data) = PowerPointRendererTests.hostileFiles[index]
        let app = try Launch(root: root)
        let seenByThePackageCheck = PowerPointPackage.rejection(of: data) != nil
        if seenByThePackageCheck {
            await #expect(throws: TaskLensError.self, "\(label) is refused at import") {
                try await app.documents.importData(data, filename: "\(label).pptx", contentType: nil)
            }
        }
        let deck = try await importFixture("scale-1", into: app)
        try data.write(to: app.documents.fileURL(for: deck))
        let model = await app.open(.powerPoint(deck.id))
        let failure = try #require(model.powerPointFailure, "\(label)")
        #expect([PowerPointFailure.securityRejected, .invalidSource].contains(failure), "\(label): \(failure)")
        #expect(model.failureContent?.canImportPDF == false)
        if seenByThePackageCheck {
            #expect(app.cache.events.renders == 0, "\(label): never rendered")
        }
        #expect(try listing(app.generated(deck.id)).isEmpty, "\(label): nothing cached")
        #expect(try await app.sessions.allSessions().isEmpty)
        if failure == .securityRejected {
            #expect(model.failureContent?.actions == [.cancel], "No retry loop")
        }
        print("PPTX A955 hostile \(label): \(failure) packageCheck=\(seenByThePackageCheck) renders=\(app.cache.events.renders)")
    }

    // MARK: Helpers

    private func pdf(pages: Int) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 792, height: 612)).pdfData { context in
            for page in 1...pages {
                context.beginPage()
                "Page \(page)".draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 28)])
            }
        }
    }

    private func png(_ index: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 160 + index, height: 90), format: format).pngData { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160 + index, height: 90))
        }
    }

    private func listing(_ folder: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder)
        guard isFolder.boolValue else { return ["(file)"] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func importFixture(_ name: String, into app: Launch) async throws -> Document {
        let bundle = Bundle(for: IntegrationFixtureToken.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "pptx")
            ?? bundle.url(forResource: name, withExtension: "pptx", subdirectory: "Fixtures"), "fixture \(name)")
        return try await app.documents.importFile(at: url, filename: "\(name).pptx")
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(180)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private final class IntegrationFixtureToken {}
