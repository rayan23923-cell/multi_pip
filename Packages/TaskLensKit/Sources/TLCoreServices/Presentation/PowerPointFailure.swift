import Foundation
import TLFoundation

/// Why an imported PowerPoint file could not be presented (A9.5).
///
/// One category per thing the user could be told or do differently. It
/// carries no WebKit, XML or ZIP detail, no path and no file content; those
/// stay in logs. `speakerNotesUnsupported` is used only when the renderer's
/// answer identifies it (see `init(_:officeImportCode:hasSpeakerNotes:)`);
/// a cause that isn't known is never guessed.
public enum PowerPointFailure: Error, Equatable, Sendable, CaseIterable {
    /// The file is not a PowerPoint package TaskLens can read: damaged, truncated, another kind of file, or missing parts.
    case invalidSource
    /// A well-formed deck that iOS refuses to open, for a reason it doesn't give.
    case unsupportedPresentation
    /// iOS opened the deck, but the slides it produced can't be trusted (count, size, snapshot) or its web view failed.
    case renderingFailed
    /// iOS refused the deck, and the deck has speaker notes: the known limitation.
    case speakerNotesUnsupported
    /// A slide, or a picture, chart or layout a slide uses, is not in the package.
    case missingResource
    /// The slide images were rendered but could not be read back.
    case corruptedCache
    /// The render ran past its time limit.
    case timeout
    /// The person left before the render finished. Not an error to show.
    case cancelled
    /// The import check (A9.1) rejects the file: a macro project, unsafe paths or ZIP bomb sizes. Never rendered.
    case securityRejected
    /// The stored file or the slide images could not be read or written.
    case storageFailure
    case unknown

    /// OfficeImport's error when it refuses a deck. In the A8 audit and the A9.2
    /// renderer tests every deck with speaker notes got it, and the same decks
    /// without notes rendered.
    public static let officeImportRefusalCode = 912

    /// Classifies an error from rendering or loading.
    ///
    /// iOS reports a refused deck only as an OfficeImport error code, never
    /// naming the part it refused. So a refusal is `speakerNotesUnsupported`
    /// only when the code is the refusal code *and* the deck has speaker notes;
    /// any other refusal, or one where either fact is unknown, is
    /// `unsupportedPresentation`.
    public init(_ error: any Error, officeImportCode: Int? = nil, hasSpeakerNotes: Bool? = nil) {
        switch error {
        case let failure as PowerPointFailure:
            self = failure
        case let failure as PowerPointRenderError:
            switch failure {
            case .invalidPresentation: self = .invalidSource
            case .unsupportedContent:
                let isNotes = officeImportCode == Self.officeImportRefusalCode && hasSpeakerNotes == true
                self = isNotes ? .speakerNotesUnsupported : .unsupportedPresentation
            case .resourceMissing: self = .missingResource
            case .renderingFailed(.writeFailed): self = .storageFailure
            case .renderingFailed, .webViewFailed: self = .renderingFailed
            case .timeout: self = .timeout
            case .cancelled: self = .cancelled
            }
        case is CancellationError:
            self = .cancelled
        case let failure as TaskLensError:
            switch failure {
            case .validationFailed(.invalidPresentation): self = .invalidSource
            case .notFound: self = .invalidSource
            case .unsupportedContent: self = .unsupportedPresentation
            case .persistenceFailed: self = .storageFailure
            default: self = .unknown
            }
        default:
            self = .unknown
        }
    }

    /// The error the presentation engine maps to its phase: the same as before
    /// A9.5 (`unsupportedSource` for files iOS won't open, `unreadable` for the rest).
    public var presentationError: any Error {
        switch self {
        case .invalidSource, .unsupportedPresentation, .speakerNotesUnsupported, .securityRejected:
            TaskLensError.unsupportedContent(type: "pptx")
        case .cancelled:
            CancellationError()
        case .renderingFailed, .missingResource, .corruptedCache, .timeout, .storageFailure, .unknown:
            TaskLensError.persistenceFailed(operation: .read, details: "PowerPoint: \(self)")
        }
    }
}
