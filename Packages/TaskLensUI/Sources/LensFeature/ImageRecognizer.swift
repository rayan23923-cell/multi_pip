import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import TLCoreServices
import UIKit
import Vision

/// Reads text and codes from an image. Vision in the app; a fake in tests.
public protocol ImageRecognizing: Sendable {
    func recognize(_ image: CGImage) async throws -> VisualRecognition
}

/// The first Lens stage: an image the recognizer can read well and fast.
public enum ImagePreprocessor {
    /// Longest side after scaling. Larger photos are slower and no more accurate.
    public static let maximumDimension: CGFloat = 2_048

    /// Upright (EXIF orientation applied) and scaled down to `maximumDimension`.
    public static func prepare(_ image: UIImage) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maximumDimension / max(size.width, size.height))
        if scale == 1, image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage
        }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.cgImage
    }

    public static func prepare(data: Data) -> CGImage? {
        UIImage(data: data).flatMap(prepare)
    }

    /// The first page of a PDF as an image, for scanned pages without a text layer.
    public static func firstPage(of document: PDFDocument) -> CGImage? {
        guard let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(2, maximumDimension / max(bounds.width, bounds.height, 1))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return prepare(page.thumbnail(of: size, for: .mediaBox))
    }

    /// The text layer of a PDF as recognized lines (exact, so full confidence).
    public static func textLines(of document: PDFDocument, maximumPages: Int = 5) -> [RecognizedLine] {
        var lines: [RecognizedLine] = []
        for index in 0..<min(document.pageCount, maximumPages) {
            guard let text = document.page(at: index)?.string else { continue }
            lines += text.split(whereSeparator: \.isNewline)
                .map { RecognizedLine(text: String($0), confidence: 1) }
        }
        return lines
    }
}

/// Apple Vision: accurate text recognition (with Arabic where the OS supports
/// it) and barcode detection. Runs on the device; nothing is uploaded.
public struct VisionImageRecognizer: ImageRecognizing {
    public init() {}

    public func recognize(_ image: CGImage) async throws -> VisualRecognition {
        try await Task.detached(priority: .userInitiated) {
            try Self.run(on: image)
        }.value
    }

    static func run(on image: CGImage) throws -> VisualRecognition {
        do {
            return try run(on: image, includingArabic: true)
        } catch {
            // Some OS versions reject the Arabic + English combination: read English only.
            return try run(on: image, includingArabic: false)
        }
    }

    static func run(on image: CGImage, includingArabic: Bool) throws -> VisualRecognition {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        text.recognitionLanguages = includingArabic ? languages(for: text) : ["en-US"]
        let codes = VNDetectBarcodesRequest()

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([text, codes])

        let lines = (text.results ?? []).compactMap { observation -> RecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return RecognizedLine(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                box: .init(x: box.minX, y: box.minY, width: box.width, height: box.height)
            )
        }
        let found = (codes.results ?? []).compactMap { observation -> RecognizedCode? in
            guard let payload = observation.payloadStringValue else { return nil }
            let isQR = observation.symbology == .qr || observation.symbology == .microQR
            return RecognizedCode(
                payload: payload,
                kind: isQR ? .qr : .barcode,
                symbology: observation.symbology.rawValue,
                confidence: Double(observation.confidence)
            )
        }
        return VisualRecognition(lines: lines, codes: found)
    }

    /// English always; Arabic first when this OS version can read it.
    static func languages(for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
        var languages = ["en-US"]
        if let arabic = supported.first(where: { $0.hasPrefix("ar") }) {
            languages.insert(arabic, at: 0)
        }
        return languages
    }
}
