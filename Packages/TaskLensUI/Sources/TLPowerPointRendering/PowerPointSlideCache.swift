import Foundation
import TLCoreServices
import TLDomain
import TLFoundation

/// The slide images of imported PowerPoint files, rendered by
/// `PowerPointRenderer` and kept in the document's generated files folder,
/// which `DocumentService` deletes with the document.
///
/// Opening the same file again uses the images already there instead of
/// rendering again. The renderer moves the slides folder into place only after
/// every slide rendered, so a folder that is there is a complete set. Opening a
/// file that is already rendering waits for that render instead of starting
/// another one.
///
/// Errors are reported as `TaskLensError`: `unsupportedContent` for files
/// WebKit can't open (including decks with speaker notes) and
/// `persistenceFailed(.read)` for anything else, with nothing left behind.
public struct PowerPointSlideCache: PowerPointSlideImageProviding {
    private let documentService: DocumentService
    private let options: PowerPointRenderer.Options

    public init(documentService: DocumentService, options: PowerPointRenderer.Options = PowerPointRenderer.Options()) {
        self.documentService = documentService
        var options = options
        options.format = .png
        self.options = options
    }

    /// The folder holding a document's `slide-001.png`, `slide-002.png`...
    public func slidesDirectory(for documentID: DocumentID) -> URL {
        documentService.generatedFilesDirectory(for: documentID).appendingPathComponent("Slides", isDirectory: true)
    }

    public func slideImage(for documentID: DocumentID, index: Int) -> URL {
        slidesDirectory(for: documentID).appendingPathComponent(Self.fileName(index: index))
    }

    public func slideImages(for document: Document, fileURL: URL) async throws -> [URL] {
        let directory = slidesDirectory(for: document.id)
        if let existing = Self.renderedSlides(in: directory) { return existing }
        return try await Self.renders.run(document.id) { [options] in
            if let existing = Self.renderedSlides(in: directory) { return existing }
            // Whatever is there is not a complete set; the renderer needs the folder gone.
            try? FileManager.default.removeItem(at: directory)
            do {
                return try await PowerPointRenderer().render(fileURL, to: directory, options: options).slides.map(\.fileURL)
            } catch {
                throw Self.taskLensError(for: error)
            }
        }
    }

    static func fileName(index: Int) -> String { String(format: "slide-%03d.png", index + 1) }

    /// The images in `directory` when they are exactly slide-001.png to slide-N.png, N ≥ 1.
    static func renderedSlides(in directory: URL) -> [URL]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path), !names.isEmpty else { return nil }
        let expected = (0..<names.count).map { fileName(index: $0) }
        guard names.sorted() == expected else { return nil }
        return expected.map { directory.appendingPathComponent($0) }
    }

    static func taskLensError(for error: any Error) -> any Error {
        switch error as? PowerPointRenderError {
        case .invalidPresentation, .unsupportedContent:
            TaskLensError.unsupportedContent(type: "pptx")
        case .cancelled:
            CancellationError()
        case .some(let failure):
            TaskLensError.persistenceFailed(operation: .read, details: "PowerPoint slides: \(failure)")
        case nil:
            error is CancellationError
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
}
