import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization
import UIKit

@MainActor
@Observable
public final class ImageViewerModel: ContextProducing {
    public let documentID: DocumentID
    public private(set) var document: Document?
    public private(set) var image: UIImage?
    public private(set) var failedToOpen = false
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

    /// Pixel dimensions, for the info line.
    public var pixelSize: CGSize? {
        image.map { CGSize(width: $0.size.width * $0.scale, height: $0.size.height * $0.scale) }
    }

    public func load() async {
        guard image == nil else { return }
        do {
            let document = try await documentService.document(id: documentID)
            self.document = document
            let url = documentService.fileURL(for: document)
            // Read the file off the main thread; large photos take a moment on older devices.
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            guard let data, let decoded = UIImage(data: data) else {
                failedToOpen = true
                return
            }
            image = decoded
            self.document = try await documentService.markOpened(documentID)
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    public var toolOutput: ToolOutput? {
        document.map(DocumentService.output(for:))
    }

    public func save() async {
        guard let output = toolOutput else { return }
        do {
            try await toolCapture.save(output, preferring: document?.workspaceID)
            savedItemCount += 1
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }
}
