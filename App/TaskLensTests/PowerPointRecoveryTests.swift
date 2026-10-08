import Foundation
import PresentationFeature
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import TLNavigation
@_spi(Testing) import TLPowerPointRendering

/// A9.5.4: Try Again, recovery and cleanup with the real import check,
/// renderer, cache and classification. Every test runs over a file-backed
/// store, so a "launch" is everything built fresh over the same folder, as
/// when the app starts again. Transient failures are real ones: slides that
/// can't be stored (a file in the way), a render past its time limit, and a
/// render the person leaves.
@MainActor
@Suite("PowerPoint recovery", .serialized)
struct PowerPointRecoveryTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TaskLensPowerPointRecovery-\(UUID().uuidString)", isDirectory: true)

    /// One run of the app over `root`.
    @MainActor
    private struct Launch {
        let documents: DocumentService
        let sessions: PresentationSessionStore
        let cache: PowerPointSlideCache

        init(root: URL, timeout: Duration? = nil) throws {
            let location = StoreLocation(rootURL: root)
            let repositories = try Repositories.fileBacked(at: location)
            documents = DocumentService(documents: repositories.documents, filesDirectory: location.filesDirectory)
            sessions = PresentationSessionStore(sessions: repositories.presentationSessions)
            var options = PowerPointRenderer.Options()
            if let timeout { options.timeout = timeout }
            cache = PowerPointSlideCache(documentService: documents, options: options)
        }

        func model(_ deck: Document, slides: (any PowerPointSlideImageProviding)? = nil,
                   sleep: PresentationAutoPlayer.Sleep? = nil) -> PresentationModel {
            PresentationModel(request: .powerPoint(deck.id), documentService: documents, sessionStore: sessions,
                              slideImages: slides ?? cache, autoPlaySleep: sleep, onImportPDF: {})
        }

        func open(_ deck: Document, slides: (any PowerPointSlideImageProviding)? = nil,
                  sleep: PresentationAutoPlayer.Sleep? = nil) async -> PresentationModel {
            let model = model(deck, slides: slides, sleep: sleep)
            await model.load()
            return model
        }

        func generated(_ deck: Document) -> URL { documents.generatedFilesDirectory(for: deck.id) }
        func slides(_ deck: Document) -> URL { cache.slidesDirectory(for: deck.id) }
    }

    // MARK: Retry

    /// 1, 22, 23, 24: a real storage failure, then Try Again succeeds once the
    /// obstacle is gone, through the same model, cache and renderer.
    @Test func failureThenTryAgainSucceedsAndPresentsNormally() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-3", into: app)
        try blockGeneratedFolder(deck, app)

        let model = app.model(deck, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
        await model.load()
        #expect(model.powerPointFailure == .storageFailure)
        #expect(model.failureContent?.canRetry == true)
        #expect(model.slideCount == 0)
        #expect(try await app.sessions.allSessions().isEmpty)

        try FileManager.default.removeItem(at: app.generated(deck))
        await model.retry()
        #expect(model.failureContent == nil, "The failure screen is gone")
        #expect(model.powerPointFailure == nil)
        #expect(model.phase == .ready)
        #expect(model.slideCount == 3, "Every slide")
        try expectValidCache(app, deck, slides: 3)
        #expect(app.cache.events.renders == 2, "One render for the failed attempt, one for Try Again")

        // Normal navigation, auto play and session.
        model.next()
        #expect(model.slideNumber == 2)
        model.goToSlide(number: 3)
        #expect(model.slideNumber == 3)
        model.goToSlide(number: 1)
        model.toggleAutoPlay()
        #expect(await waitUntil { model.phase == .completed })
        #expect(model.slideNumber == 3)
        model.goToSlide(number: 2)
        model.didLeave()
        await model.saveSession()
        #expect(await app.sessions.session(for: .powerPoint(deck.id))?.currentSlide == 1)

        let reopened = await app.open(deck)
        #expect(reopened.slideNumber == 2)
        #expect(app.cache.events.renders == 2 && app.cache.events.hits == 1, "The retried render is the cache")
        reopened.didLeave()
    }

    /// 2, 4: Try Again on a failure that happens again: one fresh render per
    /// tap, the same category, nothing left behind and nothing automatic.
    @Test func failureThenTryAgainFailsAgainWithOneFreshAttemptPerTap() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("missing-slide", into: app)
        let model = await app.open(deck)
        #expect(model.powerPointFailure == .missingResource)
        #expect(app.cache.events.renders == 1)
        try await Task.sleep(for: .seconds(1))
        #expect(app.cache.events.renders == 1, "Nothing retries on its own")

        for attempt in 2...3 {
            await model.retry()
            #expect(model.powerPointFailure == .missingResource)
            #expect(model.failureContent?.canRetry == true)
            #expect(model.slideCount == 0)
            #expect(app.cache.events.renders == attempt, "One render per Try Again")
            #expect(try listing(app.generated(deck)).isEmpty, "No cache or staging folder")
        }
        try await Task.sleep(for: .seconds(1))
        #expect(app.cache.events.renders == 3)
        #expect(try await app.sessions.allSessions().isEmpty)
    }

    /// 3, 11 (security): permanent failures offer no Try Again, and a retry call
    /// changes nothing: no second check, no render.
    @Test func permanentFailuresAreNeverRetried() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let notes = try await importFixture("audit-with-notes", into: app)
        let rejected = try await importFixture("scale-3", into: app)
        try MiniZip.make([("[Content_Types].xml", "<Types/>"), ("ppt/presentation.xml", "<p:presentation/>"),
                          ("ppt/vbaProject.bin", "macro")]).write(to: app.documents.fileURL(for: rejected))
        let invalid = try await importFixture("scale-3", into: app)
        let file = app.documents.fileURL(for: invalid)
        try Data(contentsOf: file).dropLast(200).write(to: file)

        for (deck, expected) in [(notes, PowerPointFailure.speakerNotesUnsupported), (rejected, .securityRejected)] {
            let counting = CountingSlides(app.cache)
            let model = await app.open(deck, slides: counting)
            #expect(model.powerPointFailure == expected)
            #expect(model.failureContent?.canRetry == false, "\(expected): no Try Again")
            await model.retry()
            await model.retry()
            #expect(counting.calls == 1, "\(expected): never attempted again")
            #expect(model.powerPointFailure == expected)
            #expect(try listing(app.generated(deck)).isEmpty)
        }
        #expect(app.cache.events.renders == 1, "Only the notes deck reached the renderer; the rejected one never did")

        // Invalid source offers Try Again (A9.5.2); each tap is one bounded check that fails the same way.
        let counting = CountingSlides(app.cache)
        let model = await app.open(invalid, slides: counting)
        #expect(model.powerPointFailure == .invalidSource)
        await model.retry()
        #expect(counting.calls == 2)
        #expect(model.powerPointFailure == .invalidSource)
        #expect(app.cache.events.renders == 1, "Never rendered")
        #expect(try listing(app.generated(invalid)).isEmpty)
        #expect(try await app.sessions.allSessions().isEmpty)
    }

    // MARK: Timeout

    /// 13: a render past its time limit leaves no cache, staging or renderer
    /// folder, stays `timeout`, and the next attempt renders normally.
    @Test func timeoutCleansUpAndTheNextAttemptSucceeds() async throws {
        defer { cleanUp() }
        let started = Date()
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-10", into: app)
        let quick = PowerPointSlideCache(documentService: app.documents, options: .init(timeout: .milliseconds(300)))
        let model = await app.open(deck, slides: SwitchingSlides([quick, app.cache]))
        #expect(model.powerPointFailure == .timeout)
        #expect(model.failureContent?.canRetry == true)
        #expect(try listing(app.generated(deck)).isEmpty, "No partial cache")
        #expect(await waitUntil { rendererFolders(since: started).isEmpty }, "No renderer work folder")

        await model.retry()
        #expect(model.phase == .ready)
        #expect(model.slideCount == 10)
        try expectValidCache(app, deck, slides: 10)
        model.didLeave()
    }

    // MARK: Cancellation

    /// 12, 15, 17: leaving during the render shows nothing, saves no session,
    /// leaves no cache or temporary folder, and opening again starts afresh.
    @Test func leavingDuringTheRenderLeavesNothingAndOpeningAgainWorks() async throws {
        defer { cleanUp() }
        let started = Date()
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-50", into: app)
        let model = app.model(deck)
        let load = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(500))
        load.cancel()
        await load.value
        #expect(model.wasCancelled)
        #expect(model.failureContent == nil, "No failure screen for leaving")
        model.didLeave()
        await model.saveSession()
        #expect(try await app.sessions.allSessions().isEmpty, "No session")
        #expect(await waitUntil { !PowerPointSlideCache.isRendering(deck.id) })
        #expect(try listing(app.generated(deck)).isEmpty, "No partial cache or staging folder")
        #expect(await waitUntil { rendererFolders(since: started).isEmpty })

        let again = await app.open(deck)
        #expect(again.slideCount == 50)
        try expectValidCache(app, deck, slides: 50)
        again.didLeave()
    }

    /// 16, 7: a valid cache is never touched by a cancelled open of the same
    /// deck, nor by another deck's failed or cancelled render.
    @Test func aValidCacheSurvivesCancelledAndFailedRenders() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-3", into: app)
        await app.open(deck).didLeave()
        let before = try fingerprint(app.slides(deck))

        // Cancelled opens of the cached deck.
        for delay in [0, 1, 20] {
            let open = Task { try await app.cache.slideImages(for: deck, fileURL: app.documents.fileURL(for: deck)) }
            try await Task.sleep(for: .milliseconds(delay))
            open.cancel()
            _ = try? await open.value
        }
        // Another deck failing, timing out and being left.
        let other = try await importFixture("missing-slide", into: app)
        _ = await app.open(other)
        let big = try await importFixture("scale-50", into: app)
        let quick = PowerPointSlideCache(documentService: app.documents, options: .init(timeout: .milliseconds(300)))
        _ = await app.open(big, slides: quick)
        let left = Task { try await app.cache.slideImages(for: big, fileURL: app.documents.fileURL(for: big)) }
        try await Task.sleep(for: .milliseconds(300))
        left.cancel()
        _ = try? await left.value
        #expect(await waitUntil { !PowerPointSlideCache.isRendering(big.id) })

        #expect(try fingerprint(app.slides(deck)) == before, "The valid cache is byte for byte the same")
        let rendersBefore = app.cache.events.renders
        let reopened = await app.open(deck)
        #expect(reopened.slideCount == 3)
        #expect(app.cache.events.renders == rendersBefore, "Opened from the cache")
        reopened.didLeave()
    }

    /// 8: a cache the A9.4 rules find stale (another source) is replaced; when
    /// that render fails, nothing of the old deck is ever shown.
    @Test func aStaleCacheWhoseRenderFailsIsNeverShown() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-3", into: app)
        await app.open(deck).didLeave()
        // The stored file now holds a deck that fails to render.
        try Data(contentsOf: try fixture("missing-slide")).write(to: app.documents.fileURL(for: deck))

        let model = await app.open(deck)
        #expect(model.powerPointFailure == .missingResource)
        #expect(model.slideCount == 0, "Never the old file's slides")
        #expect(try listing(app.generated(deck)).isEmpty, "The stale cache is gone, and nothing partial replaced it")
    }

    // MARK: Partial cache

    /// 5, 6, 10: a render cut short after some slides were written is never
    /// the cache; the next render's cache matches its slides exactly.
    @Test func aPartialRenderIsNeverPromoted() async throws {
        defer { cleanUp() }
        let started = Date()
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-50", into: app)
        // Long enough to write some slides, too short for fifty.
        let quick = PowerPointSlideCache(documentService: app.documents, options: .init(timeout: .seconds(2)))
        let failed = await app.open(deck, slides: quick)
        if failed.powerPointFailure == nil {
            failed.didLeave()
            print("PPTX A954 partial: the render finished within the limit; the cut-short case was not exercised")
            return
        }
        #expect(failed.powerPointFailure == .timeout)
        #expect(try listing(app.generated(deck)).isEmpty, "No slide of the cut-short render is kept")
        #expect(await waitUntil { rendererFolders(since: started).isEmpty })

        let model = await app.open(deck)
        #expect(model.slideCount == 50)
        try expectValidCache(app, deck, slides: 50)
        model.didLeave()
    }

    // MARK: Restart

    /// 14, 21: what an app stopped mid-render leaves behind (a staging folder
    /// with some slides, a damaged cache, an old renderer work folder) is never
    /// opened, is removed by the next render, and that render succeeds.
    @Test func afterARestartLeftoversAreIgnoredAndRemoved() async throws {
        defer { cleanUp() }
        let first = try Launch(root: root)
        let deck = try await importFixture("scale-3", into: first)
        await first.open(deck).didLeave()

        // As the stopped app left it.
        let slides = first.slides(deck), parent = slides.deletingLastPathComponent()
        let staging = parent.appendingPathComponent("Slides-\(UUID().uuidString).partial", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: slides.appendingPathComponent("slide-001.png"), to: staging.appendingPathComponent("slide-001.png"))
        try FileManager.default.removeItem(at: slides.appendingPathComponent("slide-003.png"))
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PowerPointRender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("slides"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: work.path)

        let restarted = try Launch(root: root)
        let sameDeck = try #require(try await restarted.documents.documents(in: nil).first { $0.id == deck.id })
        let model = await restarted.open(sameDeck)
        #expect(model.phase == .ready)
        #expect(model.slideCount == 3, "Never the damaged or staged slides")
        #expect(restarted.cache.events.hits == 0 && restarted.cache.events.renders == 1)
        try expectValidCache(restarted, sameDeck, slides: 3)
        #expect(!FileManager.default.fileExists(atPath: work.path), "The abandoned renderer folder is removed")
        model.didLeave()
    }

    /// 21: a failure, the app stops, and after starting again the deck opens
    /// normally, with no session from the failed attempt.
    @Test func aFailureThenARestartRecovers() async throws {
        defer { cleanUp() }
        let first = try Launch(root: root)
        let deck = try await importFixture("scale-3", into: first)
        try blockGeneratedFolder(deck, first)
        let failed = await first.open(deck)
        #expect(failed.powerPointFailure == .storageFailure)
        failed.didLeave()
        await failed.saveSession()
        try FileManager.default.removeItem(at: first.generated(deck))

        let restarted = try Launch(root: root)
        #expect(try await restarted.sessions.allSessions().isEmpty, "No session from the failed attempt")
        let model = await restarted.open(deck)
        #expect(model.phase == .ready)
        #expect(model.slideNumber == 1)
        #expect(model.slideCount == 3)
        try expectValidCache(restarted, deck, slides: 3)
        model.didLeave()
    }

    // MARK: Concurrency

    /// 18, 20: opens of the same deck at once share one render and all get the same slides.
    @Test func simultaneousOpensShareOneRenderAndOneResult() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-10", into: app)
        let file = app.documents.fileURL(for: deck)
        let opens = (0..<4).map { _ in Task { try await app.cache.slideImages(for: deck, fileURL: file) } }
        var results: [[URL]] = []
        for open in opens { results.append(try await open.value) }
        #expect(Set(results.map { $0.map(\.lastPathComponent) }).count == 1)
        #expect(results[0].count == 10)
        #expect(app.cache.events.renders == 1)
        try expectValidCache(app, deck, slides: 10)
    }

    /// 19: opening again while a cancelled render is still finishing waits for
    /// it, never renders over it, and ends with one valid cache.
    @Test func openingAgainWhileACancelledRenderFinishesIsSafe() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-50", into: app)
        let file = app.documents.fileURL(for: deck)
        for delay in [50, 400, 1500] {
            try? FileManager.default.removeItem(at: app.generated(deck))
            let leaving = Task { try await app.cache.slideImages(for: deck, fileURL: file) }
            try await Task.sleep(for: .milliseconds(delay))
            leaving.cancel()
            // Straight away, without waiting for the cancelled render to end.
            let again = try await app.cache.slideImages(for: deck, fileURL: file)
            #expect(again.count == 50, "after \(delay) ms")
            _ = try? await leaving.value
            #expect(!PowerPointSlideCache.isRendering(deck.id))
            try expectValidCache(app, deck, slides: 50)
        }
    }

    /// 19: Try Again tapped while the first attempt's model is still loading is ignored.
    @Test func tryAgainDuringALoadDoesNothing() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-10", into: app)
        let counting = CountingSlides(app.cache)
        let model = app.model(deck, slides: counting)
        let load = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(100))
        await model.retry()
        await load.value
        #expect(counting.calls == 1)
        #expect(model.slideCount == 10)
        #expect(app.cache.events.renders == 1)
        model.didLeave()
    }

    // MARK: Helpers

    /// A file where the document's generated folder should be: slides can't be stored.
    private func blockGeneratedFolder(_ deck: Document, _ app: Launch) throws {
        let generated = app.generated(deck)
        try FileManager.default.createDirectory(at: generated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: generated)
    }

    private func expectValidCache(_ app: Launch, _ deck: Document, slides count: Int,
                                  sourceLocation: SourceLocation = #_sourceLocation) throws {
        let expected = (1...count).map { String(format: "slide-%03d.png", $0) } + ["cache.json"]
        #expect(try listing(app.slides(deck)) == expected.sorted(), sourceLocation: sourceLocation)
        let data = try Data(contentsOf: app.slides(deck).appendingPathComponent("cache.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(manifest["slideCount"] as? Int == count, "Metadata matches the slides", sourceLocation: sourceLocation)
        #expect(manifest["documentID"] as? String == deck.id.rawValue.uuidString, sourceLocation: sourceLocation)
        #expect(try listing(app.generated(deck)) == ["Slides"], "No staging folders", sourceLocation: sourceLocation)
    }

    /// Names and sizes and modification dates of every file in a folder.
    private func fingerprint(_ folder: URL) throws -> [String] {
        try listing(folder).map { name in
            let values = try folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(name) \(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        }
    }

    /// The renderer's work folders in tmp made since `date`.
    private func rendererFolders(since date: Date) -> [String] {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return names.filter { name in
            guard name.hasPrefix("PowerPointRender-") else { return false }
            let created = (try? tmp.appendingPathComponent(name).resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return created >= date.addingTimeInterval(-1)
        }
    }

    private func listing(_ folder: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func importFixture(_ name: String, into app: Launch) async throws -> Document {
        try await app.documents.importFile(at: try fixture(name), filename: "\(name).pptx")
    }

    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: RecoveryFixtureToken.self)
        return try #require(bundle.url(forResource: name, withExtension: "pptx")
            ?? bundle.url(forResource: name, withExtension: "pptx", subdirectory: "Fixtures"), "fixture \(name)")
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

/// Counts the attempts that reach the cache.
private final class CountingSlides: PowerPointSlideImageProviding, @unchecked Sendable {
    private let base: PowerPointSlideCache
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(_ base: PowerPointSlideCache) { self.base = base }

    func slideImages(for document: Document, fileURL: URL) async throws -> [URL] {
        lock.withLock { _calls += 1 }
        return try await base.slideImages(for: document, fileURL: fileURL)
    }

    func slideImage(for documentID: DocumentID, index: Int) -> URL { base.slideImage(for: documentID, index: index) }
}

/// The first attempt through one cache, later ones through the next: a first
/// render with a short time limit, then Try Again with the normal one.
private final class SwitchingSlides: PowerPointSlideImageProviding, @unchecked Sendable {
    private let caches: [PowerPointSlideCache]
    private let lock = NSLock()
    private var attempt = 0

    init(_ caches: [PowerPointSlideCache]) { self.caches = caches }

    func slideImages(for document: Document, fileURL: URL) async throws -> [URL] {
        let cache = lock.withLock {
            defer { attempt += 1 }
            return caches[min(attempt, caches.count - 1)]
        }
        return try await cache.slideImages(for: document, fileURL: fileURL)
    }

    func slideImage(for documentID: DocumentID, index: Int) -> URL { caches[0].slideImage(for: documentID, index: index) }
}

private final class RecoveryFixtureToken {}
