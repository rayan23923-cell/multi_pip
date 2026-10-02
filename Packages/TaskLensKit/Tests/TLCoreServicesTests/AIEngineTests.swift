import Foundation
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation

/// A provider that answers what it is told, and records what it was sent.
final class FakeAIProvider: AIProvider, @unchecked Sendable {
    let kind: AIProviderKind
    let destination: String
    var state: AIAvailability
    var reply: Result<String, AIProviderError>
    private(set) var sent: [AIRequest] = []

    init(kind: AIProviderKind, destination: String = "test", state: AIAvailability = .available, reply: Result<String, AIProviderError> = .success("Done")) {
        self.kind = kind
        self.destination = destination
        self.state = state
        self.reply = reply
    }

    func availability() async -> AIAvailability { state }

    func respond(to request: AIRequest) async throws -> String {
        sent.append(request)
        return try reply.get()
    }
}

@Suite("AI requests and answers")
struct AIRequestTests {
    @Test func requestCarriesOnlyTextAndIsBounded() throws {
        let long = String(repeating: "a", count: AIRequestBuilder.maximumCharacters + 500)
        let request = try AIRequestBuilder.request(.summarize, input: AIInput(text: long, entities: ["Price: $199"]))
        #expect(request.isTruncated)
        #expect(request.prompt.contains("Price: $199"))
        #expect(request.prompt.count < AIRequestBuilder.maximumCharacters + 200)
        #expect(request.instructions.contains("Summarize"))
        #expect(!request.includesSessionContext)
    }

    @Test func sessionContextOnlyForCompareAndAnswer() throws {
        let input = AIInput(text: "iPhone 17 costs $799", question: "How much?", sessionContext: ["iPhone 16 costs $699"])
        #expect(try AIRequestBuilder.request(.summarize, input: input).includesSessionContext == false)
        let compare = try AIRequestBuilder.request(.compare, input: input)
        #expect(compare.includesSessionContext)
        #expect(compare.prompt.contains("iPhone 16"))
        let answer = try AIRequestBuilder.request(.answer, input: input)
        #expect(answer.prompt.contains("QUESTION:\nHow much?"))
    }

    @Test func emptyContentAndMissingQuestionAreRejected() {
        #expect(throws: TaskLensError.validationFailed(.emptyContent)) {
            try AIRequestBuilder.request(.summarize, input: AIInput(text: "  "))
        }
        #expect(throws: TaskLensError.validationFailed(.emptyContent)) {
            try AIRequestBuilder.request(.answer, input: AIInput(text: "Some text"))
        }
    }

    @Test func translateNamesTheTarget() throws {
        let request = try AIRequestBuilder.request(.translate, input: AIInput(text: "Hello", targetLanguage: "Arabic"))
        #expect(request.instructions.contains("Translate into Arabic"))
    }

    @Test func everyTaskBuildsARequest() throws {
        for task in AITask.allCases {
            let request = try AIRequestBuilder.request(task, input: AIInput(text: "Meeting tomorrow at 10", question: "When?", sessionContext: ["x"]))
            #expect(request.task == task)
            #expect(!request.instructions.isEmpty)
        }
    }

    @Test func suggestedActionsAreParsedAndLimited() {
        let answer = AIAnswer.parse("""
        The meeting is tomorrow at 10.
        ACTIONS: addToCalendar, createNote, deleteEverything, createNote, call, copy
        """)
        #expect(answer.text == "The meeting is tomorrow at 10.")
        #expect(answer.suggestions == [.addToCalendar, .createNote, .call])
        #expect(AIAnswer.needsConfirmation(.addToCalendar))
        #expect(AIAnswer.needsConfirmation(.call))
        #expect(!AIAnswer.needsConfirmation(.createNote))
    }

    @Test func answerWithoutActionsKeepsAllText() {
        let answer = AIAnswer.parse("Line one\nLine two")
        #expect(answer.text == "Line one\nLine two")
        #expect(answer.suggestions.isEmpty)
    }

    @Test func onlyHTTPSServersAreAccepted() {
        #expect(AISettings.isValidServerURL(URL(string: "https://ai.example.com/v1/chat/completions")))
        #expect(!AISettings.isValidServerURL(URL(string: "http://ai.example.com")))
        #expect(!AISettings.isValidServerURL(nil))
    }
}

@Suite("AI service")
struct AIServiceTests {
    let clock = ManualDateProvider(Date(timeIntervalSinceReferenceDate: 5_000))
    let records = InMemoryRepository<AIRecord>()

    func service(_ providers: [any AIProvider], settings: AISettings = AISettings()) -> (AIService, InMemoryAISettingsStore) {
        let store = InMemoryAISettingsStore(settings)
        return (AIService(providers: providers, settings: store, records: records, clock: clock, logger: .disabled()), store)
    }

    func request() throws -> AIRequest {
        try AIRequestBuilder.request(.summarize, input: AIInput(text: "TaskLens keeps your research together."))
    }

    @Test func onDeviceIsPreferred() async throws {
        let server = FakeAIProvider(kind: .server, destination: "ai.example.com")
        let device = FakeAIProvider(kind: .onDevice, destination: "device")
        let (ai, _) = service([server, device], settings: AISettings(allowsServer: true))
        let outcome = await ai.run(try request())
        #expect(outcome == .answer(AIAnswer(text: "Done", suggestions: []), provider: .onDevice))
        #expect(device.sent.count == 1)
        #expect(server.sent.isEmpty)
    }

    @Test func serverIsNeverUsedUnlessAllowed() async throws {
        let server = FakeAIProvider(kind: .server)
        let device = FakeAIProvider(kind: .onDevice, state: .unavailable(.deviceNotEligible))
        let (ai, _) = service([server, device])
        #expect(await ai.run(try request()) == .unavailable(.deviceNotEligible))
        #expect(server.sent.isEmpty)
    }

    @Test func serverRunsWhenAllowedAndDisclosesItsHost() async throws {
        let server = FakeAIProvider(kind: .server, destination: "ai.example.com")
        let device = FakeAIProvider(kind: .onDevice, state: .unavailable(.deviceNotEligible))
        let (ai, _) = service([server, device], settings: AISettings(allowsServer: true))
        let request = try request()
        let disclosure = try #require(await ai.disclosure(for: request))
        #expect(disclosure.leavesDevice)
        #expect(disclosure.destination == "ai.example.com")
        #expect(disclosure.characters == request.sentCharacters)
        guard case .answer(_, provider: .server) = await ai.run(request) else {
            Issue.record("Expected a server answer")
            return
        }
        #expect(server.sent == [request])
    }

    @Test func offlineDoesNotFail() async throws {
        let server = FakeAIProvider(kind: .server, state: .unavailable(.offline))
        let device = FakeAIProvider(kind: .onDevice, state: .unavailable(.deviceNotEligible))
        let (ai, _) = service([server, device], settings: AISettings(allowsServer: true))
        #expect(await ai.run(try request()) == .unavailable(.offline))
        #expect(await ai.availability() == .unavailable(.offline))

        // Losing the network mid-request is also "offline", not an error.
        server.state = .available
        server.reply = .failure(.offline)
        #expect(await ai.run(try request()) == .unavailable(.offline))
    }

    @Test func turnedOffSendsNothing() async throws {
        let device = FakeAIProvider(kind: .onDevice)
        let (ai, store) = service([device], settings: AISettings(isEnabled: false))
        #expect(await ai.run(try request()) == .unavailable(.turnedOff))
        #expect(await ai.disclosure(for: try request()) == nil)
        #expect(device.sent.isEmpty)
        ai.update { $0.isEnabled = true }
        #expect(store.load().isEnabled)
        #expect(await ai.availability() == .available)
    }

    @Test func failuresCanBeRetried() async throws {
        let device = FakeAIProvider(kind: .onDevice, reply: .failure(.badResponse(status: 500)))
        let (ai, _) = service([device])
        #expect(await ai.run(try request()) == .failed("HTTP 500"))
        device.reply = .success("Better")
        #expect(await ai.run(try request()) == .answer(AIAnswer(text: "Better", suggestions: []), provider: .onDevice))
    }

    @Test func historyIsKeptOnlyWhenAllowedAndCanBeDeleted() async throws {
        let device = FakeAIProvider(kind: .onDevice, destination: "device")
        let (ai, _) = service([device])
        _ = await ai.run(try request())
        let history = try await ai.history()
        #expect(history.count == 1)
        #expect(history.first?.task == "summarize")
        #expect(history.first?.sentCharacters == (try request()).sentCharacters)

        try await ai.delete(try #require(history.first).id)
        #expect(try await ai.history().isEmpty)

        _ = await ai.run(try request())
        _ = await ai.run(try request())
        try await ai.deleteHistory()
        #expect(try await ai.history().isEmpty)

        ai.update { $0.keepsHistory = false }
        _ = await ai.run(try request())
        #expect(try await ai.history().isEmpty)
    }
}

/// Answers server requests in tests without a network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("AI server provider", .serialized)
struct AIServerProviderTests {
    let settings = InMemoryAISettingsStore(AISettings(
        allowsServer: true, serverURL: URL(string: "https://ai.example.com/v1/chat/completions"), serverModel: "small"
    ))
    let secrets = InMemorySecretStore()

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func sendsOnlyTheRequestTextWithTheKey() async throws {
        secrets.setSecret("secret-key", for: AIServerProvider.apiKeySecret)
        nonisolated(unsafe) var authorization: String?
        StubURLProtocol.handler = { request in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            return (200, Data(#"{"choices":[{"message":{"content":"Short summary"}}]}"#.utf8))
        }
        let provider = AIServerProvider(settings: settings, secrets: secrets, network: FixedNetworkStatus(isOnline: true), session: session)
        #expect(await provider.availability() == .available)
        #expect(provider.destination == "ai.example.com")
        let request = try AIRequestBuilder.request(.summarize, input: AIInput(text: "Hello world"))
        #expect(try await provider.respond(to: request) == "Short summary")
        #expect(authorization == "Bearer secret-key")
        let body = try #require(StubURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["model", "messages"])
        #expect((json["messages"] as? [[String: String]])?.last?["content"] == request.prompt)
    }

    @Test func offlineAndMisconfigurationAreReported() async throws {
        let offline = AIServerProvider(settings: settings, secrets: secrets, network: FixedNetworkStatus(isOnline: false), session: session)
        #expect(await offline.availability() == .unavailable(.offline))
        let request = try AIRequestBuilder.request(.summarize, input: AIInput(text: "Hello"))
        await #expect(throws: AIProviderError.offline) { try await offline.respond(to: request) }

        let plain = InMemoryAISettingsStore(AISettings(allowsServer: true, serverURL: URL(string: "http://ai.example.com"), serverModel: "small"))
        let insecure = AIServerProvider(settings: plain, secrets: secrets, network: FixedNetworkStatus(isOnline: true), session: session)
        #expect(await insecure.availability() == .unavailable(.notConfigured))
    }

    @Test func serverErrorsAreFailuresNotCrashes() async throws {
        StubURLProtocol.handler = { _ in (503, Data()) }
        let provider = AIServerProvider(settings: settings, secrets: secrets, network: FixedNetworkStatus(isOnline: true), session: session)
        let request = try AIRequestBuilder.request(.summarize, input: AIInput(text: "Hello"))
        await #expect(throws: AIProviderError.badResponse(status: 503)) { try await provider.respond(to: request) }

        StubURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        await #expect(throws: AIProviderError.unreadableResponse) { try await provider.respond(to: request) }
    }

    @Test func onDeviceProviderReportsItsState() async {
        // On the CI simulator Apple Intelligence is normally unavailable; either
        // way the provider must answer without crashing.
        _ = await AppleIntelligenceProvider().availability()
        #expect(AppleIntelligenceProvider().kind == .onDevice)
    }
}
