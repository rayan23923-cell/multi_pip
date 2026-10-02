import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

/// Lens entry point: the user gives TaskLens some content and gets actions for it.
///
/// Content sent from other tools (e.g. a calculator result) arrives as
/// `initialInput` and is analyzed right away.
/// This phase classifies text versus links only. Entity detection (phones,
/// prices, dates) plugs in through `EntityDetecting` in the Context Engine phase.
@MainActor
@Observable
public final class LensModel {
    public var input = ""
    public private(set) var content: ContextContent?
    public private(set) var savedItem: ContextItem?
    public private(set) var captureTarget: Session?
    public var errorMessage: String?

    private let captureService: CaptureService
    private let sessionService: SessionService

    public init(captureService: CaptureService, sessionService: SessionService, initialInput: String = "") {
        self.captureService = captureService
        self.sessionService = sessionService
        self.input = initialInput
        if !initialInput.isEmpty {
            analyze()
        }
    }

    public var canAnalyze: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Action types this screen can perform today.
    public static let supportedActions: Set<ActionType> = [.openURL, .copy, .share, .saveToSession]

    /// Actions from the rule-based Action Engine that this screen can perform, best first.
    public var actions: [Action] {
        guard let content else { return [] }
        return BasicActionSuggester.actions(for: content).filter { Self.supportedActions.contains($0.type) }
    }

    public func loadTarget() async {
        captureTarget = try? await sessionService.activeSessions().first
    }

    public func analyze() {
        guard canAnalyze else {
            content = nil
            return
        }
        content = ContentClassifier.classify(input)
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
            savedItem = try await captureService.capture(content, source: .manualEntry, into: captureTarget?.id)
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    /// Plain text used by copy and share.
    public var shareableText: String? {
        switch content {
        case .text(let text): text
        case .url(let url): url.absoluteString
        case .file, nil: nil
        }
    }
}
