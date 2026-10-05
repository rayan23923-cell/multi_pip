import CryptoKit
import Foundation
import TLFoundation

public typealias PresentationSessionID = Identifier<PresentationSession>

/// What was presented: one PDF, an ordered list of images, or one PowerPoint file.
///
/// Two image presentations with the same images in a different order are
/// different presentations, because their slide numbers mean different images.
public enum PresentationSessionSource: Codable, Sendable, Hashable {
    case pdf(DocumentID)
    case images([DocumentID])
    case powerPoint(DocumentID)

    public var documentIDs: [DocumentID] {
        switch self {
        case .pdf(let id), .powerPoint(let id): [id]
        case .images(let ids): ids
        }
    }

    /// The session's storage identity, derived from the source so the same
    /// presentation always maps to one record and can never get a duplicate.
    /// A PDF or PowerPoint file uses its document's UUID (a document is never
    /// both); an image list uses a UUID made from a SHA-256 of its ordered
    /// document IDs.
    public var sessionID: PresentationSessionID {
        switch self {
        case .pdf(let id), .powerPoint(let id):
            return PresentationSessionID(id.rawValue)
        case .images(let ids):
            let key = "images:" + ids.map(\.uuidString).joined(separator: ",")
            var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
            bytes[6] = (bytes[6] & 0x0F) | 0x50 // name-based UUID (version 5 layout)
            bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
            let uuid = UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
            return PresentationSessionID(uuid)
        }
    }
}

/// Where the user left a presentation, so it can open there again.
///
/// Only presentation state is kept: the slide, how many slides there were, and
/// the Auto Play interval. Never timers, tasks, rendered pages or images, and
/// never the PDF reader's `lastReadPage`, which is a separate position.
public struct PresentationSession: Entity {
    public static let entityName = "presentationSession"

    public let id: PresentationSessionID
    public let source: PresentationSessionSource
    /// Zero-based, like `PresentationState.currentSlide`.
    public var currentSlide: Int
    /// The slide count when saved. A different count on reopening means the
    /// source changed, and the saved slide is no longer trusted.
    public var slideCount: Int
    /// Seconds per slide for Auto Play, or nil to use the default.
    public var autoPlayInterval: Int?
    public var lastViewedAt: Date

    public init(
        source: PresentationSessionSource,
        currentSlide: Int,
        slideCount: Int,
        autoPlayInterval: Int?,
        lastViewedAt: Date
    ) {
        id = source.sessionID
        self.source = source
        self.currentSlide = currentSlide
        self.slideCount = slideCount
        self.autoPlayInterval = autoPlayInterval
        self.lastViewedAt = lastViewedAt
    }

    /// The slide to open on for a presentation that now has `count` slides, or
    /// nil when this saved state no longer fits it.
    public func restorableSlide(forSlideCount count: Int) -> Int? {
        guard count == slideCount, (0..<count).contains(currentSlide) else { return nil }
        return currentSlide
    }
}
