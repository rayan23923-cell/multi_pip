import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

/// The Workflows screen: the user's workflows, runs waiting for an OK, and
/// the result of the last run.
@MainActor
@Observable
public final class WorkflowsModel {
    public private(set) var workflows: [Workflow] = []
    /// Sensitive workflows a share started; they run only after the user's OK.
    public private(set) var pending: [PendingWorkflowRun] = []
    public private(set) var lastResult: WorkflowRunResult?
    public private(set) var lastRunName: String?
    public private(set) var isRunning = false
    public private(set) var hasLoaded = false
    public var errorMessage: String?

    private let service: WorkflowService
    private let runner: WorkflowRunner
    private let automation: WorkflowAutomation?

    public init(service: WorkflowService, runner: WorkflowRunner, automation: WorkflowAutomation? = nil) {
        self.service = service
        self.runner = runner
        self.automation = automation
    }

    public func load() async {
        do {
            workflows = try await service.list()
        } catch {
            errorMessage = L10n.message(for: error)
        }
        hasLoaded = true
    }

    // MARK: Managing

    @discardableResult
    public func save(_ draft: WorkflowDraft) async -> Bool {
        do {
            if let id = draft.id {
                try await service.update(id, name: draft.name, trigger: draft.trigger, steps: draft.steps)
            } else {
                try await service.create(name: draft.name, trigger: draft.trigger, steps: draft.steps)
            }
            await load()
            return true
        } catch {
            errorMessage = L10n.message(for: error)
            return false
        }
    }

    public func addTemplate(_ index: Int) async {
        let templates = WorkflowService.templates()
        guard templates.indices.contains(index) else { return }
        let template = templates[index]
        await save(WorkflowDraft(name: L10n.string(Self.templateKey(index)), trigger: template.trigger, steps: template.steps))
    }

    public func setEnabled(_ workflow: Workflow, _ isEnabled: Bool) async {
        await change { try await self.service.setEnabled(workflow.id, isEnabled) }
    }

    public func duplicate(_ workflow: Workflow) async {
        let name = L10n.format(.workflowsCopyName, workflow.name)
        await change { try await self.service.duplicate(workflow.id, name: String(name.prefix(WorkflowService.maximumNameLength))) }
    }

    public func delete(_ workflow: Workflow) async {
        do {
            try await service.delete(workflow.id)
            pending.removeAll { $0.workflow.id == workflow.id }
            await load()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    private func change(_ operation: @escaping () async throws -> Workflow) async {
        do {
            _ = try await operation()
            await load()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    // MARK: Running

    /// Runs from the Run button on typed text or a link. Sensitive workflows
    /// need `confirmed` (the view asks first).
    public func run(_ workflow: Workflow, text: String, confirmed: Bool) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let input: WorkflowInput
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            input = .url(url)
        } else {
            input = .text(trimmed)
        }
        isRunning = true
        defer { isRunning = false }
        let result = await runner.run(workflow, input: input, confirmed: confirmed)
        if result.state == .completed { try? await service.markRun(workflow.id) }
        lastResult = result
        lastRunName = workflow.name
        await load()
    }

    /// Called by the app after shared items were saved.
    public func handleShared(_ items: [ContextItem]) async {
        guard let automation, !items.isEmpty else { return }
        let outcome = await automation.handle(items)
        pending += outcome.pending
        if let last = outcome.completed.last {
            lastResult = last
        }
        await load()
    }

    public func confirm(_ run: PendingWorkflowRun) async {
        guard let automation else { return }
        pending.removeAll { $0.id == run.id }
        isRunning = true
        defer { isRunning = false }
        lastResult = await automation.confirm(run)
        lastRunName = run.workflow.name
        await load()
    }

    public func dismiss(_ run: PendingWorkflowRun) {
        pending.removeAll { $0.id == run.id }
    }

    public func clearResult() {
        lastResult = nil
        lastRunName = nil
    }

    static func templateKey(_ index: Int) -> L10nKey {
        L10nKey(rawValue: "workflows.template.\(index)") ?? .workflowsNew
    }
}

/// What the editor edits.
public struct WorkflowDraft: Sendable, Equatable {
    public var id: WorkflowID?
    public var name: String
    public var trigger: WorkflowTrigger
    public var steps: [WorkflowStep]

    public init(id: WorkflowID? = nil, name: String = "", trigger: WorkflowTrigger = .manual, steps: [WorkflowStep] = []) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.steps = steps
    }

    public init(_ workflow: Workflow) {
        self.init(id: workflow.id, name: workflow.name, trigger: workflow.trigger, steps: workflow.steps)
    }

    public var isSensitive: Bool { steps.contains { $0.kind.isSensitive } }
    public var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !steps.isEmpty }
}
