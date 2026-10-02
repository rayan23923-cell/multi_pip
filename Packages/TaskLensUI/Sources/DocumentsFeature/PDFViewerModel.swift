import Foundation
import Observation
import PDFKit
import TLCoreServices
import TLDomain
import TLLocalization

/// Reads a PDF: pages, search, text extraction and saving to a session.
@MainActor
@Observable
public final class PDFViewerModel: ContextProducing {
    public let documentID: DocumentID
    public private(set) var document: Document?
    public private(set) var pdf: PDFDocument?
    /// Zero-based index of the visible page.
    public private(set) var currentPage = 0
    public var searchQuery = ""
    public private(set) var matches: [PDFSelection] = []
    public private(set) var matchIndex: Int?
    /// Text of the current page when the user asked for it. Empty means the page has no text layer.
    public private(set) var extractedText: String?
    public private(set) var savedItemCount = 0
    public private(set) var failedToOpen = false
    public var errorMessage: String?

    private let documentService: DocumentService
    private let toolCapture: ToolCaptureService
    private let stateRecorder: ToolStateRecorder?

    public init(
        documentID: DocumentID,
        documentService: DocumentService,
        toolCapture: ToolCaptureService,
        stateRecorder: ToolStateRecorder? = nil
    ) {
        self.documentID = documentID
        self.documentService = documentService
        self.toolCapture = toolCapture
        self.stateRecorder = stateRecorder
    }

    /// Remembers this document and page in the active session, for Resume.
    private func recordPosition() {
        guard let stateRecorder else { return }
        let documentID = documentID, page = currentPage
        Task { await stateRecorder.record(.documents, in: document?.workspaceID, documentID: documentID, page: page) }
    }

    public var pageCount: Int { pdf?.pageCount ?? 0 }
    public var canGoBack: Bool { currentPage > 0 }
    public var canGoForward: Bool { currentPage + 1 < pageCount }
    public var currentMatch: PDFSelection? { matchIndex.map { matches[$0] } }
    public var fileURL: URL? { document.map(documentService.fileURL(for:)) }

    public func load() async {
        guard pdf == nil else { return }
        do {
            let document = try await documentService.document(id: documentID)
            self.document = document
            guard let pdf = PDFDocument(url: documentService.fileURL(for: document)) else {
                failedToOpen = true
                return
            }
            self.pdf = pdf
            let opened = try await documentService.markOpened(documentID, pageCount: pdf.pageCount)
            self.document = opened
            let documentService = documentService
            Task { await PDFSearchIndexer.indexMissing([opened], service: documentService) }
            currentPage = min(document.lastReadPage ?? 0, max(pdf.pageCount - 1, 0))
            recordPosition()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    // MARK: Pages

    public func goTo(page: Int) {
        guard pageCount > 0 else { return }
        let page = min(max(page, 0), pageCount - 1)
        guard page != currentPage else { return }
        currentPage = page
        extractedText = nil
        Task { try? await documentService.setLastReadPage(documentID, page: page) }
        recordPosition()
    }

    public func nextPage() { goTo(page: currentPage + 1) }
    public func previousPage() { goTo(page: currentPage - 1) }

    /// Called when the user scrolls the PDF view.
    public func pageDidChange(to page: Int) {
        guard page != currentPage else { return }
        currentPage = page
        extractedText = nil
        Task { try? await documentService.setLastReadPage(documentID, page: page) }
        recordPosition()
    }

    // MARK: Search

    public func search() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pdf, !query.isEmpty else {
            matches = []
            matchIndex = nil
            return
        }
        matches = pdf.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        matchIndex = matches.isEmpty ? nil : 0
        showCurrentMatch()
    }

    public func nextMatch() {
        guard let index = matchIndex, !matches.isEmpty else { return }
        matchIndex = (index + 1) % matches.count
        showCurrentMatch()
    }

    public func previousMatch() {
        guard let index = matchIndex, !matches.isEmpty else { return }
        matchIndex = (index - 1 + matches.count) % matches.count
        showCurrentMatch()
    }

    private func showCurrentMatch() {
        guard let pdf, let page = currentMatch?.pages.first else { return }
        let index = pdf.index(for: page)
        if index != NSNotFound { goTo(page: index) }
    }

    // MARK: Text

    /// Extracts the current page's text layer. Scanned pages have none (OCR comes later).
    @discardableResult
    public func extractCurrentPageText() -> String {
        let text = pdf?.page(at: currentPage)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        extractedText = text
        return text
    }

    /// The current page's text, for Picture in Picture. A page without a
    /// text layer (a scan) gives a card with the document name and page only.
    public var pageOutput: ToolOutput? {
        guard let document else { return nil }
        let text = pdf?.page(at: currentPage)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            var output = DocumentService.output(for: document)
            output.metadata["page"] = .number(Double(currentPage + 1))
            return output
        }
        return DocumentService.textOutput(text, from: document, page: currentPage)
    }

    // MARK: Saving

    /// The whole document.
    public var toolOutput: ToolOutput? {
        document.map(DocumentService.output(for:))
    }

    public func saveDocument() async {
        guard let output = toolOutput else { return }
        await save(output)
    }

    public func saveExtractedText() async {
        guard let document, let text = extractedText, !text.isEmpty else { return }
        await save(DocumentService.textOutput(text, from: document, page: currentPage))
    }

    private func save(_ output: ToolOutput) async {
        do {
            try await toolCapture.save(output, preferring: document?.workspaceID)
            savedItemCount += 1
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }
}
