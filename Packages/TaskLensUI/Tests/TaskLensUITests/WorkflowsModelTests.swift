import Foundation
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import WorkflowsFeature

@MainActor
@Suite("Workflows model")
struct WorkflowsModelTests {
    let services = Services()

    func model(ai: AIService? = nil) -> WorkflowsModel {
        let clock = services.clock
        let repositories = services.repositories
        let service = WorkflowService(workflows: repositories.workflows, clock: clock)
        let documents = DocumentService(documents: repositories.documents, filesDirectory: FileManager.default.temporaryDirectory, clock: clock, logger: .disabled())
        let runner = WorkflowRunner(
            capture: services.capture,
            notes: NoteService(notes: repositories.notes, clock: clock, logger: .disabled()),
            calculator: CalculatorService(records: repositories.calculations, clock: clock, logger: .disabled()),
            workspaces: services.workspaces, sessions: services.sessions, ai: ai, reader: nil
        )
        return WorkflowsModel(service: service, runner: runner,
                              automation: WorkflowAutomation(service: service, runner: runner, documents: documents))
    }

    @Test func createRunDuplicateDisableDelete() async throws {
        let model = model()
        await model.load()
        #expect(model.workflows.isEmpty)

        #expect(await model.save(WorkflowDraft(name: "Keep", trigger: .manual, steps: [WorkflowStep(kind: .save)])))
        let workflow = try #require(model.workflows.first)

        await model.run(workflow, text: "Remember the milk", confirmed: false)
        #expect(model.lastResult?.savedItemIDs.count == 1)
        #expect(model.workflows.first?.lastRunAt != nil)

        services.clock.advance(by: 60)
        await model.duplicate(workflow)
        #expect(model.workflows.count == 2)
        #expect(model.workflows.last?.isEnabled == false)

        await model.setEnabled(workflow, false)
        #expect(model.workflows.first?.isEnabled == false)

        await model.delete(workflow)
        #expect(model.workflows.count == 1)
    }

    @Test func invalidDraftIsRefused() async {
        let model = model()
        #expect(!(await model.save(WorkflowDraft(name: "", trigger: .manual, steps: [WorkflowStep(kind: .save)]))))
        #expect(model.errorMessage != nil)
        #expect(!WorkflowDraft(name: "A", steps: []).canSave)
    }

    @Test func sharedLinkRunsQuietWorkflowsAndQueuesSensitiveOnes() async throws {
        let model = model()
        _ = try await services.workspaces.create(WorkspaceDraft(name: "Research", kind: .research))
        await model.save(WorkflowDraft(name: "To Research", trigger: .sharedURL, steps: [
            WorkflowStep(kind: .save, parameters: [WorkflowStep.ParameterKey.workspace: "Research"]),
        ]))
        await model.save(WorkflowDraft(name: "Summarize", trigger: .sharedURL, steps: [WorkflowStep(kind: .summarize)]))
        await model.save(WorkflowDraft(name: "Images", trigger: .sharedImage, steps: [WorkflowStep(kind: .recognizeText)]))

        let shared = try await services.capture.capture(.url(URL(string: "https://swift.org")!), source: .shareExtension)
        await model.handleShared([shared])

        // The quiet one ran; the AI one waits; the image one didn't match.
        #expect(try await services.capture.item(id: shared.id).sessionID != nil)
        #expect(model.pending.map(\.workflow.name) == ["Summarize"])

        let pending = try #require(model.pending.first)
        await model.confirm(pending)
        #expect(model.pending.isEmpty)
        // No AI here: the step is skipped, not failed.
        #expect(model.lastResult?.steps.first?.outcome == .skipped(.aiUnavailable))
    }

    @Test func dismissingAPendingRunRunsNothing() async throws {
        let model = model()
        await model.save(WorkflowDraft(name: "Summarize", trigger: .sharedText, steps: [WorkflowStep(kind: .summarize), WorkflowStep(kind: .save)]))
        let shared = try await services.capture.capture(.text("A long text"), source: .shareExtension)
        await model.handleShared([shared])
        let pending = try #require(model.pending.first)
        model.dismiss(pending)
        #expect(model.pending.isEmpty)
        #expect(model.lastResult == nil)
        #expect(try await services.repositories.contextItems.fetchAll().count == 1)
    }

    @Test func templatesCanBeAdded() async {
        let model = model()
        for index in WorkflowService.templates().indices {
            await model.addTemplate(index)
        }
        #expect(model.workflows.count == WorkflowService.templates().count)
        #expect(model.workflows.allSatisfy { !$0.name.isEmpty })
    }
}
