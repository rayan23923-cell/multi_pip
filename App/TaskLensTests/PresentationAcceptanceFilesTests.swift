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

/// A9.5.6: the acceptance file set (`acceptance-*` fixtures: real .pptx decks
/// written with python-pptx, PDFs exported from them with LibreOffice, and
/// photos of several shapes) through the real app pipeline on the simulator.
/// This is not the physical-device acceptance; it checks the same files the
/// device run uses. `PPTX A956` lines carry results; `PROBEIMG` lines carry a
/// rendered slide per deck so its content can be looked at.
@MainActor
@Suite("A9.5.6 acceptance files", .serialized)
struct PresentationAcceptanceFilesTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TaskLensAcceptance-\(UUID().uuidString)", isDirectory: true)

    private static let quick: PresentationAutoPlayer.Sleep = { _ in try await Task.sleep(for: .milliseconds(5)) }
    private static let neverEnds: PresentationAutoPlayer.Sleep = { _ in try await Task.sleep(for: .seconds(3600)) }

    @MainActor
    private struct Launch {
        let documents: DocumentService
        let sessions: PresentationSessionStore
        let cache: PowerPointSlideCache

        init(root: URL) throws {
            let location = StoreLocation(rootURL: root)
            let repositories = try Repositories.fileBacked(at: location)
            documents = DocumentService(documents: repositories.documents, filesDirectory: location.filesDirectory)
            sessions = PresentationSessionStore(sessions: repositories.presentationSessions)
            cache = PowerPointSlideCache(documentService: documents)
        }

        func open(_ request: PresentationRequest, sleep: PresentationAutoPlayer.Sleep?,
                  onImportPDF: (@MainActor () -> Void)? = {}) async -> PresentationModel {
            let model = PresentationModel(request: request, documentService: documents, sessionStore: sessions,
                                          slideImages: cache, autoPlaySleep: sleep, onImportPDF: onImportPDF)
            await model.load()
            return model
        }
    }

    // MARK: PowerPoint decks 1–6

    struct Deck: Sendable, CustomTestStringConvertible {
        let name: String
        let slides: Int
        /// The slide whose rendering is printed (one-based).
        let shown: Int
        /// Prints every slide, small, so each picture can be checked against its slide.
        var everySlide = false
        /// Has a picture on each slide. Where WebKit links slides to other
        /// slides' pictures (seen on the iOS 26.5 simulator), the deck must
        /// open on the rendering failure screen instead of wrong slides.
        var pictures = false
        var testDescription: String { name }
    }

    nonisolated static let decks = [
        Deck(name: "1-simple-text", slides: 3, shown: 1),
        Deck(name: "2-multi-slide-15", slides: 15, shown: 2),
        Deck(name: "3-arabic-rtl", slides: 5, shown: 2),
        Deck(name: "4-images-shapes", slides: 6, shown: 1, everySlide: true, pictures: true),
        Deck(name: "5-tables-charts", slides: 5, shown: 3),
        Deck(name: "6-large-80-slides", slides: 80, shown: 80, everySlide: true, pictures: true),
    ]

    /// Import → check → render → cache → present → navigate → Auto Play to the
    /// end without looping → leave on a non-first slide → restart → restored
    /// from the cache.
    @Test(arguments: decks)
    func deckPresentsAndRestores(deck: Deck) async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let document = try await app.documents.importFile(at: fixture("acceptance-\(deck.name)", "pptx"))
        #expect(document.kind == .powerpoint)

        let start = ContinuousClock.now
        let model = await app.open(.powerPoint(document.id), sleep: Self.neverEnds)
        let firstOpen = ContinuousClock.now - start
        if deck.pictures, model.powerPointFailure == .renderingFailed,
           PowerPointRenderer.lastFailureDetail?.contains("picture of another slide") == true {
            #expect(model.failureContent?.canRetry == true)
            #expect(model.failureContent?.canImportPDF == true)
            model.didLeave()
            await model.saveSession()
            #expect(try await app.sessions.allSessions().isEmpty)
            #expect(try listing(app.documents.generatedFilesDirectory(for: document.id)).isEmpty)
            print("PPTX A956 deck \(deck.name): refused, \(PowerPointRenderer.lastFailureDetail ?? "-") firstOpen=\(firstOpen)")
            return
        }
        #expect(model.phase == .ready, "\(deck.name): \(String(describing: model.powerPointFailure))")
        #expect(model.failureContent == nil)
        #expect(model.slideCount == deck.slides)
        #expect(app.cache.events.renders == 1)

        model.next()
        #expect(model.slideNumber == min(2, deck.slides))
        model.previous()
        #expect(model.slideNumber == 1)
        for number in 1...deck.slides {
            model.goToSlide(number: number)
            let source = try #require(model.currentSlide?.source)
            let image = await model.image(for: source, maxPixelSize: 828)
            #expect(image != nil, "\(deck.name): slide \(number) is drawn")
            if number == deck.shown, let image { emit("A956-\(deck.name)-\(number)", image) }
            if deck.everySlide, let small = await model.image(for: source, maxPixelSize: 160) {
                emit("A956S-\(deck.name)-\(number)", small)
            }
        }
        model.didLeave()

        // Auto Play on its own model, so the pacing is quick: it ends on the last slide and stays.
        let playing = await app.open(.powerPoint(document.id), sleep: Self.quick)
        playing.goToSlide(number: 1)
        playing.toggleAutoPlay()
        #expect(playing.isAutoPlaying)
        #expect(await waitUntil { playing.phase == .completed })
        #expect(playing.slideNumber == deck.slides)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(playing.slideNumber == deck.slides, "No loop")
        let leaveOn = max(1, deck.slides - 1)
        playing.goToSlide(number: leaveOn)
        playing.didLeave()
        await playing.saveSession()

        let restarted = try Launch(root: root)
        let again = await restarted.open(.powerPoint(document.id), sleep: Self.neverEnds)
        #expect(again.phase == .ready)
        #expect(again.slideNumber == leaveOn, "\(deck.name): restored")
        #expect(restarted.cache.events.renders == 0 && restarted.cache.events.hits == 1, "From the cache")
        again.didLeave()
        print("PPTX A956 deck \(deck.name): slides=\(model.slideCount) firstOpen=\(firstOpen) restoredSlide=\(again.slideNumber)")
    }

    // MARK: Problem decks

    /// Speaker notes: the failure screen, no Try Again, nothing cached, no session.
    @Test func speakerNotesDeckFails() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let document = try await app.documents.importFile(at: fixture("acceptance-7a-problem-speaker-notes", "pptx"))
        let model = await app.open(.powerPoint(document.id), sleep: Self.neverEnds)
        #expect(model.powerPointFailure == .speakerNotesUnsupported)
        #expect(model.failureContent == PowerPointFailureContent(.speakerNotesUnsupported))
        #expect(model.failureContent?.canRetry == false)
        #expect(model.failureContent?.canImportPDF == true)
        model.didLeave()
        await model.saveSession()
        #expect(try await app.sessions.allSessions().isEmpty)
        #expect(try listing(app.documents.generatedFilesDirectory(for: document.id)).isEmpty)
        print("PPTX A956 problem 7a-speaker-notes: \(String(describing: model.powerPointFailure))")
    }

    /// Not a presentation, a macro, half a file: refused at import, or on opening
    /// a failure that is never shown as slides, with nothing cached and no session.
    @Test(arguments: ["7b-problem-not-a-presentation", "7c-problem-macro", "7d-problem-truncated"])
    func brokenDecksAreRefused(name: String) async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let url = try fixture("acceptance-\(name)", "pptx")
        let document: Document
        do {
            document = try await app.documents.importFile(at: url)
        } catch {
            #expect(try await app.documents.documents(in: nil).isEmpty, "\(name): nothing added")
            print("PPTX A956 problem \(name): refused at import (\(error))")
            return
        }
        let model = await app.open(.powerPoint(document.id), sleep: Self.neverEnds)
        let failure = try #require(model.powerPointFailure, "\(name) must not present")
        #expect([PowerPointFailure.invalidSource, .securityRejected].contains(failure), "\(name): \(failure)")
        #expect(model.slideCount == 0)
        await model.retry()
        #expect(model.powerPointFailure == failure, "Try Again gives the same answer")
        model.didLeave()
        await model.saveSession()
        #expect(try await app.sessions.allSessions().isEmpty)
        #expect(try listing(app.documents.generatedFilesDirectory(for: document.id)).isEmpty)
        print("PPTX A956 problem \(name): opened, failure=\(failure)")
    }

    // MARK: PDF fallback with the exported PDF

    @Test func speakerNotesFallBackToTheExportedPDF() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let notes = try await app.documents.importFile(at: fixture("acceptance-7a-problem-speaker-notes", "pptx"))
        let fallback = PDFFallbackImport(failedPresentation: notes.id, documentService: app.documents)
        let failed = await app.open(.powerPoint(notes.id), sleep: Self.neverEnds, onImportPDF: { fallback.choosePDF() })
        failed.importPDF()
        #expect(await fallback.picked(nil) == nil, "Picker cancelled")
        #expect(failed.failureContent != nil)
        #expect(try await app.documents.documents(in: nil).count == 1)

        failed.importPDF()
        let exported = try fixture("acceptance-7a-problem-speaker-notes", "pdf")
        let id = try #require(await fallback.picked(exported))
        let pdf = await app.open(.pdf(id), sleep: Self.neverEnds)
        #expect(pdf.phase == .ready && pdf.slideCount == 4)
        pdf.goToSlide(number: 3)
        pdf.didLeave()
        await pdf.saveSession()
        let restarted = try Launch(root: root)
        let again = await restarted.open(.pdf(id), sleep: Self.neverEnds)
        #expect(again.slideNumber == 3)
        again.didLeave()
        #expect(await restarted.sessions.session(for: .powerPoint(notes.id)) == nil)
        print("PPTX A956 fallback: pdf slides=\(pdf.slideCount) restored=\(again.slideNumber)")
    }

    // MARK: PDF and image presentations

    @Test(arguments: [("2-multi-slide-15", 15), ("3-arabic-rtl", 5)])
    func exportedPDFPresentsAndKeepsTheReaderPage(name: String, pages: Int) async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let document = try await app.documents.importFile(at: fixture("acceptance-\(name)", "pdf"))
        _ = try await app.documents.setLastReadPage(document.id, page: 3)
        let model = await app.open(.pdf(document.id), sleep: Self.quick)
        #expect(model.phase == .ready && model.slideCount == pages)
        model.goToSlide(number: pages)
        #expect(model.slideNumber == pages)
        model.goToSlide(number: 1)
        model.toggleAutoPlay()
        #expect(await waitUntil { model.phase == .completed })
        #expect(model.slideNumber == pages)
        model.goToSlide(number: pages - 1)
        model.didLeave()
        await model.saveSession()
        let restarted = try Launch(root: root)
        let again = await restarted.open(.pdf(document.id), sleep: Self.neverEnds)
        #expect(again.slideNumber == pages - 1)
        again.didLeave()
        #expect(try await restarted.documents.document(id: document.id).lastReadPage == 3, "Reader page separate")
        print("PPTX A956 pdf \(name): slides=\(model.slideCount) restored=\(again.slideNumber)")
    }

    @Test func photosPresentInOrderAndRestore() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        var ids: [DocumentID] = []
        for index in 1...7 {
            ids.append(try await app.documents.importFile(at: fixture("acceptance-image-\(index)", index == 7 ? "png" : "jpg")).id)
        }
        let model = await app.open(.images(ids), sleep: Self.quick)
        #expect(model.phase == .ready && model.slideCount == 7)
        for (offset, id) in ids.enumerated() {
            model.goToSlide(number: offset + 1)
            guard case .image(let shown) = try #require(model.currentSlide?.source) else {
                Issue.record("slide \(offset + 1) is not an image"); continue
            }
            #expect(shown == id, "Slide \(offset + 1) is image \(offset + 1)")
            #expect(await model.image(for: shown, maxPixelSize: 828) != nil)
        }
        model.goToSlide(number: 1)
        model.toggleAutoPlay()
        #expect(await waitUntil { model.phase == .completed })
        #expect(model.slideNumber == 7)
        model.goToSlide(number: 6)
        model.didLeave()
        await model.saveSession()
        let restarted = try Launch(root: root)
        let again = await restarted.open(.images(ids), sleep: Self.neverEnds)
        #expect(again.slideNumber == 6)
        again.didLeave()
        print("PPTX A956 images: slides=\(model.slideCount) restored=\(again.slideNumber)")
    }

    // MARK: Helpers

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: AcceptanceFixtureToken.self)
        return try #require(bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"), "fixture \(name).\(ext)")
    }

    private func listing(_ folder: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(180)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Prints a small JPEG of the slide, base64 in 8,000-character lines.
    private func emit(_ name: String, _ image: CGImage) {
        guard let encoded = UIImage(cgImage: image).jpegData(compressionQuality: 0.7)?.base64EncodedString() else { return }
        let parts = stride(from: 0, to: encoded.count, by: 8000).map { start in
            let from = encoded.index(encoded.startIndex, offsetBy: start)
            return String(encoded[from..<encoded.index(from, offsetBy: min(8000, encoded.count - start))])
        }
        for (index, part) in parts.enumerated() { print("PROBEIMG \(name) \(index)/\(parts.count) \(part)") }
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private final class AcceptanceFixtureToken {}
