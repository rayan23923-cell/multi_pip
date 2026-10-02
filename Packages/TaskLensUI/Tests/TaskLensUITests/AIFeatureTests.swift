import Foundation
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import TLLocalization
@testable import AIFeature

/// Scripted provider for the UI models.
final class ScriptedAIProvider: AIProvider, @unchecked Sendable {
    let kind: AIProviderKind
    var state: AIAvailability
    var reply: Result<String, AIProviderError>
    private(set) var requests: [AIRequest] = []

    init(kind: AIProviderKind = .onDevice, state: AIAvailability = .available, reply: Result<String, AIProviderError> = .success("Answer")) {
        self.kind = kind
        self.state = state
        self.reply = reply
    }

    var destination: String { kind == .onDevice ? "device" : "ai.example.com" }
    func availability() async -> AIAvailability { state }
    func respond(to request: AIRequest) async throws -> String {
        requests.append(request)
        return try reply.get()
    }
}

@MainActor
@Suite("AI assist and settings models")
struct AIFeatureTests {
    let records = InMemoryRepository<AIRecord>()

    func service(_ provider: ScriptedAIProvider, settings: AISettings = AISettings()) -> AIService {
        AIService(providers: [provider], settings: InMemoryAISettingsStore(settings), records: records, logger: .disabled())
    }

    @Test func nothingIsSentUntilSendAndTheDisclosureIsShown() async {
        let provider = ScriptedAIProvider(reply: .success("Short summary\nACTIONS: createNote, call"))
        let model = AIAssistModel(service: service(provider))
        await model.setContent("TaskLens keeps research together. Call 0771 234 5678.", entities: ["phoneNumber: 0771 234 5678"])
        #expect(provider.requests.isEmpty)
        #expect(model.availability == .available)
        #expect(model.disclosure?.leavesDevice == false)
        #expect((model.disclosure?.characters ?? 0) > 0)
        #expect(model.canSend)

        await model.send()
        #expect(provider.requests.count == 1)
        #expect(model.phase == .answered(AIAnswer(text: "Short summary", suggestions: [.createNote, .call]), provider: .onDevice))
        #expect(AIAnswer.needsConfirmation(.call))
    }

    @Test func askNeedsAQuestion() async {
        let provider = ScriptedAIProvider()
        let model = AIAssistModel(service: service(provider))
        await model.setContent("The exam is on Monday.", entities: [])
        model.task = .answer
        #expect(!model.canSend)
        model.question = "When is the exam?"
        #expect(model.canSend)
        await model.send()
        #expect(provider.requests.first?.prompt.contains("When is the exam?") == true)
    }

    @Test func sessionContextOnlyWhenTurnedOn() async {
        let provider = ScriptedAIProvider()
        let model = AIAssistModel(service: service(provider)) { ["iPhone 16 costs $699"] }
        await model.setContent("iPhone 17 costs $799", entities: [])
        model.task = .compare
        await model.send()
        #expect(provider.requests.last?.includesSessionContext == false)
        model.includesSessionContext = true
        await model.send()
        #expect(provider.requests.last?.includesSessionContext == true)
        #expect(provider.requests.last?.prompt.contains("iPhone 16") == true)
    }

    @Test func offlineKeepsLensWorkingAndRetries() async {
        let provider = ScriptedAIProvider(kind: .server, state: .unavailable(.offline))
        let model = AIAssistModel(service: service(provider, settings: AISettings(allowsServer: true)))
        await model.setContent("Some text", entities: [])
        #expect(model.phase == .unavailable(.offline))
        #expect(!model.canSend)
        await model.send()
        #expect(provider.requests.isEmpty)

        provider.state = .available
        await model.retry()
        #expect(provider.requests.count == 1)
        if case .answered(_, let kind) = model.phase { #expect(kind == .server) } else { Issue.record("Expected an answer, got \(model.phase)") }
    }

    @Test func failureOffersRetry() async {
        let provider = ScriptedAIProvider(reply: .failure(.badResponse(status: 500)))
        let model = AIAssistModel(service: service(provider))
        await model.setContent("Some text", entities: [])
        await model.send()
        #expect(model.phase == .failed)
        provider.reply = .success("OK")
        await model.retry()
        #expect(model.phase == .answered(AIAnswer(text: "OK", suggestions: []), provider: .onDevice))
    }

    @Test func turnedOffShowsWhyAndSendsNothing() async {
        let provider = ScriptedAIProvider()
        let model = AIAssistModel(service: service(provider, settings: AISettings(isEnabled: false)))
        await model.setContent("Some text", entities: [])
        #expect(model.phase == .unavailable(.turnedOff))
        await model.send()
        #expect(provider.requests.isEmpty)
    }

    @Test func settingsControlServerKeyAndHistory() async {
        let provider = ScriptedAIProvider(kind: .server)
        let ai = service(provider)
        let secrets = InMemorySecretStore()
        let settings = AISettingsModel(service: ai, secrets: secrets)
        await settings.load()
        #expect(settings.availability == .unavailable(.notConfigured), "No server until the user adds one")

        settings.serverAddress = "http://insecure.example.com"
        settings.serverModel = "small"
        await settings.setAllowsServer(true)
        #expect(!settings.settings.allowsServer)
        #expect(settings.errorMessage != nil)

        settings.serverAddress = "https://ai.example.com/v1/chat/completions"
        settings.setAPIKey("key-1")
        await settings.setAllowsServer(true)
        #expect(settings.settings.allowsServer)
        #expect(settings.hasAPIKey)
        #expect(secrets.secret(for: AIServerProvider.apiKeySecret) == "key-1")
        #expect(settings.availability == .available)

        _ = await ai.run(try! AIRequestBuilder.request(.summarize, input: AIInput(text: "Hello")))
        await settings.load()
        #expect(settings.history.count == 1)
        #expect(settings.history.first?.destination == "ai.example.com")

        await settings.setKeepsHistory(false)
        #expect(settings.history.isEmpty, "Turning history off deletes it")

        await settings.removeServer()
        #expect(!settings.hasAPIKey)
        #expect(secrets.secret(for: AIServerProvider.apiKeySecret) == nil)
        #expect(!settings.settings.allowsServer)

        await settings.setEnabled(false)
        #expect(settings.availability == .unavailable(.turnedOff))
    }

    @Test func everyTaskAndReasonHasALabel() {
        for task in AITask.allCases {
            #expect(L10nKey(rawValue: "ai.task.\(task.rawValue)") != nil, "Missing label for \(task)")
        }
        for reason in [AIUnavailableReason.turnedOff, .deviceNotEligible, .notEnabled, .modelNotReady, .offline, .notConfigured] {
            #expect(L10nKey(rawValue: "ai.unavailable.\(reason.rawValue)") != nil, "Missing label for \(reason)")
        }
    }
}
