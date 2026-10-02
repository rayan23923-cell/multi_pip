import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import TLCoreServices

/// Lets workflows read images (Vision) and PDFs (PDFKit), on this device.
public struct LensWorkflowReader: WorkflowContentReading {
    private let recognizer: any ImageRecognizing

    public init(recognizer: any ImageRecognizing = VisionImageRecognizer()) {
        self.recognizer = recognizer
    }

    public func recognizeText(inImageAt url: URL) async throws -> String {
        guard let image = Self.loadImage(url) else { return "" }
        let recognition = try await recognizer.recognize(image)
        return recognition.lines.map(\.text).joined(separator: "\n")
    }

    public func text(ofPDFAt url: URL) async throws -> String {
        await Self.pdfText(url)
    }

    /// Upright and no larger than the Lens preprocessor's limit.
    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ImagePreprocessor.maximumDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    @concurrent
    static func pdfText(_ url: URL) async -> String {
        guard let pdf = PDFDocument(url: url) else { return "" }
        var text = ""
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index)?.string, !page.isEmpty else { continue }
            text += page + "\n"
            if text.count >= DocumentService.maximumSearchTextLength { break }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
