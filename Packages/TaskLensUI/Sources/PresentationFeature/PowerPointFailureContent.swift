import TLCoreServices
import TLLocalization

/// What the failure screen says and offers for a PowerPoint file that can't be
/// presented (A9.5.2), from the category A9.5.1 classified. It never sees the
/// underlying error: no WebKit code, file path, part name or cache detail.
///
/// `actions` are in screen order; the first is the prominent one. Try Again
/// appears only where another attempt can change the result; Import PDF only
/// where the file is a presentation that can be exported as PDF.
public struct PowerPointFailureContent: Equatable, Sendable {
    public enum Action: String, Equatable, Sendable {
        case retry, importPDF, cancel
    }

    public let title: L10nKey
    public let message: L10nKey
    public let symbolName: String
    public let actions: [Action]

    public var canRetry: Bool { actions.contains(.retry) }
    public var canImportPDF: Bool { actions.contains(.importPDF) }

    /// Nil for `cancelled`: leaving is the person's own choice, not a failure to show.
    public init?(_ failure: PowerPointFailure) {
        switch failure {
        case .speakerNotesUnsupported:
            self.init(.presentationPptxNotesTitle, .presentationPptxNotesMessage, "text.bubble", [.importPDF, .cancel])
        case .unsupportedPresentation:
            self.init(.presentationPptxUnsupportedTitle, .presentationPptxUnsupportedMessage, "doc.badge.ellipsis", [.importPDF, .cancel])
        case .renderingFailed, .unknown, .corruptedCache:
            // A broken cache was already rebuilt once; to the person it is the same as any rendering failure.
            self.init(.presentationPptxFailedTitle, .presentationPptxFailedMessage, "exclamationmark.triangle", [.retry, .importPDF, .cancel])
        case .missingResource:
            self.init(.presentationPptxFailedTitle, .presentationPptxMissingMessage, "exclamationmark.triangle", [.retry, .cancel])
        case .invalidSource:
            self.init(.presentationPptxInvalidTitle, .presentationPptxInvalidMessage, "doc.questionmark", [.retry, .cancel])
        case .timeout:
            self.init(.presentationPptxTimeoutTitle, .presentationPptxTimeoutMessage, "clock.badge.exclamationmark", [.retry, .importPDF, .cancel])
        case .securityRejected:
            // Never retried: the import check gives the same answer every time, and it is never bypassed.
            self.init(.presentationPptxSecurityTitle, .presentationPptxSecurityMessage, "lock.doc", [.cancel])
        case .storageFailure:
            self.init(.presentationPptxStorageTitle, .presentationPptxStorageMessage, "externaldrive.badge.exclamationmark", [.retry, .cancel])
        case .cancelled:
            return nil
        }
    }

    /// The same content without one action, e.g. Import PDF where nothing handles it.
    public func removing(_ action: Action) -> PowerPointFailureContent {
        PowerPointFailureContent(title, message, symbolName, actions.filter { $0 != action })
    }

    private init(_ title: L10nKey, _ message: L10nKey, _ symbolName: String, _ actions: [Action]) {
        self.title = title
        self.message = message
        self.symbolName = symbolName
        self.actions = actions
    }
}
