import Foundation
import ImageIO
import TLDomain
import TLFoundation

/// Loads imported images as a presentation: one slide per image, in exactly
/// the order the caller gives. Nothing is sorted.
///
/// Each file is checked by reading its header with Image I/O; pixels are never
/// decoded, so building a 100-image presentation stays cheap. Slides hold the
/// document ID only, and the presentation UI decodes an image when it shows it.
/// Any format Image I/O can read works (JPEG, PNG, HEIC, WebP, GIF, TIFF...).
/// An animated GIF is one slide; its first frame is the image.
///
/// A PowerPoint file is loaded the same way, from the slide images rendered
/// from it (`init(powerPoint:slideImages:...)`): one slide per image, in the
/// order the renderer gives, each checked from its header. The images stay
/// where the renderer left them.
///
/// It only reads documents. Images have no reading position, and nothing here
/// touches a document's `lastReadPage` or `lastOpenedAt`.
public struct ImagePresentationLoader: PresentationLoading {
    public let documentIDs: [DocumentID]
    /// The presentation title. Nil uses the first image's title.
    public let title: String?
    private let documentService: DocumentService
    private let clock: any DateProviding
    /// Set when the images are the rendered slides of one PowerPoint file.
    private let slideImages: (any PowerPointSlideImageProviding)?

    public init(
        documentIDs: [DocumentID],
        title: String? = nil,
        documentService: DocumentService,
        clock: any DateProviding = SystemDateProvider()
    ) {
        self.documentIDs = documentIDs
        self.title = title
        self.documentService = documentService
        self.clock = clock
        slideImages = nil
    }

    /// Loads an imported PowerPoint file from the slide images `slideImages`
    /// renders (or already rendered) for it.
    public init(
        powerPoint documentID: DocumentID,
        slideImages: any PowerPointSlideImageProviding,
        documentService: DocumentService,
        clock: any DateProviding = SystemDateProvider()
    ) {
        documentIDs = [documentID]
        title = nil
        self.documentService = documentService
        self.clock = clock
        self.slideImages = slideImages
    }

    /// Fails with `validationFailed(.emptyContent)` for no images, `notFound` for
    /// an unknown document, `unsupportedContent` for a document that is not an
    /// image, and `persistenceFailed(.read)` for an image file that cannot be read.
    ///
    /// For a PowerPoint file it also fails with whatever the slide renderer
    /// throws; no presentation is made unless every slide image is readable.
    public func loadPresentation() async throws -> PresentationDocument {
        if let slideImages, let id = documentIDs.first { return try await loadPowerPoint(id, from: slideImages) }
        guard !documentIDs.isEmpty else { throw TaskLensError.validationFailed(.emptyContent) }
        var documents: [Document] = []
        documents.reserveCapacity(documentIDs.count)
        for id in documentIDs {
            let document = try await documentService.document(id: id)
            guard document.kind == .image else { throw TaskLensError.unsupportedContent(type: document.kind.rawValue) }
            try Self.checkReadable(at: documentService.fileURL(for: document))
            documents.append(document)
        }
        return try PresentationDocument.images(
            documents, title: title ?? documents[0].title, createdAt: clock.now()
        )
    }

    private func loadPowerPoint(_ id: DocumentID, from slideImages: any PowerPointSlideImageProviding) async throws -> PresentationDocument {
        let document = try await documentService.document(id: id)
        guard document.kind == .powerpoint else { throw TaskLensError.unsupportedContent(type: document.kind.rawValue) }
        let images = try await slideImages.slideImages(for: document, fileURL: documentService.fileURL(for: document))
        for url in images { try Self.checkReadable(at: url) }
        return try PresentationDocument.powerPoint(document, renderedSlideCount: images.count, createdAt: clock.now())
    }

    /// Confirms the file is an image Image I/O can read, from its header only.
    static func checkReadable(at url: URL) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0
        else {
            throw TaskLensError.persistenceFailed(operation: .read, details: "The image could not be opened.")
        }
    }
}
