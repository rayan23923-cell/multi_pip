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
/// that is already rendering waits for that render instead of starting another.
///
/// Errors are reported as `TaskLensError`: `unsupportedContent` for files
/// WebKit can't open (including decks with speaker notes) and
/// `persistenceFailed(.read)` for anything else, with nothing left behind.
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
        let source = try Self.sourceFacts(fileURL)
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
            events.record(.render)
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
        let staging = parent.appendingPathComponent("Slides-\(UUID().uuidString)\(Self.unfinishedSuffix)", isDirectory: true)
        do {
            let hash = try await Task.detached(priority: .userInitiated) { try Self.sha256(of: fileURL) }.value
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
            try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent(Self.manifestName), options: .atomic)
            // The finished render becomes the cache in one rename.
            try FileManager.default.moveItem(at: staging, to: directory)
            return (0..<output.slides.count).map { directory.appendingPathComponent(Self.fileName(index: $0)) }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Self.taskLensError(for: error)
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

    static func taskLensError(for error: any Error) -> any Error {
        switch error as? PowerPointRenderError {
        case .invalidPresentation, .unsupportedContent:
            TaskLensError.unsupportedContent(type: "pptx")
        case .cancelled:
            CancellationError()
        case .some(let failure):
            TaskLensError.persistenceFailed(operation: .read, details: "PowerPoint slides: \(failure)")
        case nil:
            error is CancellationError || error is TaskLensError
                ? error
                : TaskLensError.persistenceFailed(operation: .read, details: "PowerPoint slides: \(error)")
        }
    }

    // MARK: One render per document

    @MainActor private static let renders = Renders()

    /// Renders in progress, so a document being rendered is not rendered twice.
    @MainActor
    private final class Renders {
        private var tasks: [DocumentID: Task<[URL], any Error>] = [:]

        func run(_ id: DocumentID, _ render: @escaping @Sendable @MainActor () async throws -> [URL]) async throws -> [URL] {
            if let task = tasks[id] { return try await task.value }
            let task = Task { try await render() }
            tasks[id] = task
            defer { tasks[id] = nil }
            return try await task.value
        }
    }

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
