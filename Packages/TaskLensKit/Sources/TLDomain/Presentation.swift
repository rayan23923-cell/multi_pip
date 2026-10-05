import Foundation
import TLFoundation

public typealias PresentationID = Identifier<PresentationDocument>

/// Where a presentation's slides come from.
///
/// `pdf`, `image` and `powerpoint` can be presented. A PowerPoint file is shown
/// as the slide images rendered from it. `unknown` exists so stored data has a name for it.
public enum PresentationSourceType: String, Codable, Sendable, CaseIterable {
    case pdf
    case image
    case powerpoint
    case unknown

    /// True for the sources TaskLens can present today.
    public var isSupported: Bool {
        switch self {
        case .pdf, .image, .powerpoint: true
        case .unknown: false
        }
    }
}

/// What one slide shows.
public enum PresentationSlideSource: Codable, Sendable, Hashable {
    /// A page of an imported PDF. `pageIndex` is zero-based.
    case pdfPage(DocumentID, pageIndex: Int)
    /// An imported image, shown whole.
    case image(DocumentID)
    /// An image rendered from an imported document (a PowerPoint slide), shown
    /// whole like `image`. `index` is zero-based among the rendered images.
    case renderedImage(DocumentID, index: Int)

    public var documentID: DocumentID {
        switch self {
        case .pdfPage(let id, _), .image(let id), .renderedImage(let id, _): id
        }
    }
}

/// One slide of a presentation.
public struct PresentationSlide: Codable, Sendable, Hashable, Identifiable {
    /// Zero-based position in the presentation.
    public let index: Int
    public let source: PresentationSlideSource

    public init(index: Int, source: PresentationSlideSource) {
        self.index = index
        self.source = source
    }

    public var id: Int { index }
    /// One-based number shown to the user.
    public var displayNumber: Int { index + 1 }
}

/// The content of a presentation: which document, and its slides in order.
///
/// It points at documents already imported through `DocumentService` and does
/// not copy files. It holds no position: the current slide lives in
/// `PresentationState`, and a PDF's `Document.lastReadPage` is never read or
/// written for presenting.
public struct PresentationDocument: Codable, Sendable, Equatable, Identifiable {
    public let id: PresentationID
    /// The source document: the PDF, or the first image of an image set.
    public let documentID: DocumentID
    public var title: String
    public let sourceType: PresentationSourceType
    public let slides: [PresentationSlide]
    public let createdAt: Date

    public init(
        id: PresentationID = PresentationID(),
        documentID: DocumentID,
        title: String,
        sourceType: PresentationSourceType,
        slides: [PresentationSlide],
        createdAt: Date
    ) {
        self.id = id
        self.documentID = documentID
        self.title = title
        self.sourceType = sourceType
        self.slides = slides
        self.createdAt = createdAt
    }

    public var slideCount: Int { slides.count }

    /// The slide at a zero-based index, or nil when out of range.
    public func slide(at index: Int) -> PresentationSlide? {
        slides.indices.contains(index) ? slides[index] : nil
    }

    /// One slide per page of an imported PDF.
    public static func pdf(_ document: Document, pageCount: Int, createdAt: Date) throws -> PresentationDocument {
        guard document.kind == .pdf else { throw TaskLensError.unsupportedContent(type: document.kind.rawValue) }
        guard pageCount > 0 else { throw TaskLensError.validationFailed(.emptyContent) }
        let slides = (0..<pageCount).map { PresentationSlide(index: $0, source: .pdfPage(document.id, pageIndex: $0)) }
        return PresentationDocument(
            documentID: document.id, title: document.title, sourceType: .pdf, slides: slides, createdAt: createdAt
        )
    }

    /// One slide per image, in the given order.
    public static func images(_ documents: [Document], title: String, createdAt: Date) throws -> PresentationDocument {
        guard let first = documents.first else { throw TaskLensError.validationFailed(.emptyContent) }
        if let other = documents.first(where: { $0.kind != .image }) {
            throw TaskLensError.unsupportedContent(type: other.kind.rawValue)
        }
        let slides = documents.enumerated().map { PresentationSlide(index: $0.offset, source: .image($0.element.id)) }
        return PresentationDocument(
            documentID: first.id, title: title, sourceType: .image, slides: slides, createdAt: createdAt
        )
    }

    /// One slide per image rendered from an imported PowerPoint file, in the
    /// order they were rendered. The images are not copied or imported.
    public static func powerPoint(_ document: Document, renderedSlideCount: Int, createdAt: Date) throws -> PresentationDocument {
        guard document.kind == .powerpoint else { throw TaskLensError.unsupportedContent(type: document.kind.rawValue) }
        guard renderedSlideCount > 0 else { throw TaskLensError.validationFailed(.emptyContent) }
        let slides = (0..<renderedSlideCount).map { PresentationSlide(index: $0, source: .renderedImage(document.id, index: $0)) }
        return PresentationDocument(
            documentID: document.id, title: document.title, sourceType: .powerpoint, slides: slides, createdAt: createdAt
        )
    }
}
