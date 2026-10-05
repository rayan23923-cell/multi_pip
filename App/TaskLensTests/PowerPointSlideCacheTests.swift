import CryptoKit
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

/// A9.4: the PowerPoint slide cache. Every test runs over a file-backed store,
/// so a "launch" is a new set of repositories, services and cache over the
/// same folder, as when the app starts again. Counts come from the cache's own
/// `events` (opened from cache vs rendered). `PPTX A94 PERF` lines carry timings.
@MainActor
@Suite("PowerPoint slide cache", .serialized)
struct PowerPointSlideCacheTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TaskLensPowerPointCache-\(UUID().uuidString)", isDirectory: true)

    /// One run of the app: everything built fresh over `root`.
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

        func open(_ deck: Document, sleep: PresentationAutoPlayer.Sleep? = nil) async -> PresentationModel {
            let model = PresentationModel(request: .powerPoint(deck.id), documentService: documents, sessionStore: sessions,
                                          slideImages: cache, autoPlaySleep: sleep)
            await model.load()
            if case .error = model.phase {
                print("PPTX A94 open failed: \(PowerPointRenderer.lastFailureDetail ?? "-")")
            }
            return model
        }

        func slides(_ deck: Document) -> URL { cache.slidesDirectory(for: deck.id) }
        func manifestURL(_ deck: Document) -> URL { slides(deck).appendingPathComponent("cache.json") }
    }

    // MARK: Test matrix

    @Test func oneSlideRendersOnceThenOpensFromTheCache() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-1", into: app)
        let first = await app.open(deck)
        #expect(first.slideCount == 1)
        #expect(app.cache.events.renders == 1 && app.cache.events.hits == 0)
        first.didLeave()

        let manifest = try readManifest(app, deck)
        #expect(manifest["rendererVersion"] as? Int == PowerPointSlideCache.rendererVersion)
        #expect(manifest["documentID"] as? String == deck.id.rawValue.uuidString)
        #expect(manifest["slideCount"] as? Int == 1)
        #expect(manifest["imageFormat"] as? String == "png")
        #expect(manifest["longestSidePixels"] as? Int == 1920)
        #expect((manifest["sourceSHA256"] as? String)?.count == 64)
        #expect(manifest["sourceSize"] as? Int == fileSize(app.documents.fileURL(for: deck)))
        #expect(try listing(app.slides(deck)) == ["cache.json", "slide-001.png"])
        let rendered = try hashes(app, deck)

        let second = await app.open(deck)
        #expect(second.slideCount == 1)
        #expect(app.cache.events.renders == 1 && app.cache.events.hits == 1)
        #expect(try hashes(app, deck) == rendered, "The cached image is the rendered one, byte for byte")
        second.didLeave()
    }

    @Test(arguments: [10, 50, 100])
    func firstRenderCachedOpenAndOpenAfterRestart(slides count: Int) async throws {
        defer { cleanUp() }
        let clock = ContinuousClock()
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-\(count)", into: app)

        var started = clock.now
        let first = await app.open(deck)
        let firstOpen = clock.now - started
        #expect(first.slideCount == count)
        first.goToSlide(number: count / 2)
        await leave(first)
        let rendered = try hashes(app, deck)

        var cachedOpens: [Duration] = []
        for _ in 0..<3 {
            started = clock.now
            let again = await app.open(deck)
            cachedOpens.append(clock.now - started)
            #expect(again.slideCount == count)
            #expect(again.slideNumber == count / 2)
            again.didLeave()
        }
        #expect(app.cache.events.renders == 1 && app.cache.events.hits == 3)

        let restarted = try Launch(root: root)
        let documents = try await restarted.documents.documents(in: nil)
        let sameDeck = try #require(documents.first { $0.id == deck.id })
        started = clock.now
        let afterRestart = await restarted.open(sameDeck)
        let restartOpen = clock.now - started
        #expect(afterRestart.slideCount == count)
        #expect(afterRestart.slideNumber == count / 2)
        #expect(restarted.cache.events.renders == 0 && restarted.cache.events.hits == 1, "No render after a restart")
        #expect(try hashes(restarted, deck) == rendered)
        afterRestart.didLeave()

        let images = try imageBytes(app, deck)
        let total = try folderBytes(app.slides(deck))
        let cached = cachedOpens.sorted()[1]
        #expect(cached < .seconds(1))
        #expect(restartOpen < .seconds(2))
        print("PPTX A94 PERF slides=\(count) firstOpen=\(seconds(firstOpen))s cachedOpen=\(seconds(cached))s "
            + "cachedOpens=\(cachedOpens.map(seconds).joined(separator: ",")) openAfterRestart=\(seconds(restartOpen))s "
            + "cacheBytes=\(total) imageBytes=\(images) perSlide=\(images / count) metadataBytes=\(total - images)")
    }

    // MARK: Validation

    enum Damage: String, CaseIterable, Sendable {
        case missingImage, unreadableImage, emptyImage, jpegImage, symlinkedImage, extraImage
        case missingMetadata, invalidMetadata, fewerSlides, moreSlides, wrongFingerprint, wrongSourceSize
        case olderRenderer, newerRenderer, otherDocument, otherImageSize, otherFormat
    }

    @Test(arguments: Damage.allCases)
    func aDamagedCacheIsRenderedAgain(_ damage: Damage) async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-3", into: app)
        await app.open(deck).didLeave()
        try apply(damage, app, deck)

        let reopened = await app.open(deck)
        #expect(reopened.phase == .ready)
        #expect(reopened.slideCount == 3, "Never fewer or more slides than the deck")
        #expect(app.cache.events.renders == 2 && app.cache.events.hits == 0, "\(damage) is never opened")
        try expectValidCache(app, deck, slides: 3)
        reopened.didLeave()

        await app.open(deck).didLeave()
        #expect(app.cache.events.renders == 2 && app.cache.events.hits == 1, "The new cache is used")
    }

    @Test func aChangedSourceIsRenderedAgain() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-3", into: app)
        await app.open(deck).didLeave()
        // The stored file now holds a different deck (another size).
        try Data(contentsOf: try fixture("scale-1")).write(to: app.documents.fileURL(for: deck))

        let reopened = await app.open(deck)
        #expect(reopened.slideCount == 1, "Never the old file's slides")
        #expect(app.cache.events.renders == 2)
        try expectValidCache(app, deck, slides: 1)
        reopened.didLeave()
    }

    @Test func aSourceWithTheSameSizeButOtherContentIsRenderedAgain() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-3", into: app)
        await app.open(deck).didLeave()
        let file = app.documents.fileURL(for: deck)
        let before = try Data(contentsOf: file)
        try Self.withChangedZipTimestamps(before).write(to: file)
        #expect(fileSize(file) == before.count)

        await app.open(deck).didLeave()
        #expect(app.cache.events.renders == 2 && app.cache.events.hits == 0)
        try expectValidCache(app, deck, slides: 3)
    }

    @Test func aTouchedButUnchangedSourceUsesTheCache() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-3", into: app)
        await app.open(deck).didLeave()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                              ofItemAtPath: app.documents.fileURL(for: deck).path)

        await app.open(deck).didLeave()
        #expect(app.cache.events.renders == 1 && app.cache.events.hits == 1, "Same content, same SHA-256")
    }

    @Test func aSlidesFolderLinkedOutsideTheStoreIsNeverTrusted() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-3", into: app)
        await app.open(deck).didLeave()
        // A complete, valid-looking cache outside the document's folder, linked in.
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.moveItem(at: app.slides(deck), to: outside)
        try FileManager.default.createSymbolicLink(at: app.slides(deck), withDestinationURL: outside)

        await app.open(deck).didLeave()
        #expect(app.cache.events.renders == 2 && app.cache.events.hits == 0)
        let values = try app.slides(deck).resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink != true)
        try expectValidCache(app, deck, slides: 3)
        #expect(try listing(outside).count == 4, "Nothing outside the store is deleted")
    }

    // MARK: Atomic creation and cleanup

    @Test func anUnfinishedRenderIsNeverOpenedAndIsRemoved() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-3", into: app)
        await app.open(deck).didLeave()
        // As if the app stopped mid-render: the cache gone, a complete-looking staging folder left.
        let parent = app.slides(deck).deletingLastPathComponent()
        let staging = parent.appendingPathComponent("Slides-\(UUID().uuidString).partial", isDirectory: true)
        try FileManager.default.moveItem(at: app.slides(deck), to: staging)

        await app.open(deck).didLeave()
        #expect(app.cache.events.renders == 2 && app.cache.events.hits == 0)
        #expect(try listing(parent) == ["Slides"], "Staging folders are removed")
        try expectValidCache(app, deck, slides: 3)
    }

    @Test func aFailedRenderLeavesNothingAndIsNeverValid() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        for name in ["audit-with-notes", "missing-slide"] {
            let deck = try await importFixture(name, into: app)
            let model = await app.open(deck)
            if case .error = model.phase {} else { Issue.record("\(name) should fail") }
            #expect(model.slideCount == 0)
            let parent = app.slides(deck).deletingLastPathComponent()
            #expect((try? listing(parent)) ?? [] == [], "\(name): no cache, no staging folder")
            // Opening again tries again; a failure is never remembered as a cache.
            _ = await app.open(deck)
            #expect((try? listing(parent)) ?? [] == [])
        }
        #expect(app.cache.events.renders == 4 && app.cache.events.hits == 0)
        #expect(try await app.sessions.allSessions().isEmpty)
    }

    @Test func deletingTheSourceDeletesItsCache() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let kept = try await importFixture("scale-1", into: app)
        let deleted = try await importFixture("scale-3", into: app)
        await app.open(kept).didLeave()
        await app.open(deleted).didLeave()
        try await app.documents.delete(deleted.id)
        #expect(!FileManager.default.fileExists(atPath: app.documents.generatedFilesDirectory(for: deleted.id).path))
        try expectValidCache(app, kept, slides: 1)

        // A stored file removed behind the app's back: nothing is shown from the cache.
        try FileManager.default.removeItem(at: app.documents.fileURL(for: kept))
        let model = await app.open(kept)
        #expect(model.phase == .error(.unreadable))
        #expect(model.slideCount == 0)
    }

    // MARK: Concurrency

    @Test func openingTheSameDeckAtOnceRendersOnce() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-3", into: app)
        let opens = (0..<3).map { _ in Task { await app.open(deck) } }
        var models: [PresentationModel] = []
        for open in opens { models.append(await open.value) }
        #expect(models.allSatisfy { $0.slideCount == 3 })
        #expect(app.cache.events.renders == 1, "One render, shared by every open")
        #expect(PowerPointRenderer.peakWebViewCount <= 1)
        models.forEach { $0.didLeave() }
        try expectValidCache(app, deck, slides: 3)
    }

    @Test func differentDecksAtOnceKeepTheirOwnSlides() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let decks = [try await importFixture("scale-3", into: app), try await importFixture("aspect-4x3", into: app),
                     try await importFixture("arabic", into: app)]
        let opens = decks.map { deck in Task { await app.open(deck) } }
        var counts: [Int] = []
        for open in opens {
            let model = await open.value
            counts.append(model.slideCount)
            model.didLeave()
        }
        #expect(counts == [3, 1, 4])
        #expect(app.cache.events.renders == 3)
        var seen = Set<String>()
        for (deck, count) in zip(decks, counts) {
            try expectValidCache(app, deck, slides: count)
            let deckHashes = Set(try hashes(app, deck).dropLast()) // images only
            #expect(seen.isDisjoint(with: deckHashes), "No deck shows another's slides")
            seen.formUnion(deckHashes)
        }
    }

    // MARK: Separation

    @Test func slideChangesAndAutoPlayNeverRender() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let deck = try await importFixture("scale-10", into: app)
        let model = await app.open(deck, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
        let rendered = try hashes(app, deck)
        for _ in 0..<9 { model.next() }
        model.previous()
        model.goToSlide(number: 3)
        for number in 1...10 {
            model.goToSlide(number: number)
            let source = try #require(model.currentSlide?.source)
            #expect(await model.image(for: source, maxPixelSize: 828) != nil)
        }
        model.goToSlide(number: 1)
        model.setAutoPlayInterval(5)
        model.toggleAutoPlay()
        #expect(await waitUntil { model.phase == .completed })
        #expect(model.slideNumber == 10)
        await leave(model)
        #expect(app.cache.events.renders == 1 && app.cache.events.hits == 0, "Nothing after the first load")
        #expect(try hashes(app, deck) == rendered)
    }

    @Test func cachedSlidesAreNotLibraryDocumentsAndLeaveOtherFilesAlone() async throws {
        defer { cleanUp() }
        let app = try Launch(root: root)
        let pdf = try await app.documents.importData(Data("%PDF-1.4".utf8), filename: "Report.pdf", contentType: .pdf)
        let read = try await app.documents.setLastReadPage(pdf.id, page: 4)
        let deck = try await importFixture("scale-3", into: app)
        await app.open(deck).didLeave()

        let library = try await app.documents.documents(in: nil)
        #expect(Set(library.map(\.id)) == [pdf.id, deck.id], "Slide images are never documents")
        #expect(library.allSatisfy { $0.kind != .image })
        let pdfNow = try await app.documents.document(id: pdf.id)
        #expect(pdfNow.lastReadPage == read.lastReadPage)
        #expect(!FileManager.default.fileExists(atPath: app.documents.generatedFilesDirectory(for: pdf.id).path))
        #expect(try listing(app.documents.generatedFilesDirectory(for: deck.id)) == ["Slides"])
    }

    // MARK: Damage

    private func apply(_ damage: Damage, _ app: Launch, _ deck: Document) throws {
        let folder = app.slides(deck)
        let second = folder.appendingPathComponent("slide-002.png")
        let fileManager = FileManager.default
        switch damage {
        case .missingImage: try fileManager.removeItem(at: second)
        case .unreadableImage: try Data("not an image".utf8).write(to: second)
        case .emptyImage: try Data().write(to: second)
        case .jpegImage:
            let image = try #require(UIImage(contentsOfFile: second.path)?.jpegData(compressionQuality: 0.9))
            try image.write(to: second)
        case .symlinkedImage:
            try fileManager.removeItem(at: second)
            try fileManager.createSymbolicLink(atPath: second.path, withDestinationPath: "slide-001.png")
        case .extraImage:
            try fileManager.copyItem(at: folder.appendingPathComponent("slide-001.png"), to: folder.appendingPathComponent("slide-004.png"))
        case .missingMetadata: try fileManager.removeItem(at: app.manifestURL(deck))
        case .invalidMetadata: try Data("{ \"rendererVersion\": ".utf8).write(to: app.manifestURL(deck))
        case .fewerSlides: try editManifest(app, deck) { $0["slideCount"] = 2 }
        case .moreSlides: try editManifest(app, deck) { $0["slideCount"] = 4 }
        case .wrongFingerprint:
            try editManifest(app, deck) {
                $0["sourceSHA256"] = String(repeating: "0", count: 64)
                $0["sourceModified"] = 0
            }
        case .wrongSourceSize: try editManifest(app, deck) { $0["sourceSize"] = ($0["sourceSize"] as? Int ?? 0) + 1 }
        case .olderRenderer: try editManifest(app, deck) { $0["rendererVersion"] = PowerPointSlideCache.rendererVersion - 1 }
        case .newerRenderer: try editManifest(app, deck) { $0["rendererVersion"] = PowerPointSlideCache.rendererVersion + 1 }
        case .otherDocument: try editManifest(app, deck) { $0["documentID"] = UUID().uuidString }
        case .otherImageSize: try editManifest(app, deck) { $0["longestSidePixels"] = 1024 }
        case .otherFormat: try editManifest(app, deck) { $0["imageFormat"] = "jpeg" }
        }
    }

    // MARK: Helpers

    private func expectValidCache(_ app: Launch, _ deck: Document, slides count: Int,
                                  sourceLocation: SourceLocation = #_sourceLocation) throws {
        let expected = (1...count).map { String(format: "slide-%03d.png", $0) } + ["cache.json"]
        #expect(try listing(app.slides(deck)) == expected.sorted(), sourceLocation: sourceLocation)
        let manifest = try readManifest(app, deck)
        #expect(manifest["slideCount"] as? Int == count, sourceLocation: sourceLocation)
        #expect(manifest["documentID"] as? String == deck.id.rawValue.uuidString, sourceLocation: sourceLocation)
        #expect(manifest["rendererVersion"] as? Int == PowerPointSlideCache.rendererVersion, sourceLocation: sourceLocation)
        let parent = app.slides(deck).deletingLastPathComponent()
        #expect(try listing(parent) == ["Slides"], "No staging folders", sourceLocation: sourceLocation)
    }

    private func readManifest(_ app: Launch, _ deck: Document) throws -> [String: Any] {
        let data = try Data(contentsOf: app.manifestURL(deck))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func editManifest(_ app: Launch, _ deck: Document, _ edit: (inout [String: Any]) -> Void) throws {
        var manifest = try readManifest(app, deck)
        edit(&manifest)
        try JSONSerialization.data(withJSONObject: manifest).write(to: app.manifestURL(deck))
    }

    /// SHA-256 of every file in the cache, in name order (images, then cache.json last).
    private func hashes(_ app: Launch, _ deck: Document) throws -> [String] {
        let names = try listing(app.slides(deck)).filter { $0 != "cache.json" } + ["cache.json"]
        return try names.map { name in
            let data = try Data(contentsOf: app.slides(deck).appendingPathComponent(name))
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private func imageBytes(_ app: Launch, _ deck: Document) throws -> Int {
        try listing(app.slides(deck)).filter { $0.hasSuffix(".png") }
            .reduce(0) { $0 + fileSize(app.slides(deck).appendingPathComponent($1)) }
    }

    private func folderBytes(_ folder: URL) throws -> Int {
        try listing(folder).reduce(0) { $0 + fileSize(folder.appendingPathComponent($1)) }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    private func listing(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func leave(_ model: PresentationModel) async {
        model.didLeave()
        await model.saveSession()
    }

    private func importFixture(_ name: String, into app: Launch) async throws -> Document {
        try await app.documents.importFile(at: try fixture(name), filename: "\(name).pptx")
    }

    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: CacheFixtureToken.self)
        return try #require(bundle.url(forResource: name, withExtension: "pptx")
            ?? bundle.url(forResource: name, withExtension: "pptx", subdirectory: "Fixtures"), "fixture \(name)")
    }

    /// The same zip with other modification times on its first entry: same
    /// size, still a valid deck, different bytes.
    private static func withChangedZipTimestamps(_ data: Data) throws -> Data {
        var bytes = [UInt8](data)
        let local: [UInt8] = [0x50, 0x4B, 0x03, 0x04], central: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        try #require(Array(bytes[0..<4]) == local)
        let centralStart = try #require((0...(bytes.count - 4)).first { Array(bytes[$0..<$0 + 4]) == central })
        let changed = bytes[10] ^ 0x02 // the minutes and seconds bits of the time
        bytes[10] = changed
        bytes[centralStart + 12] = changed
        return Data(bytes)
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
        String(format: "%.3f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private final class CacheFixtureToken {}
