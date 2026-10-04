import Foundation
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation

@MainActor
@Suite("Presentation session")
struct PresentationSessionTests {
    private let env = TestEnvironment()
    private var store: PresentationSessionStore {
        PresentationSessionStore(sessions: env.repositories.presentationSessions, clock: env.clock)
    }

    // MARK: Identity

    @Test func eachSourceHasOneStableIdentity() {
        let a = DocumentID(), b = DocumentID(), c = DocumentID()
        #expect(PresentationSessionSource.pdf(a).sessionID.rawValue == a.rawValue, "A PDF's session is keyed by its document")
        #expect(PresentationSessionSource.images([a, b]).sessionID == PresentationSessionSource.images([a, b]).sessionID)
        #expect(PresentationSessionSource.images([a, b]).sessionID != PresentationSessionSource.images([b, a]).sessionID,
                "A different order is a different presentation")
        #expect(PresentationSessionSource.images([a, b]).sessionID != PresentationSessionSource.images([a, b, c]).sessionID)
        #expect(PresentationSessionSource.images([a]).sessionID != PresentationSessionSource.pdf(a).sessionID)
    }

    // MARK: Save and restore

    @Test func savedSlideComesBack() async throws {
        let source = PresentationSessionSource.pdf(DocumentID())
        #expect(await store.session(for: source) == nil, "A new presentation has no saved state")

        try await store.save(source, currentSlide: 11, slideCount: 48, autoPlayInterval: 15)
        let saved = try #require(await store.session(for: source))
        #expect(saved.currentSlide == 11, "Slide 12 is index 11")
        #expect(saved.slideCount == 48)
        #expect(saved.autoPlayInterval == 15)
        #expect(saved.lastViewedAt == env.clock.now())
        #expect(saved.restorableSlide(forSlideCount: 48) == 11)

        try await store.save(source, currentSlide: 19, slideCount: 48, autoPlayInterval: 15)
        #expect(await store.session(for: source)?.currentSlide == 19)
        #expect(try await store.allSessions().count == 1, "Saving again replaces the record")
    }

    @Test func presentationsKeepTheirOwnSlides() async throws {
        let pdfA = PresentationSessionSource.pdf(DocumentID())
        let pdfB = PresentationSessionSource.pdf(DocumentID())
        let images = PresentationSessionSource.images([DocumentID(), DocumentID(), DocumentID()])
        try await store.save(pdfA, currentSlide: 4, slideCount: 10, autoPlayInterval: nil)
        try await store.save(pdfB, currentSlide: 7, slideCount: 10, autoPlayInterval: nil)
        try await store.save(images, currentSlide: 2, slideCount: 3, autoPlayInterval: nil)

        #expect(await store.session(for: pdfA)?.currentSlide == 4)
        #expect(await store.session(for: pdfB)?.currentSlide == 7)
        #expect(await store.session(for: images)?.currentSlide == 2)
    }

    @Test func removingForgetsOnlyThatPresentation() async throws {
        let a = PresentationSessionSource.pdf(DocumentID())
        let b = PresentationSessionSource.pdf(DocumentID())
        try await store.save(a, currentSlide: 1, slideCount: 3, autoPlayInterval: nil)
        try await store.save(b, currentSlide: 2, slideCount: 3, autoPlayInterval: nil)
        try await store.remove(a)
        #expect(await store.session(for: a) == nil)
        #expect(await store.session(for: b)?.currentSlide == 2)
    }

    // MARK: Stale state

    @Test func onlyAMatchingSavedSlideIsRestored() {
        let session = PresentationSession(
            source: .pdf(DocumentID()), currentSlide: 39, slideCount: 48, autoPlayInterval: nil, lastViewedAt: Date()
        )
        #expect(session.restorableSlide(forSlideCount: 48) == 39)
        #expect(session.restorableSlide(forSlideCount: 20) == nil, "The document changed: slide 40 does not exist")
        #expect(session.restorableSlide(forSlideCount: 60) == nil, "The document changed: slide 40 may be other content")
        #expect(session.restorableSlide(forSlideCount: 0) == nil)

        var first = session
        first.currentSlide = 0
        #expect(first.restorableSlide(forSlideCount: 48) == 0)
        var last = session
        last.currentSlide = 47
        #expect(last.restorableSlide(forSlideCount: 48) == 47)
        var outside = session
        outside.currentSlide = 48
        #expect(outside.restorableSlide(forSlideCount: 48) == nil)
        outside.currentSlide = -1
        #expect(outside.restorableSlide(forSlideCount: 48) == nil)
    }

    // MARK: App restart

    @Test func sessionsSurviveARestart() async throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = PresentationSessionSource.images([DocumentID(), DocumentID()])
        do {
            let store = PresentationSessionStore(sessions: JSONFileRepository<PresentationSession>(directory: directory), clock: env.clock)
            try await store.save(source, currentSlide: 1, slideCount: 2, autoPlayInterval: 30)
        }
        // A new repository reads the file, as the app does after a relaunch.
        let reopened = PresentationSessionStore(sessions: JSONFileRepository<PresentationSession>(directory: directory), clock: env.clock)
        let saved = try #require(await reopened.session(for: source))
        #expect(saved.currentSlide == 1)
        #expect(saved.autoPlayInterval == 30)
    }

    // MARK: Recorder

    @Test func recorderWritesTheNewestStateWithoutPilingUp() async throws {
        let source = PresentationSessionSource.pdf(DocumentID())
        let recorder = PresentationSessionRecorder(source: source, store: store)
        for slide in 0..<50 {
            recorder.record(.init(currentSlide: slide, slideCount: 50, autoPlayInterval: 10))
        }
        await recorder.flush()
        #expect(await store.session(for: source)?.currentSlide == 49, "The last change wins")
        #expect(recorder.writeCount <= 2, "A burst is written once in flight plus once after, not 50 times")

        let writes = recorder.writeCount
        recorder.record(.init(currentSlide: 49, slideCount: 50, autoPlayInterval: 10))
        await recorder.flush()
        #expect(recorder.writeCount == writes, "Unchanged state is not written again")
        #expect(try await store.allSessions().count == 1)
    }

    @Test func recorderWritesEachSlowChange() async throws {
        let source = PresentationSessionSource.pdf(DocumentID())
        let recorder = PresentationSessionRecorder(source: source, store: store)
        for slide in 1...5 {
            recorder.record(.init(currentSlide: slide, slideCount: 10, autoPlayInterval: 5))
            await recorder.flush()
            #expect(await store.session(for: source)?.currentSlide == slide)
        }
        #expect(recorder.writeCount == 5, "One write per slide change")
    }

    @Test func restoredStateIsNotWrittenBack() async throws {
        let source = PresentationSessionSource.pdf(DocumentID())
        try await store.save(source, currentSlide: 3, slideCount: 10, autoPlayInterval: 10)
        let recorder = PresentationSessionRecorder(source: source, store: store)
        let restored = PresentationSessionRecorder.Snapshot(currentSlide: 3, slideCount: 10, autoPlayInterval: 10)
        recorder.markStored(restored)
        recorder.record(restored)
        await recorder.flush()
        #expect(recorder.writeCount == 0)
    }

    // MARK: Scale

    @Test(arguments: [10, 50])
    func manySessionsStayLight(count: Int) async throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresentationSessionStore(sessions: JSONFileRepository<PresentationSession>(directory: directory), clock: env.clock)
        let sources = (0..<count).map { _ in PresentationSessionSource.pdf(DocumentID()) }
        let started = ContinuousClock.now
        for (index, source) in sources.enumerated() {
            try await store.save(source, currentSlide: index, slideCount: count, autoPlayInterval: nil)
        }
        let saved = ContinuousClock.now - started
        for (index, source) in sources.enumerated() {
            #expect(await store.session(for: source)?.currentSlide == index)
        }
        let size = (try? FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("\(PresentationSession.entityName).json").path
        )[.size] as? Int) ?? 0
        print("SESSIONS \(count): saved in \(saved), file \(size) bytes")
        #expect(size < count * 1_000, "A session is a few hundred bytes")
    }

    // MARK: Separation from the reader

    @Test func sessionAndReadingPageNeverTouchEachOther() async throws {
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = env.documents(in: directory)
        let pdf = try await documents.importData(Data("%PDF-1.4".utf8), filename: "Deck.pdf", contentType: .pdf)
        _ = try await documents.setLastReadPage(pdf.id, page: 3)
        let before = try await documents.document(id: pdf.id)

        // Presenting on slide 12 leaves the reader's page alone.
        try await store.save(.pdf(pdf.id), currentSlide: 11, slideCount: 48, autoPlayInterval: nil)
        #expect(try await documents.document(id: pdf.id) == before)

        // Reading leaves the presentation's slide alone.
        _ = try await documents.setLastReadPage(pdf.id, page: 30)
        #expect(await store.session(for: .pdf(pdf.id))?.currentSlide == 11)
        #expect(try await documents.document(id: pdf.id).lastReadPage == 30)
    }

    @Test func deleteEverythingAlsoForgetsPresentations() async throws {
        try await store.save(.pdf(DocumentID()), currentSlide: 1, slideCount: 2, autoPlayInterval: nil)
        let control = DataControl(repositories: env.repositories, filesDirectory: TemporaryDirectory.make())
        #expect(try await control.makeExport(now: Date()).presentationSessions.count == 1)
        try await control.deleteEverything()
        #expect(try await store.allSessions().isEmpty)
    }
}
