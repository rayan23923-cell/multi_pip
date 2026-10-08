import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLFoundation
import TLLocalization

/// Import PDF on the PowerPoint failure screen (A9.5.3): the person picks a
/// PDF they exported themselves, it is imported like any other document, and
/// the screen opens it as an ordinary PDF presentation.
///
/// TaskLens converts nothing and sends nothing anywhere. The picked file goes
/// through `DocumentService.importFile`, the same import as the library (type,
/// size and storage checks), and becomes a normal `.pdf` document with no link
/// to the PowerPoint file. It is then opened once with `PDFPresentationLoader`,
/// the loader the presentation will use; a file it can't open (damaged,
/// password protected, no pages) is removed again, so no broken document stays
/// in the library. Nothing here creates a presentation session, a slide cache
/// or a reading position: the PDF presentation that opens next does that, as
/// for any PDF.
@MainActor
@Observable
public final class PDFFallbackImport {
    /// Where the PDF comes from: the system file picker, or (UI tests only) a
    /// scripted pick. A nil URL means the person cancelled the picker.
    public enum Picker {
        case system
        case scripted(@MainActor () -> URL?)
    }

    /// True while the system file picker is shown.
    public var isChoosing = false
    public private(set) var isImporting = false
    /// Shown with the existing error alert; the failure screen stays behind it.
    public var errorMessage: String?
    /// The imported PDF, once it is ready to present.
    public private(set) var importedPDF: DocumentID?

    /// The PowerPoint file that couldn't be presented. Only its workspace is
    /// used, so the PDF is listed in the same library.
    public let failedPresentation: DocumentID
    private let documentService: DocumentService
    private let picker: Picker

    public init(failedPresentation: DocumentID, documentService: DocumentService, picker: Picker = .system) {
        self.failedPresentation = failedPresentation
        self.documentService = documentService
        self.picker = picker
    }

    /// Shows the picker. Ignored while an import is running.
    public func choosePDF() {
        guard !isImporting else { return }
        switch picker {
        case .system:
            isChoosing = true
        case .scripted(let pick):
            let url = pick()
            Task { await self.picked(url) }
        }
    }

    /// The picker closed: with a file, or nil when the person cancelled.
    /// Returns the imported PDF; nil leaves the failure screen as it was.
    @discardableResult
    public func picked(_ url: URL?) async -> DocumentID? {
        isChoosing = false
        guard let url, !isImporting else { return nil }
        isImporting = true
        defer { isImporting = false }
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

        let workspaceID = try? await documentService.document(id: failedPresentation).workspaceID
        let document: Document
        do {
            document = try await documentService.importFile(at: url, workspaceID: workspaceID)
        } catch {
            errorMessage = L10n.message(for: error)
            return nil
        }
        do {
            guard document.kind == .pdf else { throw TaskLensError.unsupportedContent(type: document.kind.rawValue) }
            _ = try await PDFPresentationLoader(documentID: document.id, documentService: documentService).loadPresentation()
        } catch {
            try? await documentService.delete(document.id)
            errorMessage = L10n.string(.documentsOpenFailed)
            return nil
        }
        importedPDF = document.id
        return document.id
    }

    /// The system picker reported an error instead of a file or a cancel.
    public func pickerFailed() {
        isChoosing = false
        errorMessage = L10n.string(.documentsOpenFailed)
    }
}
