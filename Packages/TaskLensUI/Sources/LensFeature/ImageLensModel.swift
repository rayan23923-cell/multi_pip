import Foundation
import Observation
import PDFKit
import TLCoreServices
import TLDomain
import TLLocalization
import UIKit

/// Action Lens for images, screenshots, camera photos and documents.
///
/// Image → preprocessing → Vision → normalized text → detectors → findings
/// → recommended actions. Nothing runs automatically: the user picks a
/// finding and taps an action. A finding read with low confidence is a
/// "Possible match" the user checks (and can correct) before any action.
/// The image stays in memory only while shown; it is never uploaded.
@MainActor
@Observable
public final class ImageLensModel {
    public enum Phase: Equatable {
        case idle
        case reading
        case done
        case failed
    }

    public private(set) var phase: Phase = .idle
    /// The image being read, shown as a thumbnail. Not stored anywhere.
    public private(set) var preview: UIImage?
    public private(set) var report: LensReport?
    public var selectedID: String?
    /// Possible matches the user checked, with the text they confirmed.
    public private(set) var confirmed: [String: String] = [:]
    public private(set) var savedIDs: Set<String> = []
    public var errorMessage: String?
    /// Where the current image came from, recorded on saved items.
    public private(set) var source: ContextSource = .photoLibrary

    private let recognizer: any ImageRecognizing
    private let captureService: CaptureService
    private let sessionService: SessionService

    public init(recognizer: any ImageRecognizing, captureService: CaptureService, sessionService: SessionService) {
        self.recognizer = recognizer
        self.captureService = captureService
        self.sessionService = sessionService
    }

    public var findings: [LensFinding] { report?.findings ?? [] }

    public var selected: LensFinding? {
        findings.first { $0.id == selectedID }
    }

    // MARK: Input

    public func read(_ image: UIImage, source: ContextSource) async {
        begin(source: source, preview: image)
        guard let prepared = ImagePreprocessor.prepare(image) else {
            phase = .failed
            return
        }
        await recognize(prepared)
    }

    public func read(data: Data, source: ContextSource) async {
        guard let image = UIImage(data: data) else {
            begin(source: source, preview: nil)
            phase = .failed
            return
        }
        await read(image, source: source)
    }

    /// A PDF: its text layer when it has one (exact), otherwise the first page through OCR.
    public func read(pdf document: PDFDocument, source: ContextSource) async {
        let firstPage = ImagePreprocessor.firstPage(of: document)
        begin(source: source, preview: firstPage.map { UIImage(cgImage: $0) })
        let lines = ImagePreprocessor.textLines(of: document)
        if !lines.isEmpty {
            show(VisualRecognition(lines: lines))
        } else if let firstPage {
            await recognize(firstPage)
        } else {
            phase = .failed
        }
    }

    /// A file the user picked or shared: an image or a PDF.
    public func read(fileAt url: URL, source: ContextSource) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) {
            await read(pdf: document, source: source)
        } else if let data = try? Data(contentsOf: url) {
            await read(data: data, source: source)
        } else {
            begin(source: source, preview: nil)
            phase = .failed
        }
    }

    /// Forgets the image and everything read from it.
    public func clear() {
        phase = .idle
        preview = nil
        report = nil
        selectedID = nil
        confirmed = [:]
        savedIDs = []
    }

    /// Drops the image but keeps what was read from it (Screen Lens keeps no frame).
    public func discardPreview() {
        preview = nil
    }

    // MARK: Findings and actions

    /// True when actions may be offered: read clearly, or checked by the user.
    public func isActionable(_ finding: LensFinding) -> Bool {
        finding.certainty == .confident || confirmed[finding.id] != nil
    }

    /// The user checked (and maybe corrected) a possible match.
    public func confirm(_ finding: LensFinding, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        confirmed[finding.id] = trimmed
        selectedID = finding.id
    }

    /// What actions act on: the confirmed text for a checked possible match.
    public func content(for finding: LensFinding) -> ContextContent {
        if let text = confirmed[finding.id] {
            var corrected = finding
            corrected.text = text
            return corrected.content
        }
        return finding.content
    }

    /// Recommended actions for a finding; nil until it is actionable.
    public func analysis(for finding: LensFinding) -> ContextAnalysis? {
        guard isActionable(finding) else { return nil }
        return ActionEngine.analyze(content(for: finding), context: ActionContext(source: source))
    }

    public func save(_ finding: LensFinding) async {
        guard isActionable(finding), !savedIDs.contains(finding.id) else { return }
        do {
            let target = try await sessionService.activeSessions().first
            var metadata: Metadata = ["lens": .string("image")]
            if let type = finding.entityType { metadata["entityType"] = .string(type.rawValue) }
            _ = try await captureService.capture(content(for: finding), source: source, into: target?.id, metadata: metadata)
            savedIDs.insert(finding.id)
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    // MARK: Pipeline

    private func begin(source: ContextSource, preview: UIImage?) {
        clear()
        self.source = source
        self.preview = preview
        phase = .reading
    }

    private func recognize(_ image: CGImage) async {
        do {
            show(try await recognizer.recognize(image))
        } catch {
            phase = .failed
        }
    }

    private func show(_ recognition: VisualRecognition) {
        let report = VisualLensAnalyzer.report(for: recognition)
        self.report = report
        // Preselect the first clear finding; never run anything.
        selectedID = report.findings.first { $0.certainty == .confident }?.id
        phase = .done
    }
}
