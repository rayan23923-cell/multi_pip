import Foundation
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation

private struct FakeReader: WorkflowContentReading {
    var imageText = "Menu\nCoffee $4"
    var pdfText = "Chapter 1. Cells are the basic unit of life."
    func recognizeText(inImageAt url: URL) async throws -> String { imageText }
    func text(ofPDFAt url: URL) async throws -> String { pdfText }
}

@Suite("Workflow engine")
struct WorkflowEngineTests {
    let env = TestEnvironment()

    var service: WorkflowService { WorkflowService(workflows: env.repositories.workflows, clock: env.clock) }

    func runner(ai: AIService? = nil) -> WorkflowRunner {
        WorkflowRunner(
            capture: env.capture, notes: env.notes, calculator: env.calculator(),
            workspaces: env.workspaces, sessions: env.sessions, ai: ai, reader: FakeReader()
        )
    }

    func ai(_ provider: FakeAIProvider?, enabled: Bool = true) -> AIService {
        AIService(
            providers: provider.map { [$0] } ?? [], settings: InMemoryAISettingsStore(AISettings(isEnabled: enabled)),
            records: InMemoryRepository<AIRecord>(), clock: env.clock, logger: .disabled()
        )
    }

    // MARK: Managing

    @Test func createEditEnableDuplicateDelete() async throws {
        let created = try await service.create(name: "Links", trigger: .sharedURL, steps: [WorkflowStep(kind: .save)])
        #expect(created.isEnabled)

        let edited = try await service.update(created.id, name: "Research links", trigger: .sharedURL,
                                              steps: [WorkflowStep(kind: .extract), WorkflowStep(kind: .save)])
        #expect(edited.steps.map(\.kind) == [.extract, .save])

        let disabled = try await service.setEnabled(created.id, false)
        #expect(!disabled.isEnabled)
        #expect(try await service.matching([.sharedURL]).isEmpty)

        _ = try await service.setEnabled(created.id, true)
        let copy = try await service.duplicate(created.id, name: "Research links copy")
        #expect(!copy.isEnabled)
        #expect(copy.steps.map(\.kind) == edited.steps.map(\.kind))
        #expect(copy.steps.map(\.id) != edited.steps.map(\.id))
        #expect(try await service.matching([.sharedURL]).map(\.id) == [created.id])

        try await service.delete(created.id)
        #expect(try await service.list().map(\.id) == [copy.id])

        await #expect(throws: TaskLensError.self) {
            try await service.create(name: " ", trigger: .manual, steps: [WorkflowStep(kind: .save)])
        }
        await #expect(throws: TaskLensError.self) {
            try await service.create(name: "Empty", trigger: .manual, steps: [])
        }
    }

    @Test func sharedContentFiresTheRightTriggers() {
        #expect(WorkflowService.triggers(for: .url(URL(string: "https://apple.com")!)) == [.sharedURL])
        #expect(WorkflowService.triggers(for: .text("Total $25")) == [.sharedText, .currency])
        #expect(WorkflowService.triggers(for: .text("hello")) == [.sharedText])
        let image = FileReference(relativePath: "a.jpg", contentType: "public.jpeg", kind: .image)
        #expect(WorkflowService.triggers(for: .file(image)) == [.sharedImage])
    }

    // MARK: Running

    @Test func urlIsSavedToResearch() async throws {
        let research = try await env.workspaces.create(WorkspaceDraft(name: "Research", kind: .research))
        let workflow = try await service.create(name: "Save links", trigger: .sharedURL, steps: [
            WorkflowStep(kind: .extract), WorkflowStep(kind: .save, parameters: [WorkflowStep.ParameterKey.workspace: "research"]),
        ])
        let url = URL(string: "https://swift.org/blog")!
        let result = await runner().run(workflow, input: .url(url), confirmed: false)

        #expect(result.state == .completed)
        #expect(!result.failed)
        let item = try await env.capture.item(id: try #require(result.savedItemIDs.first))
        #expect(item.content == .url(url))
        #expect(item.workspaceID == research.id)
    }

    @Test func sharedItemIsMovedNotCopied() async throws {
        let research = try await env.workspaces.create(WorkspaceDraft(name: "Research", kind: .research))
        let shared = try await env.capture.capture(.url(URL(string: "https://swift.org")!), source: .shareExtension)
        let workflow = try await service.create(name: "Save links", trigger: .sharedURL, steps: [
            WorkflowStep(kind: .save, parameters: [WorkflowStep.ParameterKey.workspace: "Research"]),
        ])
        let result = await runner().run(workflow, input: .url(URL(string: "https://swift.org")!), savedItem: shared.id, confirmed: false)
        #expect(result.savedItemIDs == [shared.id])
        #expect(try await env.capture.item(id: shared.id).workspaceID == research.id)
        #expect(try await env.repositories.contextItems.fetchAll().count == 1)
    }

    @Test func imageIsReadAndSaved() async throws {
        let workflow = try await service.create(name: "Image to text", trigger: .sharedImage, steps: [
            WorkflowStep(kind: .recognizeText), WorkflowStep(kind: .extract), WorkflowStep(kind: .save),
        ])
        let result = await runner().run(workflow, input: .file(URL(fileURLWithPath: "/tmp/menu.jpg"), kind: .image, title: "menu"), confirmed: false)
        #expect(result.output == "Menu\nCoffee $4")
        let item = try await env.capture.item(id: try #require(result.savedItemIDs.first))
        #expect(item.content == .text("Menu\nCoffee $4"))
        #expect(item.source == .workflow)
    }

    @Test func currencyIsConvertedCalculatedAndSaved() async throws {
        let workflow = try await service.create(name: "To IQD", trigger: .currency, steps: [
            WorkflowStep(kind: .convertCurrency, parameters: [WorkflowStep.ParameterKey.currency: "IQD", WorkflowStep.ParameterKey.rate: "1310"]),
            WorkflowStep(kind: .calculate), WorkflowStep(kind: .save),
        ])
        let result = await runner().run(workflow, input: .text("Headphones $120"), confirmed: false)
        #expect(!result.failed)
        #expect(result.output.contains("157200"))
        #expect(result.output.hasSuffix("IQD"))
        let history = try await env.calculator().history()
        #expect(history.first?.result == 157_200)
        #expect(result.savedItemIDs.count == 1)
    }

    @Test func missingRateOrAmountIsSkippedNotGuessed() async throws {
        let workflow = try await service.create(name: "To IQD", trigger: .currency, steps: [
            WorkflowStep(kind: .convertCurrency, parameters: [WorkflowStep.ParameterKey.currency: "IQD"]),
        ])
        let noRate = await runner().run(workflow, input: .text("Headphones $120"), confirmed: false)
        #expect(noRate.steps.first?.outcome == .skipped(.noRate))
        let noAmount = await runner().run(workflow, input: .text("No money here"), confirmed: false)
        #expect(noAmount.steps.first?.outcome == .skipped(.noAmount))
    }

    @Test func pdfBecomesNotesWithAI() async throws {
        let provider = FakeAIProvider(kind: .onDevice, reply: .success("Cells are the unit of life."))
        let workflow = try await service.create(name: "PDF to notes", trigger: .sharedPDF, steps: [
            WorkflowStep(kind: .extract), WorkflowStep(kind: .summarize), WorkflowStep(kind: .createNote),
        ])
        #expect(workflow.isSensitive)
        let input = WorkflowInput.file(URL(fileURLWithPath: "/tmp/bio.pdf"), kind: .pdf, title: "Biology")

        // Sensitive: nothing runs, nothing is sent, until the user confirms.
        let waiting = await runner(ai: ai(provider)).run(workflow, input: input, confirmed: false)
        #expect(waiting.state == .needsConfirmation)
        #expect(provider.sent.isEmpty)
        #expect(try await env.notes.allNotes().isEmpty)

        let result = await runner(ai: ai(provider)).run(workflow, input: input, confirmed: true)
        #expect(provider.sent.count == 1)
        #expect(provider.sent.first?.prompt.contains("Cells are the basic unit") == true)
        let note = try await env.notes.note(id: try #require(result.noteIDs.first))
        #expect(note.title == "PDF to notes")
        #expect(note.body == "Cells are the unit of life.")
    }

    @Test func offlineAISkipsAndKeepsLocalSteps() async throws {
        let workflow = try await service.create(name: "Summarize and save", trigger: .manual, steps: [
            WorkflowStep(kind: .summarize), WorkflowStep(kind: .save),
        ])
        let provider = FakeAIProvider(kind: .onDevice, state: .unavailable(.offline))
        let result = await runner(ai: ai(provider)).run(workflow, input: .text("Long article text"), confirmed: true)
        #expect(result.steps.first?.outcome == .skipped(.aiOffline))
        #expect(result.savedItemIDs.count == 1)
        #expect(result.output == "Long article text")

        let off = await runner(ai: ai(provider, enabled: false)).run(workflow, input: .text("Long article text"), confirmed: true)
        #expect(off.steps.first?.outcome == .skipped(.aiTurnedOff))
    }

    @Test func templatesAreValid() async throws {
        for template in WorkflowService.templates() {
            let workflow = try await service.create(name: template.name, trigger: template.trigger, steps: template.steps)
            #expect(workflow.isSensitive == template.steps.contains { $0.kind.usesAI })
        }
    }
}
