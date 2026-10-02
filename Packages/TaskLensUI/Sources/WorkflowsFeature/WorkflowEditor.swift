import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization

/// Name, trigger and steps. Steps can be added, removed, reordered and given
/// their options (a workspace, a currency and rate, a language).
struct WorkflowEditor: View {
    @State private var draft: WorkflowDraft
    @State private var isSaving = false
    let save: (WorkflowDraft) async -> Bool
    @Environment(\.dismiss) private var dismiss

    init(draft: WorkflowDraft, save: @escaping (WorkflowDraft) async -> Bool) {
        _draft = State(initialValue: draft)
        self.save = save
    }

    var body: some View {
        Form {
            Section {
                TextField(L10n.string(.workflowsEditorName), text: $draft.name)
                    .accessibilityIdentifier("workflowEditor.name")
                Picker(selection: $draft.trigger) {
                    ForEach(WorkflowTrigger.all, id: \.self) { trigger in
                        Text(WorkflowText.triggerKey(trigger)).tag(trigger)
                    }
                } label: {
                    Text(L10nKey.workflowsEditorTrigger)
                }
                .accessibilityIdentifier("workflowEditor.trigger")
            }

            Section {
                ForEach($draft.steps) { $step in
                    StepEditor(step: $step)
                }
                .onDelete { draft.steps.remove(atOffsets: $0) }
                .onMove { draft.steps.move(fromOffsets: $0, toOffset: $1) }
                if draft.steps.count < WorkflowService.maximumSteps {
                    Menu {
                        ForEach(WorkflowStepKind.all, id: \.self) { kind in
                            Button {
                                draft.steps.append(WorkflowStep(kind: kind))
                            } label: {
                                Text(WorkflowText.stepKey(kind))
                            }
                            .accessibilityIdentifier("workflowEditor.add.\(kind.rawValue)")
                        }
                    } label: {
                        // The whole row opens the menu, not only its text.
                        TLLabel(.workflowsEditorAddStep, systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("workflowEditor.addStep")
                }
            } header: {
                Text(L10nKey.workflowsEditorSteps)
            } footer: {
                if draft.isSensitive {
                    Text(L10nKey.workflowsEditorSensitiveFooter)
                }
            }
        }
        .navigationTitle(Text(draft.id == nil ? L10nKey.workflowsNew : L10nKey.commonEdit))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Text(L10nKey.commonCancel) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    isSaving = true
                    Task {
                        if await save(draft) { dismiss() }
                        isSaving = false
                    }
                } label: {
                    Text(L10nKey.commonSave)
                }
                .disabled(!draft.canSave || isSaving)
                .accessibilityIdentifier("workflowEditor.save")
            }
            ToolbarItem(placement: .bottomBar) {
                EditButton()
            }
        }
    }
}

struct StepEditor: View {
    @Binding var step: WorkflowStep

    var body: some View {
        VStack(alignment: .leading, spacing: TLSpacing.xs) {
            Label {
                Text(WorkflowText.stepKey(step.kind))
            } icon: {
                Image(systemName: step.kind.isSensitive ? "sparkles" : "gearshape")
            }
            switch step.kind {
            case .save:
                TextField(L10n.string(.workflowsEditorWorkspace), text: parameter(WorkflowStep.ParameterKey.workspace))
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("workflowEditor.workspace")
            case .convertCurrency:
                TextField(L10n.string(.workflowsEditorCurrency), text: parameter(WorkflowStep.ParameterKey.currency))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("workflowEditor.currency")
                TextField(L10n.string(.workflowsEditorRate), text: parameter(WorkflowStep.ParameterKey.rate))
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("workflowEditor.rate")
                Text(L10nKey.workflowsEditorRateFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .translate:
                Picker(selection: parameter(WorkflowStep.ParameterKey.language, default: "ar")) {
                    Text(L10nKey.aiLanguageArabic).tag("ar")
                    Text(L10nKey.aiLanguageEnglish).tag("en")
                } label: {
                    Text(L10nKey.aiTargetLanguage)
                }
            default:
                EmptyView()
            }
        }
        .accessibilityIdentifier("workflowEditor.step.\(step.kind.rawValue)")
    }

    private func parameter(_ key: String, default value: String = "") -> Binding<String> {
        Binding {
            step.parameters[key] ?? value
        } set: { newValue in
            // Rates are stored in a fixed format, whatever the keyboard's decimal mark.
            let stored = key == WorkflowStep.ParameterKey.rate
                ? newValue.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "٫", with: ".")
                : newValue
            step.parameters[key] = stored.isEmpty ? nil : stored
        }
    }
}
