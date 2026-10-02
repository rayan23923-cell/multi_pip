import Foundation
import TLDomain
import TLFoundation

// AI is an enhancement, not the foundation: the Context Engine and Action
// Engine work without it, offline, on every device. AI only adds text
// (a summary, a translation, notes…) and may *suggest* actions, which the
// user must tap — and confirm when they reach outside TaskLens.

/// What the user can ask AI to do with content.
public enum AITask: String, CaseIterable, Codable, Sendable {
    case summarize
    case explain
    case translate
    case rewrite
    case extract
    case classify
    case generateNotes
    case generateQuestions
    case compare
    case answer

    /// Answer needs the user's question.
    public var needsQuestion: Bool { self == .answer }

    /// Compare needs more than the one text: the session's other items.
    public var usesSessionContext: Bool { self == .compare }

    /// What the task asks of the model. English instructions; the answer is
    /// in the content's language unless the task is Translate.
    var instruction: String {
        switch self {
        case .summarize: "Summarize the content in a few short sentences."
        case .explain: "Explain the content simply, as to someone new to the topic."
        case .translate: "Translate the content."
        case .rewrite: "Rewrite the content to be clear and concise. Keep its meaning."
        case .extract: "List the key facts in the content: names, numbers, dates, prices, links, and contacts. One per line."
        case .classify: "Say what kind of content this is (for example receipt, article, invoice, message, code) and its topic, in one line each."
        case .generateNotes: "Write study notes for the content as short bullet points."
        case .generateQuestions: "Write five questions that test understanding of the content."
        case .compare: "Compare the information in the content and the session items. List similarities and differences."
        case .answer: "Answer the question using only the content. If the content doesn't contain the answer, say so."
        }
    }
}

/// What an AI request may include. Only text: there is no field for images
/// or screen frames, so they can't be sent.
public struct AIInput: Sendable, Equatable {
    /// Extracted text: typed, OCR'd from an image or screen, or a document's text.
    public var text: String
    public var question: String?
    /// "Phone number: 0771 234 5678" lines from the Context Engine.
    public var entities: [String]
    /// Titles or short previews of the session's items, only when the user includes them.
    public var sessionContext: [String]
    /// For Translate: the target language name ("Arabic", "English").
    public var targetLanguage: String?

    public init(text: String, question: String? = nil, entities: [String] = [], sessionContext: [String] = [], targetLanguage: String? = nil) {
        self.text = text
        self.question = question
        self.entities = entities
        self.sessionContext = sessionContext
        self.targetLanguage = targetLanguage
    }
}

/// One request, ready for a provider. `prompt` is exactly what is sent
/// (with `instructions`); `sentCharacters` is shown to the user first.
public struct AIRequest: Sendable, Equatable {
    public var task: AITask
    public var instructions: String
    public var prompt: String
    /// True when the content was cut to `AIRequestBuilder.maximumCharacters`.
    public var isTruncated: Bool
    public var includesSessionContext: Bool

    public var sentCharacters: Int { instructions.count + prompt.count }
}

public enum AIRequestBuilder {
    /// Longest content sent. Keeps requests small, fast, and within the
    /// on-device model's context.
    public static let maximumCharacters = 6_000
    public static let maximumSessionItems = 10
    public static let maximumQuestionLength = 500

    /// The actions AI may suggest. The rest (deleting, sending without the
    /// user) are never offered from AI output.
    public static let suggestibleActions: [ActionType] = [
        .createNote, .saveToSession, .copy, .search, .translate, .addToCalendar,
        .createReminder, .openURL, .call, .sendEmail, .sendMessage, .openInMaps, .calculate, .convertCurrency,
    ]

    static let baseInstructions = """
    You are the assistant in TaskLens, a productivity app. Work only with the content given. \
    Reply in the same language as the content unless asked to translate. Be brief. \
    Never say you performed an action: you can only suggest them. \
    If an action would help, end with one line in this exact form: \
    ACTIONS: name, name (at most 3, chosen from: \(suggestibleActions.map(\.rawValue).joined(separator: ", "))).
    """

    public static func request(_ task: AITask, input: AIInput) throws -> AIRequest {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionContext = task.usesSessionContext || task == .answer ? Array(input.sessionContext.prefix(maximumSessionItems)) : []
        guard !text.isEmpty || !sessionContext.isEmpty else {
            throw TaskLensError.validationFailed(.emptyContent)
        }
        let question = input.question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if task.needsQuestion && question.isEmpty {
            throw TaskLensError.validationFailed(.emptyContent)
        }

        var instructions = baseInstructions + "\n" + task.instruction
        if task == .translate {
            instructions += " Translate into \(input.targetLanguage ?? "English")."
        }

        let isTruncated = text.count > maximumCharacters
        var parts = ["CONTENT:\n" + String(text.prefix(maximumCharacters))]
        if !input.entities.isEmpty {
            parts.append("DETECTED:\n" + input.entities.prefix(20).joined(separator: "\n"))
        }
        if !sessionContext.isEmpty {
            parts.append("SESSION ITEMS:\n" + sessionContext.map { "- " + String($0.prefix(200)) }.joined(separator: "\n"))
        }
        if task.needsQuestion {
            parts.append("QUESTION:\n" + String(question.prefix(maximumQuestionLength)))
        }
        return AIRequest(
            task: task,
            instructions: instructions,
            prompt: parts.joined(separator: "\n\n"),
            isTruncated: isTruncated,
            includesSessionContext: !sessionContext.isEmpty
        )
    }
}

/// An AI reply: the text, plus actions it suggested. Suggestions are never run
/// automatically; `needsConfirmation` ones ask again before they run.
public struct AIAnswer: Sendable, Equatable {
    public var text: String
    public var suggestions: [ActionType]

    public static let maximumSuggestions = 3

    public init(text: String, suggestions: [ActionType]) {
        self.text = text
        self.suggestions = suggestions
    }

    /// Actions that reach outside TaskLens (calls, messages, links, calendar):
    /// a tap on an AI suggestion asks for confirmation first.
    public static let sensitiveActions: Set<ActionType> = [
        .call, .sendMessage, .sendEmail, .openURL, .addToCalendar, .createReminder, .addContact, .openInMaps,
    ]

    public static func needsConfirmation(_ action: ActionType) -> Bool {
        sensitiveActions.contains(action)
    }

    /// Splits the reply text from its "ACTIONS:" line. Unknown names are dropped.
    public static func parse(_ raw: String) -> AIAnswer {
        var lines = raw.components(separatedBy: .newlines)
        var suggestions: [ActionType] = []
        if let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("ACTIONS:") }) {
            let line = lines.remove(at: index)
            let names = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            for name in names.split(whereSeparator: { $0 == "," || $0 == "،" }) {
                let cleaned = name.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
                guard let action = AIRequestBuilder.suggestibleActions.first(where: { $0.rawValue.caseInsensitiveCompare(cleaned) == .orderedSame }),
                      !suggestions.contains(action) else { continue }
                suggestions.append(action)
            }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return AIAnswer(text: text, suggestions: Array(suggestions.prefix(maximumSuggestions)))
    }
}

// MARK: Providers

public enum AIUnavailableReason: String, Sendable, Equatable {
    /// The user turned AI off.
    case turnedOff
    /// This device can't run Apple Intelligence (for example iPhone 11).
    case deviceNotEligible
    /// Apple Intelligence is off in Settings.
    case notEnabled
    /// The on-device model is still downloading.
    case modelNotReady
    /// The AI server needs the network and there is none.
    case offline
    /// No provider is set up (no Apple Intelligence and no AI server).
    case notConfigured
}

public enum AIAvailability: Sendable, Equatable {
    case available
    case unavailable(AIUnavailableReason)
}

/// Runs a request. Apple Intelligence on device, or the user's AI server.
public protocol AIProvider: Sendable {
    var kind: AIProviderKind { get }
    /// "This iPhone", or the server host — shown before anything is sent.
    var destination: String { get }
    func availability() async -> AIAvailability
    func respond(to request: AIRequest) async throws -> String
}

/// Settings the user controls. AI is on by default only on device; a
/// server is never used until the user adds one and turns it on.
public struct AISettings: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var allowsServer: Bool
    public var serverURL: URL?
    public var serverModel: String
    public var keepsHistory: Bool

    public init(isEnabled: Bool = true, allowsServer: Bool = false, serverURL: URL? = nil, serverModel: String = "", keepsHistory: Bool = true) {
        self.isEnabled = isEnabled
        self.allowsServer = allowsServer
        self.serverURL = serverURL
        self.serverModel = serverModel
        self.keepsHistory = keepsHistory
    }

    /// Only HTTPS servers are accepted.
    public static func isValidServerURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else { return false }
        return true
    }
}

public protocol AISettingsStoring: Sendable {
    func load() -> AISettings
    func save(_ settings: AISettings)
}

/// Settings in UserDefaults (no secrets: the API key is in the Keychain).
public final class UserDefaultsAISettingsStore: AISettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "TaskLens.AISettings") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AISettings {
        guard let data = defaults.data(forKey: key), let settings = try? JSONDecoder().decode(AISettings.self, from: data) else {
            return AISettings()
        }
        return settings
    }

    public func save(_ settings: AISettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

public final class InMemoryAISettingsStore: AISettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AISettings

    public init(_ settings: AISettings = AISettings()) {
        self.settings = settings
    }

    public func load() -> AISettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    public func save(_ settings: AISettings) {
        lock.lock()
        self.settings = settings
        lock.unlock()
    }
}

/// Whether the device is online. Only the AI server needs it.
public protocol NetworkStatusProviding: Sendable {
    var isOnline: Bool { get }
}

public struct FixedNetworkStatus: NetworkStatusProviding {
    public let isOnline: Bool
    public init(isOnline: Bool) { self.isOnline = isOnline }
}

// MARK: Service

/// What the user sees before sending: what, where and why.
public struct AIDisclosure: Sendable, Equatable {
    public var task: AITask
    public var provider: AIProviderKind
    public var destination: String
    public var characters: Int
    public var includesSessionContext: Bool
    public var isTruncated: Bool
    /// True when the text leaves the device.
    public var leavesDevice: Bool { provider != .onDevice }
}

public enum AIOutcome: Sendable, Equatable {
    case answer(AIAnswer, provider: AIProviderKind)
    /// AI can't run now; deterministic actions and local features still work.
    case unavailable(AIUnavailableReason)
    /// The provider failed; the user can retry.
    case failed(String)
}

public struct AIService: Sendable {
    private let providers: [any AIProvider]
    private let settings: any AISettingsStoring
    private let records: any Repository<AIRecord>
    private let clock: any DateProviding
    private let logger: TLLogger

    /// `providers` in order of preference: on-device first, so text stays on
    /// the device whenever it can.
    public init(
        providers: [any AIProvider],
        settings: any AISettingsStoring,
        records: any Repository<AIRecord>,
        clock: any DateProviding = SystemDateProvider(),
        logger: TLLogger = TLLogger(category: "ai")
    ) {
        self.providers = providers.sorted { lhs, rhs in lhs.kind == .onDevice && rhs.kind != .onDevice }
        self.settings = settings
        self.records = records
        self.clock = clock
        self.logger = logger
    }

    public var currentSettings: AISettings { settings.load() }

    public func update(_ change: (inout AISettings) -> Void) {
        var current = settings.load()
        change(&current)
        settings.save(current)
    }

    /// The provider a request would use now, or why none can run.
    public func provider() async -> Result<any AIProvider, AIUnavailableReasonError> {
        let settings = settings.load()
        guard settings.isEnabled else { return .failure(.init(reason: .turnedOff)) }
        var firstReason: AIUnavailableReason?
        for provider in providers {
            if provider.kind == .server && !settings.allowsServer { continue }
            switch await provider.availability() {
            case .available:
                return .success(provider)
            case .unavailable(let reason):
                // Prefer the server's reason (offline) when the device can't run AI at all.
                if firstReason == nil || provider.kind == .server { firstReason = reason }
            }
        }
        return .failure(.init(reason: firstReason ?? .notConfigured))
    }

    public func availability() async -> AIAvailability {
        switch await provider() {
        case .success: .available
        case .failure(let error): .unavailable(error.reason)
        }
    }

    /// What would be sent, to show before the user taps Send.
    public func disclosure(for request: AIRequest) async -> AIDisclosure? {
        guard case .success(let provider) = await provider() else { return nil }
        return AIDisclosure(
            task: request.task, provider: provider.kind, destination: provider.destination,
            characters: request.sentCharacters, includesSessionContext: request.includesSessionContext,
            isTruncated: request.isTruncated
        )
    }

    /// Runs the request. Never throws for offline or unavailable AI: the
    /// caller keeps showing deterministic actions and offers Retry.
    public func run(_ request: AIRequest) async -> AIOutcome {
        let provider: any AIProvider
        switch await self.provider() {
        case .success(let found): provider = found
        case .failure(let error): return .unavailable(error.reason)
        }
        do {
            let raw = try await provider.respond(to: request)
            let answer = AIAnswer.parse(raw)
            if settings.load().keepsHistory {
                try? await records.upsert(AIRecord(
                    task: request.task.rawValue, provider: provider.kind, destination: provider.destination,
                    sentCharacters: request.sentCharacters,
                    inputPreview: String(request.prompt.prefix(120)),
                    output: answer.text, createdAt: clock.now()
                ))
            }
            return .answer(answer, provider: provider.kind)
        } catch let error as AIProviderError {
            logger.error("AI request failed: \(error)")
            if case .offline = error { return .unavailable(.offline) }
            return .failed(error.description)
        } catch {
            logger.error("AI request failed: \(error)")
            return .failed(String(describing: error))
        }
    }

    // MARK: History and deletion

    public func history() async throws -> [AIRecord] {
        try await records.fetchAll().sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ id: AIRecordID) async throws {
        try await records.delete(id: id)
    }

    public func deleteHistory() async throws {
        try await records.delete(ids: try await records.fetchAll().map(\.id))
        logger.info("Deleted AI history")
    }
}

public struct AIUnavailableReasonError: Error, Sendable, Equatable {
    public let reason: AIUnavailableReason
}

public enum AIProviderError: Error, Sendable, Equatable, CustomStringConvertible {
    case offline
    case notConfigured
    case badResponse(status: Int)
    case unreadableResponse
    case refused(String)

    public var description: String {
        switch self {
        case .offline: "offline"
        case .notConfigured: "notConfigured"
        case .badResponse(let status): "HTTP \(status)"
        case .unreadableResponse: "unreadableResponse"
        case .refused(let message): message
        }
    }
}
