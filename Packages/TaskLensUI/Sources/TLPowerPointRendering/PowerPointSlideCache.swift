import CryptoKit
import Foundation
import ImageIO
import TLCoreServices
import TLDomain
import TLFoundation

/// The one render cache for imported PowerPoint files: the slide images
/// `PowerPointRenderer` made, kept in the document's generated files folder
/// (which `DocumentService` deletes with the document and sweeps when the
/// document is gone), with a small `cache.json` describing them.
///
/// Opening a file whose cache is valid uses the images already there. A cache
/// is valid only when its metadata reads, names this document, the same
/// source file (size, modification date, and SHA-256 when those differ), the
/// current renderer version and image settings, and every one of its
/// `slideCount` images is present and readable. Anything else, including a
/// cache left by an older build, is deleted and the file is rendered again;
/// a partial cache is never opened.
///
/// A render goes into a new folder next to the cache and becomes the cache
/// only after every slide rendered and its metadata is written, so a failed,
/// cancelled or interrupted render never looks like a cache. Opening a file
/// that is already rendering waits for that render instead of starting another,
/// and a render started after a cancelled one (Try Again, opening it again)
/// waits until the cancelled one has ended.
///
/// A file the import check (A9.1) rejects is never rendered. Errors are
/// reported as `PowerPointFailure`, with nothing left behind. A caller that is
/// cancelled gets `cancelled`; the render itself stops when no other caller
/// is waiting for it.
public struct PowerPointSlideCache: PowerPointSlideImageProviding {
    /// Bump when rendered images change for the same file (a renderer fix, new
    /// settings), so caches made by older builds are rendered again.
    /// 1: A9.4, renderer with the A9.2 zoom fix (3075c48).
    public static let rendererVersion = 1

    private let documentService: DocumentService
    private let options: PowerPointRenderer.Options
    /// Counts for diagnostics and tests.
    public let events = Events()

    public init(documentService: DocumentService, options: PowerPointRenderer.Options = PowerPointRenderer.Options()) {
        self.documentService = documentService
        var options = options
        options.format = .png
        self.options = options
    }

    /// The folder holding a document's `slide-001.png`, `slide-002.png`... and `cache.json`.
    public func slidesDirectory(for documentID: DocumentID) -> URL {
        documentService.generatedFilesDirectory(for: documentID).appendingPathComponent("Slides", isDirectory: true)
    }

    public func slideImage(for documentID: DocumentID, index: Int) -> URL {
        slidesDirectory(for: documentID).appendingPathComponent(Self.fileName(index: index))
    }

    public func slideImages(for document: Document, fileURL: URL) async throws -> [URL] {
        let directory = slidesDirectory(for: document.id)
        let source: SourceFacts
        do { source = try Self.sourceFacts(fileURL) } catch { throw PowerPointFailure.storageFailure }
        if let cached = validSlides(in: directory, document: document.id, source: source, fileURL: fileURL) {
            events.record(.hit)
            return cached
        }
        return try await Self.renders.run(document.id) { [self] in
            // Another request may have rendered it meanwhile.
            if let cached = validSlides(in: directory, document: document.id, source: source, fileURL: fileURL) {
                events.record(.hit)
                return cached
            }
            return try await render(document.id, fileURL: fileURL, source: source, into: directory)
        }
    }

    // MARK: Rendering

    @MainActor
    private func render(_ id: DocumentID, fileURL: URL, source: SourceFacts, into directory: URL) async throws -> [URL] {
        let parent = directory.deletingLastPathComponent()
        // A stale or invalid cache must never be shown again.
        try? FileManager.default.removeItem(at: directory)
        Self.removeUnfinishedRenders(in: parent)
        Self.removeAbandonedRendererFolders()
        // The import check again, on the stored file: a rejected file is never rendered.
        let hash = try await Task.detached(priority: .userInitiated) { try Self.checkedSource(fileURL) }.value
        events.record(.render)
        let staging = parent.appendingPathComponent("Slides-\(UUID().uuidString)\(Self.unfinishedSuffix)", isDirectory: true)
        do {
            let output = try await PowerPointRenderer().render(fileURL, to: staging, options: options)
            guard !output.slides.isEmpty else { throw PowerPointRenderError.renderingFailed(.noVisibleSlides) }
            let manifest = Manifest(
                rendererVersion: Self.rendererVersion,
                documentID: id.rawValue,
                sourceSize: source.size,
                sourceModified: source.modified,
                sourceSHA256: hash,
                slideCount: output.slides.count,
                imageFormat: "png",
                longestSidePixels: options.longestSidePixels,
                createdAt: Date()
            )
            do {
                try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent(Self.manifestName), options: .atomic)
            } catch { throw PowerPointFailure.storageFailure }
            // The finished render becomes the cache in one rename.
            do {
                try FileManager.default.moveItem(at: staging, to: directory)
            } catch { throw PowerPointFailure.storageFailure }
            // The new cache must pass the same check as any other before it is used.
            guard let slides = validSlides(in: directory, document: id, source: source, fileURL: fileURL),
                  slides.count == output.slides.count
            else {
                try? FileManager.default.removeItem(at: directory)
                throw PowerPointFailure.corruptedCache
            }
            return slides
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Self.failure(for: error, fileURL: fileURL)
        }
    }

    /// The stored file's SHA-256, after the import check (A9.1) accepts it again.
    static func checkedSource(_ url: URL) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw PowerPointFailure.storageFailure }
        switch PowerPointPackage.rejection(of: data) {
        case .unsafe: throw PowerPointFailure.securityRejected
        case .malformed: throw PowerPointFailure.invalidSource
        case nil: return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    static let unfinishedSuffix = ".partial"

    /// Folders left by a render that never finished (the app was stopped).
    static func removeUnfinishedRenders(in parent: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasSuffix(unfinishedSuffix) {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    /// The renderer's own work folders in tmp, which it removes itself unless the
    /// app was stopped mid-render. Only ones far older than any render can run.
    static func removeAbandonedRendererFolders(olderThan age: TimeInterval = 3600) {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix("PowerPointRender-") {
            let url = tmp.appendingPathComponent(name)
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
            if Date().timeIntervalSince(created) > age { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Validation

    static let manifestName = "cache.json"

    /// What the cache records about how it was made. Nothing in it is used as a
    /// path: image names come from `slideCount` alone.
    struct Manifest: Codable, Equatable {
        var rendererVersion: Int
        var documentID: UUID
        var sourceSize: Int64
        var sourceModified: Date
        var sourceSHA256: String
        var slideCount: Int
        var imageFormat: String
        var longestSidePixels: Int
        var createdAt: Date
    }

    struct SourceFacts: Equatable {
        var size: Int64
        var modified: Date
    }

    static func sourceFacts(_ url: URL) throws -> SourceFacts {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return SourceFacts(size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
        } catch {
            throw TaskLensError.persistenceFailed(operation: .read, details: "PowerPoint file: \(error)")
        }
    }

    /// The slide images when the cache in `directory` is complete and made from
    /// this file by this renderer; otherwise nil (and the caller renders again).
    func validSlides(in directory: URL, document: DocumentID, source: SourceFacts, fileURL: URL) -> [URL]? {
        Self.validate(directory, document: document, source: source, fileURL: fileURL,
                      root: documentService.generatedFilesDirectory(for: document),
                      longestSidePixels: options.longestSidePixels)
    }

    static func validate(_ directory: URL, document: DocumentID, source: SourceFacts, fileURL: URL,
                         root: URL, longestSidePixels: Int) -> [URL]? {
        let fileManager = FileManager.default
        // The cache must be a real folder inside the document's own folder.
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/"),
              let manifestData = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              manifest.rendererVersion == rendererVersion,
              manifest.documentID == document.rawValue,
              manifest.imageFormat == "png",
              manifest.longestSidePixels == longestSidePixels,
              (1...10_000).contains(manifest.slideCount),
              manifest.sourceSize == source.size
        else { return nil }
        // Same size but touched since: the content decides.
        if manifest.sourceModified != source.modified {
            guard let hash = try? sha256(of: fileURL), hash == manifest.sourceSHA256 else { return nil }
        }
        let expected = (0..<manifest.slideCount).map(fileName(index:))
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path),
              names.sorted() == (expected + [manifestName]).sorted()
        else { return nil }
        let urls = expected.map { directory.appendingPathComponent($0) }
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  isReadableImage(url)
            else { return nil }
        }
        return urls
    }

    /// A PNG whose header Image I/O reads, without decoding its pixels.
    static func isReadableImage(_ url: URL) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let type = CGImageSourceGetType(source), (type as String) == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0
        else { return false }
        return true
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileName(index: Int) -> String { String(format: "slide-%03d.png", index + 1) }

    /// Classifies a render failure. A refused deck is `speakerNotesUnsupported`
    /// only when OfficeImport's code and the deck's own parts both say so.
    @MainActor
    static func failure(for error: any Error, fileURL: URL) -> PowerPointFailure {
        guard case .unsupportedContent? = error as? PowerPointRenderError else { return PowerPointFailure(error) }
        // "<domain> <code>", recorded by the renderer that just failed; renders run one at a time.
        let detail = PowerPointRenderer.lastFailureDetail?.split(separator: " ") ?? []
        let code = detail.count == 2 && detail[0].contains("OfficeImport") ? Int(detail[1]) : nil
        let hasNotes = (try? PowerPointDeck.read(contentsOf: fileURL))?.hasSpeakerNotes
        return PowerPointFailure(error, officeImportCode: code, hasSpeakerNotes: hasNotes)
    }

    // MARK: One render per document

    @MainActor private static let renders = Renders()

    /// Renders in progress, so a document being rendered is not rendered twice.
    /// A caller that is cancelled stops waiting with `cancelled`; the render is
    /// cancelled too when nobody else is waiting for it.
    ///
    /// A render stays here until it has finished, even when cancelled: a cancelled
    /// render can still be writing its staging folder or moving it into place,
    /// so the next render of that document (Try Again, opening it again) waits
    /// for it to end before touching the same folders. A finished render is
    /// never joined, so a retry always makes a fresh attempt.
    @MainActor
    private final class Renders {
        @MainActor
        private final class Render {
            var task: Task<[URL], any Error>?
            var waiters = 0
            /// Set inside the task, before any waiter sees its result.
            var isFinished = false
            var canJoin: Bool { !isFinished && task?.isCancelled == false }
        }

        private var renders: [DocumentID: Render] = [:]

        func run(_ id: DocumentID, _ body: @escaping @Sendable @MainActor () async throws -> [URL]) async throws -> [URL] {
            let render: Render
            if let running = renders[id], running.canJoin {
                render = running
            } else {
                let previous = renders[id]?.task
                let next = Render()
                next.task = Task {
                    defer {
                        next.isFinished = true
                        if self.renders[id] === next { self.renders[id] = nil }
                    }
                    if let previous { _ = await previous.result }
                    if Task.isCancelled { throw PowerPointFailure.cancelled }
                    return try await body()
                }
                renders[id] = next
                render = next
            }
            guard let task = render.task else { throw PowerPointFailure.unknown }
            render.waiters += 1
            defer { render.waiters -= 1 }
            let urls = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { @MainActor in if render.waiters <= 1 { render.task?.cancel() } }
            }
            if Task.isCancelled { throw PowerPointFailure.cancelled }
            return urls
        }

        /// True while a render of this document runs or is still finishing. For tests.
        func isRendering(_ id: DocumentID) -> Bool { renders[id] != nil }
    }

    /// True while a render of this document runs or is still finishing after a cancel.
    @_spi(Testing) @MainActor
    public static func isRendering(_ id: DocumentID) -> Bool { renders.isRendering(id) }

    // MARK: Diagnostics

    public enum Event: Sendable, Equatable { case hit, render }

    /// What this cache did: opens served from the cache, and renders.
    public final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var _hits = 0
        private var _renders = 0

        public var hits: Int { lock.withLock { _hits } }
        public var renders: Int { lock.withLock { _renders } }

        func record(_ event: Event) {
            lock.withLock {
                switch event {
                case .hit: _hits += 1
                case .render: _renders += 1
                }
            }
        }
    }
}
