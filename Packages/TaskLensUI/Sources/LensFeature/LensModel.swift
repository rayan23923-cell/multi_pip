import AIFeature
import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLFoundation
import TLLocalization

/// Lens entry point: the user gives TaskLens some content and gets actions for it.
///
/// Content → normalize → Context Engine (category + entities) → rule-based
/// Action Engine. Everything runs on device; nothing uses AI or the network.
/// Content sent from other tools (e.g. a calculator result) arrives as
/// `initialInput` and is analyzed right away.
@MainActor
@Observable
public final class LensModel {
    public var input = ""
    public private(set) var content: ContextContent?
    public private(set) var analysis: ContextAnalysis?
    public private(set) var savedItem: ContextItem?
    public private(set) var captureTarget: Session?
    public var errorMessage: String?
    /// Lens for images, screenshots, photos and documents.
    public let imageLens: ImageLensModel
    /// Optional AI over whatever Lens is showing; nil when the app has none.
    public let ai: AIAssistModel?

    private let captureService: CaptureService
    private let sessionService: SessionService

    public init(
        captureService: CaptureService,
        sessionService: SessionService,
        initialInput: String = "",
        recognizer: any ImageRecognizing = VisionImageRecognizer(),
        ai: AIAssistModel? = nil
    ) {
        self.captureService = captureService
        self.sessionService = sessionService
        self.imageLens = ImageLensModel(recognizer: recognizer, captureService: captureService, sessionService: sessionService)
        self.ai = ai
        self.input = initialInput
        if !initialInput.isEmpty {
            analyze()
        }
    }

    public var canAnalyze: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var category: ContentCategory? { analysis?.category }

    /// Suggested actions, best first.
    public var actions: [Action] { analysis?.actions ?? [] }

    public func loadTarget() async {
        captureTarget = try? await sessionService.activeSessions().first
    }

    public func analyze() {
        guard canAnalyze else {
            content = nil
            analysis = nil
            return
        }
        let content = ContentClassifier.classify(input)
        self.content = content
        analysis = ActionEngine.analyze(content, context: ActionContext(source: .manualEntry))
        savedItem = nil
    }

    public func paste(_ strings: [String]) {
        guard let first = strings.first(where: { !$0.isEmpty }) else { return }
        input = first
        analyze()
    }

    public func save() async {
        guard let content, savedItem == nil else { return }
        do {
            savedItem = try await captureService.capture(
                content,
                source: .manualEntry,
                into: captureTarget?.id,
                metadata: category.map { ["category": .string($0.rawValue)] } ?? [:]
            )
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }
}

extension LensModel {
    /// Saves text the user chose to keep (an AI answer) into the active session or the inbox.
    public func saveText(_ text: String) async {
        do {
            _ = try await captureService.capture(
                ContentClassifier.classify(text),
                source: .manualEntry,
                into: captureTarget?.id,
                metadata: ["ai": .bool(true)]
            )
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    /// "Phone number: 0771 234 5678" lines for AI, from the Context Engine.
    static func entityLines(_ entities: [DetectedEntity]) -> [String] {
        entities.compactMap { entity in
            guard let value = entity.matchedText ?? entity.normalizedText else { return nil }
            return "\(entity.type.rawValue): \(value)"
        }
    }

    static func entityLines(_ findings: [LensFinding]) -> [String] {
        findings.compactMap { finding in
            guard let type = finding.entityType else { return nil }
            return "\(type.rawValue): \(finding.text)"
        }
    }
}
