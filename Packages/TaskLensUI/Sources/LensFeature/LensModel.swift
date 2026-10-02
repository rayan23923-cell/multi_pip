import Foundation
import Observation
import TLCoreServices
import TLDomain
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

    private let captureService: CaptureService
    private let sessionService: SessionService

    public init(
        captureService: CaptureService,
        sessionService: SessionService,
        initialInput: String = "",
        recognizer: any ImageRecognizing = VisionImageRecognizer()
    ) {
        self.captureService = captureService
        self.sessionService = sessionService
        self.imageLens = ImageLensModel(recognizer: recognizer, captureService: captureService, sessionService: sessionService)
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
