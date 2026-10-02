import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

/// Optional AI on top of Lens. The deterministic findings and actions are
/// always shown first and keep working when AI is off, unavailable or offline.
///
/// Nothing is sent until the user picks a task and taps Send, after seeing
/// what will be sent and where. AI-suggested actions are only offered: the
/// user taps them, and confirms those that reach outside TaskLens.
@MainActor
@Observable
public final class AIAssistModel {
    public enum Phase: Equatable {
        case idle
        case running
        case answered(AIAnswer, provider: AIProviderKind)
        case unavailable(AIUnavailableReason)
        case failed
    }

    public var task: AITask = .summarize
    public var question = ""
    public var targetLanguage: TargetLanguage = .arabic
    /// Off by default: session items are added only when the user asks.
    public var includesSessionContext = false
    public private(set) var phase: Phase = .idle
    public private(set) var availability: AIAvailability?
    public private(set) var disclosure: AIDisclosure?
    public private(set) var errorMessage: String?

    public enum TargetLanguage: String, CaseIterable, Identifiable, Sendable {
        case arabic = "Arabic"
        case english = "English"
        public var id: String { rawValue }
    }

    private let service: AIService
    private let sessionContext: @MainActor () async -> [String]
    private var content = ""
    private var entities: [String] = []

    public init(service: AIService, sessionContext: @escaping @MainActor () async -> [String] = { [] }) {
        self.service = service
        self.sessionContext = sessionContext
    }

    /// Tasks the user can pick.
    public var tasks: [AITask] { AITask.allCases }

    public var canSend: Bool {
        guard phase != .running, availability == .available, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !task.needsQuestion || !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The content AI would work on: Lens text, OCR text or document text.
    public func setContent(_ text: String, entities: [String]) async {
        guard text != content || entities != self.entities else { return }
        content = text
        self.entities = entities
        if case .answered = phase { phase = .idle }
        await refresh()
    }

    /// Checks availability and what a request would send. Sends nothing.
    public func refresh() async {
        availability = await service.availability()
        if case .unavailable(let reason) = availability {
            disclosure = nil
            if phase == .idle || phase == .failed { phase = .unavailable(reason) }
            return
        }
        if case .unavailable = phase { phase = .idle }
        if let request = try? await request() {
            disclosure = await service.disclosure(for: request)
        } else {
            disclosure = nil
        }
    }

    public func send() async {
        guard canSend else { return }
        let request: AIRequest
        do {
            request = try await self.request()
        } catch {
            errorMessage = L10n.message(for: error)
            return
        }
        phase = .running
        switch await service.run(request) {
        case .answer(let answer, let provider):
            phase = .answered(answer, provider: provider)
        case .unavailable(let reason):
            phase = .unavailable(reason)
            availability = .unavailable(reason)
        case .failed:
            phase = .failed
        }
    }

    /// After offline or a failure: checks again and sends when possible.
    public func retry() async {
        await refresh()
        if availability == .available { await send() }
    }

    public func clear() {
        phase = .idle
        question = ""
    }

    private func request() async throws -> AIRequest {
        let context = includesSessionContext && (task.usesSessionContext || task.needsQuestion) ? await sessionContext() : []
        return try AIRequestBuilder.request(task, input: AIInput(
            text: content,
            question: question,
            entities: entities,
            sessionContext: context,
            targetLanguage: targetLanguage.rawValue
        ))
    }
}
