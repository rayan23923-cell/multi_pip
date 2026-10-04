import Foundation
import TLDomain
import TLFoundation

// Workflows: Trigger → Input → Detection → Actions → Result.
//
// Every step is deterministic and on device except the AI steps, which use the
// optional AI layer (Phase 13) and are skipped, not failed, when AI is off,
// offline or unavailable. Workflows with AI steps are "sensitive": they never
// run, from a share or the Run button, until the user confirms.

/// What a workflow works on.
public enum WorkflowInput: Sendable, Equatable {
    case text(String)
    case url(URL)
    /// A saved file: an image to read, a PDF, a text file.
    case file(URL, kind: FileKind, title: String)
}

/// Reads files for workflows: Vision for images and PDFKit for PDFs in the app.
public protocol WorkflowContentReading: Sendable {
    func recognizeText(inImageAt url: URL) async throws -> String
    func text(ofPDFAt url: URL) async throws -> String
}

public struct WorkflowStepResult: Sendable, Equatable, Identifiable {
    public enum Outcome: Sendable, Equatable {
        /// The step ran; `detail` is what it produced ("120 USD = 157,200 IQD").
        case done(detail: String)
        /// Nothing to do, or AI isn't available now; the workflow continued.
        case skipped(WorkflowSkipReason)
        case failed(String)
    }

    public var id: UUID { step.id }
    public var step: WorkflowStep
    public var outcome: Outcome
}

public enum WorkflowSkipReason: String, Sendable, Equatable {
    case noText
    case notAnImage
    case noAmount
    case noRate
    case nothingToCalculate
    case aiTurnedOff
    case aiUnavailable
    case aiOffline
}

public struct WorkflowRunResult: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case completed
        /// The workflow has sensitive steps and nothing ran yet.
        case needsConfirmation
    }

    public var state: State
    public var steps: [WorkflowStepResult]
    /// The final text, after every step.
    public var output: String
    public var savedItemIDs: [ContextItemID]
    public var noteIDs: [NoteID]

    public var failed: Bool { steps.contains { if case .failed = $0.outcome { true } else { false } } }
}

/// Create, edit, enable, duplicate, delete and find workflows.
public struct WorkflowService: Sendable {
    public static let maximumNameLength = 80
    public static let maximumSteps = 10

    private let workflows: any Repository<Workflow>
    private let clock: any DateProviding

    public init(workflows: any Repository<Workflow>, clock: any DateProviding = SystemDateProvider()) {
        self.workflows = workflows
        self.clock = clock
    }

    public func list() async throws -> [Workflow] {
        try await workflows.fetchAll().sorted { $0.createdAt < $1.createdAt }
    }

    public func workflow(id: WorkflowID) async throws -> Workflow {
        try await workflows.require(id: id)
    }

    @discardableResult
    public func create(name: String, trigger: WorkflowTrigger, steps: [WorkflowStep]) async throws -> Workflow {
        let workflow = Workflow(
            name: try Validation.name(name, maximumLength: Self.maximumNameLength),
            trigger: trigger, steps: try Self.valid(steps), createdAt: clock.now()
        )
        try await workflows.upsert(workflow)
        return workflow
    }

    @discardableResult
    public func update(_ id: WorkflowID, name: String, trigger: WorkflowTrigger, steps: [WorkflowStep]) async throws -> Workflow {
        var workflow = try await workflows.require(id: id)
        workflow.name = try Validation.name(name, maximumLength: Self.maximumNameLength)
        workflow.trigger = trigger
        workflow.steps = try Self.valid(steps)
        workflow.updatedAt = clock.now()
        try await workflows.upsert(workflow)
        return workflow
    }

    @discardableResult
    public func setEnabled(_ id: WorkflowID, _ isEnabled: Bool) async throws -> Workflow {
        var workflow = try await workflows.require(id: id)
        workflow.isEnabled = isEnabled
        workflow.updatedAt = clock.now()
        try await workflows.upsert(workflow)
        return workflow
    }

    /// A copy, turned off so two workflows don't both run on the same share.
    @discardableResult
    public func duplicate(_ id: WorkflowID, name: String) async throws -> Workflow {
        let original = try await workflows.require(id: id)
        let copy = Workflow(
            name: try Validation.name(name, maximumLength: Self.maximumNameLength),
            trigger: original.trigger,
            steps: original.steps.map { WorkflowStep(kind: $0.kind, parameters: $0.parameters) },
            isEnabled: false, createdAt: clock.now()
        )
        try await workflows.upsert(copy)
        return copy
    }

    public func delete(_ id: WorkflowID) async throws {
        try await workflows.delete(id: id)
    }

    public func markRun(_ id: WorkflowID) async throws {
        guard var workflow = try await workflows.fetch(id: id) else { return }
        workflow.lastRunAt = clock.now()
        try await workflows.upsert(workflow)
    }

    /// Enabled workflows that start on this kind of shared content.
    public func matching(_ triggers: Set<WorkflowTrigger>) async throws -> [Workflow] {
        try await list().filter { $0.isEnabled && triggers.contains($0.trigger) }
    }

    static func valid(_ steps: [WorkflowStep]) throws -> [WorkflowStep] {
        guard !steps.isEmpty else { throw TaskLensError.validationFailed(.emptyContent) }
        guard steps.count <= maximumSteps else { throw TaskLensError.validationFailed(.nameTooLong) }
        return steps
    }

    /// Which triggers shared content fires.
    public static func triggers(for content: ContextContent) -> Set<WorkflowTrigger> {
        switch content {
        case .url: return [.sharedURL]
        case .file(let file):
            switch file.kind {
            case .image: return [.sharedImage]
            case .pdf: return [.sharedPDF]
            case .text, .document, .powerpoint: return []
            }
        case .text(let text):
            var triggers: Set<WorkflowTrigger> = [.sharedText]
            if ContextEngine.analyze(text: text).entities.contains(where: { $0.type == .currencyAmount }) {
                triggers.insert(.currency)
            }
            return triggers
        }
    }

    /// Ready-made workflows the user can add and change.
    public static func templates(currency: String = "IQD") -> [(name: String, trigger: WorkflowTrigger, steps: [WorkflowStep])] {
        [
            ("Save links to Research", .sharedURL, [
                WorkflowStep(kind: .extract),
                WorkflowStep(kind: .save, parameters: [WorkflowStep.ParameterKey.workspace: "Research"]),
            ]),
            ("Summarize a link", .sharedURL, [
                WorkflowStep(kind: .extract), WorkflowStep(kind: .save), WorkflowStep(kind: .summarize),
            ]),
            ("Image to text", .sharedImage, [
                WorkflowStep(kind: .recognizeText), WorkflowStep(kind: .extract), WorkflowStep(kind: .save),
            ]),
            ("Translate an image", .sharedImage, [
                WorkflowStep(kind: .recognizeText), WorkflowStep(kind: .extract),
                WorkflowStep(kind: .translate, parameters: [WorkflowStep.ParameterKey.language: "ar"]), WorkflowStep(kind: .save),
            ]),
            ("Convert to \(currency)", .currency, [
                WorkflowStep(kind: .convertCurrency, parameters: [WorkflowStep.ParameterKey.currency: currency]),
                WorkflowStep(kind: .calculate), WorkflowStep(kind: .save),
            ]),
            ("PDF to notes", .sharedPDF, [
                WorkflowStep(kind: .extract), WorkflowStep(kind: .summarize), WorkflowStep(kind: .createNote),
            ]),
        ]
    }
}

/// Runs a workflow's steps in order on one input.
public struct WorkflowRunner: Sendable {
    private let capture: CaptureService
    private let notes: NoteService
    private let calculator: CalculatorService
    private let workspaces: WorkspaceService
    private let sessions: SessionService
    private let ai: AIService?
    private let reader: (any WorkflowContentReading)?

    public init(
        capture: CaptureService, notes: NoteService, calculator: CalculatorService,
        workspaces: WorkspaceService, sessions: SessionService,
        ai: AIService?, reader: (any WorkflowContentReading)?
    ) {
        self.capture = capture
        self.notes = notes
        self.calculator = calculator
        self.workspaces = workspaces
        self.sessions = sessions
        self.ai = ai
        self.reader = reader
    }

    /// Runs `workflow` on `input`. `savedItem` is the item a share already
    /// saved; a Save step moves it instead of saving a copy. A sensitive
    /// workflow runs only with `confirmed`.
    public func run(_ workflow: Workflow, input: WorkflowInput, savedItem: ContextItemID? = nil, confirmed: Bool) async -> WorkflowRunResult {
        guard confirmed || !workflow.isSensitive else {
            return WorkflowRunResult(state: .needsConfirmation, steps: [], output: "", savedItemIDs: [], noteIDs: [])
        }
        var state = RunState(input: input, savedItem: savedItem)
        if case .file(let url, let kind, _) = input, kind == .pdf || kind == .text {
            state.text = (try? await fileText(url, kind: kind)) ?? ""
        }
        var results: [WorkflowStepResult] = []
        for step in workflow.steps {
            if Task.isCancelled { break }
            let outcome: WorkflowStepResult.Outcome
            do {
                outcome = try await perform(step, workflow: workflow, state: &state)
            } catch {
                outcome = .failed(String(describing: error))
            }
            results.append(WorkflowStepResult(step: step, outcome: outcome))
        }
        return WorkflowRunResult(state: .completed, steps: results, output: state.text, savedItemIDs: state.savedItemIDs, noteIDs: state.noteIDs)
    }

    struct RunState {
        var input: WorkflowInput
        var text: String
        var entities: [DetectedEntity] = []
        var conversion: CalculatorEngine.Completion?
        var savedItem: ContextItemID?
        var savedItemIDs: [ContextItemID] = []
        var noteIDs: [NoteID] = []
        var session: Session?

        init(input: WorkflowInput, savedItem: ContextItemID?) {
            self.input = input
            self.savedItem = savedItem
            switch input {
            case .text(let text): self.text = text
            case .url(let url): self.text = url.absoluteString
            case .file: self.text = ""
            }
        }

        /// The text changed from what was shared (OCR, a conversion, an AI answer).
        var isOriginal: Bool {
            switch input {
            case .text(let original): text == original
            case .url(let url): text == url.absoluteString
            case .file: text.isEmpty
            }
        }
    }

    private func fileText(_ url: URL, kind: FileKind) async throws -> String {
        if kind == .pdf, let reader { return try await reader.text(ofPDFAt: url) }
        let data = try Data(contentsOf: url)
        return String(decoding: data.prefix(DocumentService.maximumSearchTextLength * 4), as: UTF8.self)
    }

    private func perform(_ step: WorkflowStep, workflow: Workflow, state: inout RunState) async throws -> WorkflowStepResult.Outcome {
        switch step.kind {
        case .recognizeText:
            guard case .file(let url, .image, _) = state.input else { return .skipped(.notAnImage) }
            guard let reader else { return .skipped(.notAnImage) }
            let text = try await reader.recognizeText(inImageAt: url)
            guard !text.isEmpty else { return .skipped(.noText) }
            state.text = text
            return .done(detail: String(text.prefix(200)))

        case .extract:
            guard !state.text.isEmpty else { return .skipped(.noText) }
            state.entities = ContextEngine.analyze(text: String(state.text.prefix(20_000))).entities
            let found = state.entities.compactMap(\.matchedText)
            return .done(detail: found.prefix(10).joined(separator: "\n"))

        case .convertCurrency:
            if state.entities.isEmpty { state.entities = ContextEngine.analyze(text: state.text).entities }
            guard let found = state.entities.lazy.compactMap(Self.currency).first else { return .skipped(.noAmount) }
            let (amount, code) = found
            let target = step.parameters[WorkflowStep.ParameterKey.currency] ?? ""
            guard let rateText = step.parameters[WorkflowStep.ParameterKey.rate],
                  let rate = Decimal(string: rateText, locale: Locale(identifier: "en_US_POSIX")), rate > 0
            else { return .skipped(.noRate) }
            let result = amount * rate
            let expression = "\(CalculatorEngine.text(for: amount)) × \(CalculatorEngine.text(for: rate))"
            state.conversion = CalculatorEngine.Completion(expression: expression, result: result)
            let line = "\(CalculatorEngine.text(for: amount)) \(code ?? "") = \(CalculatorEngine.text(for: result)) \(target)"
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            state.text = line
            return .done(detail: line)

        case .calculate:
            let completion = state.conversion ?? CalculatorEngine.evaluate(state.text)
            guard let completion else { return .skipped(.nothingToCalculate) }
            try await calculator.record(completion)
            if state.conversion == nil {
                state.text = "\(completion.expression) = \(CalculatorEngine.text(for: completion.result))"
            }
            return .done(detail: "\(completion.expression) = \(CalculatorEngine.text(for: completion.result))")

        case .summarize, .translate, .generateNotes:
            return await runAI(step, state: &state)

        case .save:
            let session = try await targetSession(named: step.parameters[WorkflowStep.ParameterKey.workspace])
            state.session = session
            if let savedItem = state.savedItem, state.isOriginal {
                // A share already saved this; put it where the workflow says.
                let item = try await capture.move(savedItem, to: session?.id)
                state.savedItemIDs.append(item.id)
                state.savedItem = nil
                return .done(detail: session?.title ?? "")
            }
            let content: ContextContent
            switch state.input {
            case .url(let url) where state.isOriginal: content = .url(url)
            default:
                guard !state.text.isEmpty else { return .skipped(.noText) }
                content = .text(state.text)
            }
            let item = try await capture.capture(content, source: .workflow, into: session?.id,
                                                 metadata: ["workflow": .string(workflow.name)])
            state.savedItemIDs.append(item.id)
            return .done(detail: session?.title ?? "")

        case .createNote:
            guard !state.text.isEmpty else { return .skipped(.noText) }
            let note = try await notes.create(
                title: String(workflow.name.prefix(NoteService.maximumTitleLength)), body: state.text,
                workspaceID: state.session?.workspaceID, sessionID: state.session?.id
            )
            state.noteIDs.append(note.id)
            return .done(detail: note.title)

        default:
            return .skipped(.noText)
        }
    }

    private func runAI(_ step: WorkflowStep, state: inout RunState) async -> WorkflowStepResult.Outcome {
        guard let ai else { return .skipped(.aiUnavailable) }
        guard !state.text.isEmpty else { return .skipped(.noText) }
        let task: AITask = switch step.kind {
        case .translate: .translate
        case .generateNotes: .generateNotes
        default: .summarize
        }
        let language = step.parameters[WorkflowStep.ParameterKey.language] == "en" ? "English" : "Arabic"
        let entities = state.entities.prefix(10).compactMap { entity in entity.matchedText.map { "\(entity.type.rawValue): \($0)" } }
        guard let request = try? AIRequestBuilder.request(task, input: AIInput(
            text: state.text, entities: Array(entities), targetLanguage: task == .translate ? language : nil
        )) else { return .skipped(.noText) }
        switch await ai.run(request) {
        case .answer(let answer, _):
            state.text = answer.text
            return .done(detail: String(answer.text.prefix(200)))
        case .unavailable(let reason):
            switch reason {
            case .turnedOff: return .skipped(.aiTurnedOff)
            case .offline: return .skipped(.aiOffline)
            default: return .skipped(.aiUnavailable)
            }
        case .failed(let message):
            return .failed(message)
        }
    }

    /// The active session of the named workspace (started if needed), or the
    /// current capture target, or nil for the inbox.
    private func targetSession(named name: String?) async throws -> Session? {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return try await sessions.captureTarget(preferring: nil) }
        let all = try await workspaces.list()
        guard let workspace = all.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            return nil
        }
        if let session = try await sessions.activeSession(in: workspace.id) { return session }
        return try await sessions.start(in: workspace.id)
    }

    static func currency(_ entity: DetectedEntity) -> (Decimal, String?)? {
        if case .currency(let amount, let code) = entity.value { return (amount, code) }
        return nil
    }
}

extension ContextSource {
    /// Saved by a workflow.
    public static let workflow: ContextSource = "workflow"
}

/// A sensitive workflow a share started, waiting for the user's OK.
public struct PendingWorkflowRun: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let workflow: Workflow
    public let input: WorkflowInput
    public let itemID: ContextItemID?

    public init(id: UUID = UUID(), workflow: Workflow, input: WorkflowInput, itemID: ContextItemID?) {
        self.id = id
        self.workflow = workflow
        self.input = input
        self.itemID = itemID
    }
}

/// Runs enabled workflows on items shared to TaskLens. Workflows without
/// sensitive steps run right away; the others wait for confirmation.
public struct WorkflowAutomation: Sendable {
    private let service: WorkflowService
    private let runner: WorkflowRunner
    private let documents: DocumentService

    public init(service: WorkflowService, runner: WorkflowRunner, documents: DocumentService) {
        self.service = service
        self.runner = runner
        self.documents = documents
    }

    public struct Outcome: Sendable, Equatable {
        public var completed: [WorkflowRunResult] = []
        public var pending: [PendingWorkflowRun] = []
    }

    public func handle(_ items: [ContextItem]) async -> Outcome {
        var outcome = Outcome()
        for item in items {
            let triggers = WorkflowService.triggers(for: item.content)
            guard !triggers.isEmpty,
                  let workflows = try? await service.matching(triggers), !workflows.isEmpty,
                  let input = await input(for: item)
            else { continue }
            // One item is saved (moved) by at most one workflow.
            var savedItem: ContextItemID? = item.id
            for workflow in workflows {
                if workflow.isSensitive {
                    outcome.pending.append(PendingWorkflowRun(workflow: workflow, input: input, itemID: item.id))
                    continue
                }
                let result = await runner.run(workflow, input: input, savedItem: savedItem, confirmed: false)
                if result.savedItemIDs.contains(item.id) { savedItem = nil }
                try? await service.markRun(workflow.id)
                outcome.completed.append(result)
            }
        }
        return outcome
    }

    /// Runs a pending workflow after the user confirmed it.
    public func confirm(_ pending: PendingWorkflowRun) async -> WorkflowRunResult {
        let result = await runner.run(pending.workflow, input: pending.input, savedItem: pending.itemID, confirmed: true)
        try? await service.markRun(pending.workflow.id)
        return result
    }

    /// What a workflow reads from a saved item.
    public func input(for item: ContextItem) async -> WorkflowInput? {
        switch item.content {
        case .text(let text): return .text(text)
        case .url(let url): return .url(url)
        case .file(let file):
            guard let id = item.metadata["documentID"]?.stringValue.flatMap(DocumentID.init(uuidString:)),
                  let document = try? await documents.document(id: id)
            else { return nil }
            return .file(documents.fileURL(for: document), kind: file.kind, title: document.title)
        }
    }
}
