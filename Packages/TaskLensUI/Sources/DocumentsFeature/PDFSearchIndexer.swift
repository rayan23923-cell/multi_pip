import Foundation
import PDFKit
import TLCoreServices
import TLDomain

/// Keeps the text of PDFs for Smart Search, on this device. PDFs without a
/// text layer (scans) have nothing to index and are found by title only.
enum PDFSearchIndexer {
    /// Indexes PDFs that have no search text yet.
    static func indexMissing(_ documents: [Document], service: DocumentService) async {
        for document in documents where document.kind == .pdf && DocumentService.searchText(of: document) == nil {
            let text = await extractText(at: service.fileURL(for: document))
            // Stored even when empty, so a scan isn't read again on every load.
            _ = try? await service.setSearchText(document.id, text: text ?? "")
        }
    }

    @concurrent
    static func extractText(at url: URL) async -> String? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        var text = ""
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index)?.string, !page.isEmpty else { continue }
            text += page + "\n"
            if text.count >= DocumentService.maximumSearchTextLength { break }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
