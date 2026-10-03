import CoreGraphics
import Foundation
import ImageIO
import Observation
import PDFKit
import TLCoreServices
import TLDomain
import TLNavigation

/// Opens a presentation through the engine and gives the screen what it needs
/// to draw the current slide.
///
/// Every slide change goes through `PresentationEngine`; this model never sets a
/// slide itself. It records nothing for Resume and never touches a document's
/// `lastReadPage`, so presenting a PDF does not move its reading position.
/// There is no timer: slides change only when the user asks.
@MainActor
@Observable
public final class PresentationModel {
    public let request: PresentationRequest
    public let engine: PresentationEngine
    /// The PDF being presented. PDFKit reads pages only when one is drawn.
    public private(set) var pdf: PDFDocument?
    /// Image titles seen so far, for VoiceOver.
    public private(set) var imageTitles: [DocumentID: String] = [:]

    private let documentService: DocumentService

    public init(request: PresentationRequest, documentService: DocumentService, engine: PresentationEngine? = nil) {
        self.request = request
        self.documentService = documentService
        self.engine = engine ?? PresentationEngine()
    }

    public var title: String { engine.document?.title ?? "" }
    public var phase: PresentationState.Phase { engine.phase }
    public var hasSlides: Bool { engine.state.hasSlides }
    /// One-based, for display.
    public var slideNumber: Int { engine.state.displaySlideNumber }
    public var slideCount: Int { engine.slideCount }
    public var canGoBack: Bool { hasSlides && engine.currentSlide > 0 }
    public var canGoForward: Bool { hasSlides && engine.currentSlide + 1 < engine.slideCount }
    public var currentSlide: PresentationSlide? { engine.currentSlideContent }

    /// What VoiceOver reads as the slide's content: the image's name, or the PDF's title.
    public var currentSlideDescription: String {
        switch currentSlide?.source {
        case .image(let id): imageTitles[id] ?? ""
        case .pdfPage: title
        case nil: ""
        }
    }

    public func load() async {
        guard engine.phase == .idle else { return }
        switch request {
        case .pdf(let id):
            await engine.load(from: PDFPresentationLoader(documentID: id, documentService: documentService))
            if engine.state.hasSlides, let document = try? await documentService.document(id: id) {
                pdf = PDFDocument(url: documentService.fileURL(for: document))
            }
        case .images(let ids):
            await engine.load(from: ImagePresentationLoader(documentIDs: ids, documentService: documentService))
        }
    }

    // MARK: Commands (all through the engine)

    public func next() { _ = engine.next() }
    public func previous() { _ = engine.previous() }

    /// `number` is one-based, as the user types it.
    public func goToSlide(number: Int) {
        _ = engine.goToSlide(number - 1)
    }

    // MARK: Rendering

    /// The image for an image slide, decoded at no more than `maxPixelSize` on
    /// its longest side. Only the slide on screen is decoded.
    public func image(for id: DocumentID, maxPixelSize: CGFloat) async -> CGImage? {
        guard let document = try? await documentService.document(id: id) else { return nil }
        imageTitles[id] = document.title
        let url = documentService.fileURL(for: document)
        return await Task.detached(priority: .userInitiated) {
            Self.downsampledImage(at: url, maxPixelSize: maxPixelSize)
        }.value
    }

    nonisolated static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maxPixelSize.rounded(.up)), 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
