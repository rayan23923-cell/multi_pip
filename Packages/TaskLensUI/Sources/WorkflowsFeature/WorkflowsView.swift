import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization

/// Workflows: what runs when you share something, and what you run yourself.
public struct WorkflowsView: View {
    @Bindable var model: WorkflowsModel
    @State private var editing: WorkflowDraft?
    @State private var running: Workflow?

    public init(model: WorkflowsModel) {
        self.model = model
    }

    public var body: some View {
        List {
            if !model.pending.isEmpty {
                Section {
                    ForEach(model.pending) { run in
                        PendingRunRow(run: run) {
                            Task { await model.confirm(run) }
                        } dismiss: {
                            model.dismiss(run)
                        }
                    }
                } header: {
                    Text(L10nKey.workflowsPending)
                } footer: {
                    Text(L10nKey.workflowsPendingFooter)
                }
            }

            if let result = model.lastResult {
                WorkflowResultSection(name: model.lastRunName, result: result) { model.clearResult() }
            }

            Section {
                if model.hasLoaded && model.workflows.isEmpty {
                    Text(L10nKey.workflowsEmpty)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("workflows.empty")
                }
                ForEach(model.workflows) { workflow in
                    WorkflowRow(workflow: workflow) {
                        running = workflow
                    } setEnabled: { isEnabled in
                        Task { await model.setEnabled(workflow, isEnabled) }
                    }
                    .contextMenu { menu(for: workflow) }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await model.delete(workflow) }
                        } label: {
                            TLLabel(.commonDelete, systemImage: "trash")
                        }
                        Button {
                            editing = WorkflowDraft(workflow)
                        } label: {
                            TLLabel(.commonEdit, systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            } footer: {
                Text(L10nKey.workflowsFooter)
            }
        }
        .navigationTitle(Text(L10nKey.workflowsTitle))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        editing = WorkflowDraft()
                    } label: {
                        TLLabel(.workflowsNew, systemImage: "plus")
                    }
                    .accessibilityIdentifier("workflows.new")
                    Section {
                        ForEach(WorkflowService.templates().indices, id: \.self) { index in
                            Button {
                                Task { await model.addTemplate(index) }
                            } label: {
                                Text(WorkflowsModel.templateKey(index))
                            }
                            .accessibilityIdentifier("workflows.template.\(index)")
                        }
                    } header: {
                        Text(L10nKey.workflowsTemplates)
                    }
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel(Text(L10nKey.workflowsNew))
                }
                .accessibilityIdentifier("workflows.add")
            }
        }
        .sheet(item: $editing) { draft in
            NavigationStack {
                WorkflowEditor(draft: draft) { saved in
                    await model.save(saved)
                }
            }
        }
        .sheet(item: $running) { workflow in
            NavigationStack {
                WorkflowRunSheet(workflow: workflow, model: model)
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }

    @ViewBuilder
    private func menu(for workflow: Workflow) -> some View {
        Button {
            running = workflow
        } label: {
            TLLabel(.workflowsRun, systemImage: "play")
        }
        Button {
            editing = WorkflowDraft(workflow)
        } label: {
            TLLabel(.commonEdit, systemImage: "pencil")
        }
        .accessibilityIdentifier("workflows.edit")
        Button {
            Task { await model.duplicate(workflow) }
        } label: {
            TLLabel(.commonDuplicate, systemImage: "plus.square.on.square")
        }
        .accessibilityIdentifier("workflows.duplicate")
        Button(role: .destructive) {
            Task { await model.delete(workflow) }
        } label: {
            TLLabel(.commonDelete, systemImage: "trash")
        }
        .accessibilityIdentifier("workflows.delete")
    }
}

extension WorkflowDraft: Identifiable {}

struct WorkflowRow: View {
    let workflow: Workflow
    let open: () -> Void
    let setEnabled: (Bool) -> Void

    var body: some View {
        HStack(spacing: TLSpacing.s) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: workflow.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(verbatim: WorkflowText.pipeline(workflow.trigger, workflow.steps))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if workflow.isSensitive {
                        Label {
                            Text(L10nKey.workflowsAsksFirst)
                        } icon: {
                            Image(systemName: "hand.raised")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(L10nKey.workflowsRun))
            Toggle(isOn: Binding(get: { workflow.isEnabled }, set: setEnabled)) {
                Text(verbatim: workflow.name)
            }
            .labelsHidden()
            .accessibilityIdentifier("workflows.toggle.\(workflow.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflows.row.\(workflow.name)")
    }
}

struct PendingRunRow: View {
    let run: PendingWorkflowRun
    let confirm: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TLSpacing.xs) {
            Text(verbatim: run.workflow.name)
                .font(.headline)
            Text(verbatim: WorkflowText.inputSummary(run.input))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(L10nKey.workflowsConfirmMessage)
                .font(.footnote)
            HStack {
                Button(action: confirm) {
                    TLLabel(.workflowsConfirmRun, systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("workflows.pending.run")
                Button(action: dismiss) {
                    Text(L10nKey.workflowsDismiss)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("workflows.pending.dismiss")
            }
        }
        .padding(.vertical, TLSpacing.xs)
    }
}

/// What each step did.
struct WorkflowResultSection: View {
    let name: String?
    let result: WorkflowRunResult
    let clear: () -> Void

    var body: some View {
        Section {
            ForEach(result.steps) { step in
                HStack(alignment: .top, spacing: TLSpacing.s) {
                    Image(systemName: symbol(step.outcome))
                        .foregroundStyle(color(step.outcome))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkflowText.stepKey(step.step.kind))
                        switch step.outcome {
                        case .done(let detail) where !detail.isEmpty:
                            Text(verbatim: detail).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                        case .skipped(let reason):
                            Text(WorkflowText.skipKey(reason)).font(.footnote).foregroundStyle(.secondary)
                        case .failed:
                            Text(L10nKey.workflowsFailed).font(.footnote).foregroundStyle(.secondary)
                        default:
                            EmptyView()
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("workflows.result.step")
            }
            if !result.savedItemIDs.isEmpty || !result.noteIDs.isEmpty {
                Label {
                    Text(L10nKey.workflowsResultSaved)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .accessibilityIdentifier("workflows.result.saved")
            }
            Button(action: clear) {
                TLLabel(.aiClear, systemImage: "xmark.circle")
            }
        } header: {
            if let name {
                Text(verbatim: L10n.format(.workflowsResultTitle, name))
            } else {
                Text(L10nKey.workflowsResult)
            }
        }
    }

    private func symbol(_ outcome: WorkflowStepResult.Outcome) -> String {
        switch outcome {
        case .done: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func color(_ outcome: WorkflowStepResult.Outcome) -> Color {
        switch outcome {
        case .done: .green
        case .skipped: .secondary
        case .failed: .red
        }
    }
}

/// Run a workflow on typed text or a link. Sensitive workflows ask first.
struct WorkflowRunSheet: View {
    let workflow: Workflow
    let model: WorkflowsModel
    @State private var text = ""
    @State private var isConfirming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Text(verbatim: WorkflowText.pipeline(workflow.trigger, workflow.steps))
                    .foregroundStyle(.secondary)
                TextField(L10n.string(.workflowsInputPlaceholder), text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("workflows.input")
            } footer: {
                if workflow.isSensitive {
                    Text(L10nKey.workflowsEditorSensitiveFooter)
                }
            }
            if let result = model.lastResult, model.lastRunName == workflow.name {
                WorkflowResultSection(name: nil, result: result) { model.clearResult() }
            }
        }
        .navigationTitle(Text(verbatim: workflow.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Text(L10nKey.commonDone) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    if workflow.isSensitive {
                        isConfirming = true
                    } else {
                        Task { await model.run(workflow, text: text, confirmed: false) }
                    }
                } label: {
                    if model.isRunning { ProgressView() } else { Text(L10nKey.workflowsRun) }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning)
                .accessibilityIdentifier("workflows.runButton")
            }
        }
        .confirmationDialog(Text(L10nKey.workflowsConfirmTitle), isPresented: $isConfirming, titleVisibility: .visible) {
            Button {
                Task { await model.run(workflow, text: text, confirmed: true) }
            } label: {
                Text(L10nKey.workflowsConfirmRun)
            }
            .accessibilityIdentifier("workflows.confirmRun")
        } message: {
            Text(L10nKey.workflowsConfirmMessage)
        }
    }
}

/// Localized names for triggers, steps and outcomes.
enum WorkflowText {
    static func triggerKey(_ trigger: WorkflowTrigger) -> L10nKey {
        L10nKey(rawValue: "workflow.trigger.\(trigger.rawValue)") ?? .workflowTriggerManual
    }

    static func stepKey(_ kind: WorkflowStepKind) -> L10nKey {
        L10nKey(rawValue: "workflow.step.\(kind.rawValue)") ?? .workflowStepSave
    }

    static func skipKey(_ reason: WorkflowSkipReason) -> L10nKey {
        L10nKey(rawValue: "workflow.skip.\(reason.rawValue)") ?? .workflowSkipNoText
    }

    /// "Share a link → Extract → Save". Arrows follow the layout direction.
    static func pipeline(_ trigger: WorkflowTrigger, _ steps: [WorkflowStep]) -> String {
        let arrow = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en").characterDirection == .rightToLeft ? " ← " : " → "
        return ([L10n.string(triggerKey(trigger))] + steps.map { L10n.string(stepKey($0.kind)) }).joined(separator: arrow)
    }

    static func inputSummary(_ input: WorkflowInput) -> String {
        switch input {
        case .text(let text): String(text.prefix(120))
        case .url(let url): url.host() ?? url.absoluteString
        case .file(_, _, let title): title
        }
    }
}
