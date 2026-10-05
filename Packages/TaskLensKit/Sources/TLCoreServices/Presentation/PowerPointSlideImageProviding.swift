import Foundation
import TLDomain

/// The slide images of an imported PowerPoint file, one image file per slide.
///
/// The app renders them offline with WebKit (A9.2) and keeps them with the
/// document; tests can give prepared images. A presentation of the file is
/// then loaded like any image presentation, by `ImagePresentationLoader`.
public protocol PowerPointSlideImageProviding: Sendable {
    /// The slide images in presentation order, rendered first when there are
    /// none yet. All or nothing: it throws rather than return some of them.
    /// The app's provider throws `PowerPointFailure`.
    func slideImages(for document: Document, fileURL: URL) async throws -> [URL]

    /// Where the image of a zero-based slide is, once rendered.
    func slideImage(for documentID: DocumentID, index: Int) -> URL
}
