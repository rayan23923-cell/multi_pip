import CoreGraphics
import Foundation
import TLDomain
import TLFoundation

/// Loads an imported PDF as a presentation: one slide per page, in page order.
///
/// It only reads. The document's `lastReadPage` and `lastOpenedAt` stay as the
/// PDF reader left them, so presenting never moves the reading position.
///
/// The page count comes from Core Graphics, which reads the same file PDFKit
/// renders and keeps this service free of UI frameworks. Each slide stores the
/// document and the zero-based page index, which is what the presentation UI
/// needs to render the page with PDFKit later.
public struct PDFPresentationLoader: PresentationLoading {
    public let documentID: DocumentID
    private let documentService: DocumentService
    private let clock: any DateProviding

    public init(documentID: DocumentID, documentService: DocumentService, clock: any DateProviding = SystemDateProvider()) {
        self.documentID = documentID
        self.documentService = documentService
        self.clock = clock
    }

    /// Fails with `notFound` for an unknown document, `unsupportedContent` for a
    /// document that is not a PDF, and `persistenceFailed(.read)` for a file that
    /// cannot be opened: damaged, password protected, or without pages (Core
    /// Graphics will not open a PDF that has none).
    public func loadPresentation() async throws -> PresentationDocument {
        let document = try await documentService.document(id: documentID)
        guard document.kind == .pdf else { throw TaskLensError.unsupportedContent(type: document.kind.rawValue) }
        let pageCount = try Self.pageCount(at: documentService.fileURL(for: document))
        return try PresentationDocument.pdf(document, pageCount: pageCount, createdAt: clock.now())
    }

    static func pageCount(at url: URL) throws -> Int {
        guard let pdf = CGPDFDocument(url as CFURL) else {
            throw TaskLensError.persistenceFailed(operation: .read, details: "The PDF could not be opened.")
        }
        if pdf.isEncrypted, !pdf.isUnlocked, !pdf.unlockWithPassword("") {
            throw TaskLensError.persistenceFailed(operation: .read, details: "The PDF is password protected.")
        }
        return pdf.numberOfPages
    }
}
