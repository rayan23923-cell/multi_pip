import Foundation
import Observation
import SwiftUI
import TLCoreServices
import TLDomain
import TLLocalization

@MainActor
@Observable
public final class TextViewerModel: ContextProducing {
    public static let fontSizes: ClosedRange<Double> = 12...32

    public let documentID: DocumentID
    public private(set) var document: Document?
    public private(set) var text = ""
    public private(set) var isTruncated = false
    public private(set) var hasLoaded = false
    public var query = ""
    public var fontSize: Double = 17
    public var isMonospaced = false
    public private(set) var savedItemCount = 0
    public var errorMessage: String?

    private let documentService: DocumentService
    private let toolCapture: ToolCaptureService

    public init(documentID: DocumentID, documentService: DocumentService, toolCapture: ToolCaptureService) {
        self.documentID = documentID
        self.documentService = documentService
        self.toolCapture = toolCapture
    }

    public var fileURL: URL? { document.map(documentService.fileURL(for:)) }

    public func load() async {
        guard !hasLoaded else { return }
        do {
            let document = try await documentService.document(id: documentID)
            self.document = document
            let content = try documentService.readText(of: document)
            text = content.text
            isTruncated = content.isTruncated
            isMonospaced = Self.prefersMonospaced(document)
            hasLoaded = true
            self.document = try await documentService.markOpened(documentID)
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    /// Ranges of `query` in the text (case and diacritic insensitive).
    public var matchRanges: [Range<String.Index>] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }

    /// The text with matches highlighted.
    public var attributedText: AttributedString {
        var attributed = AttributedString(text)
        for range in matchRanges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color.yellow
            attributed[lower..<upper][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color.black
        }
        return attributed
    }

    public var toolOutput: ToolOutput? {
        guard let document, !text.isEmpty else { return nil }
        return DocumentService.textOutput(text, from: document)
    }

    public func saveText() async {
        guard let output = toolOutput else { return }
        await save(output)
    }

    public func saveDocument() async {
        guard let document else { return }
        await save(DocumentService.output(for: document))
    }

    private func save(_ output: ToolOutput) async {
        do {
            try await toolCapture.save(output, preferring: document?.workspaceID)
            savedItemCount += 1
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    static func prefersMonospaced(_ document: Document) -> Bool {
        let name = document.file.originalFilename?.lowercased() ?? ""
        return [".swift", ".json", ".csv", ".xml", ".py", ".js", ".ts", ".c", ".h", ".m", ".sh", ".yml", ".yaml"]
            .contains { name.hasSuffix($0) }
    }
}
