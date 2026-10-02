import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization

/// Settings › AI: what AI does, what is sent and when, the optional server,
/// and history with delete controls.
public struct AISettingsSection: View {
    @Bindable var model: AISettingsModel
    @State private var apiKey = ""
    @State private var isConfirmingDelete = false

    public init(model: AISettingsModel) {
        self.model = model
    }

    public var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.settings.isEnabled }, set: { value in Task { await model.setEnabled(value) } })) {
                Text(L10nKey.aiSettingsEnabled)
            }
            .accessibilityIdentifier("ai.settings.enabled")
            if let availability = model.availability {
                LabeledContent {
                    switch availability {
                    case .available: Text(L10nKey.aiStatusReady)
                    case .unavailable(let reason): Text(L10nKey.aiUnavailable(reason))
                    }
                } label: {
                    Text(L10nKey.aiStatus)
                }
                .accessibilityIdentifier("ai.settings.status")
            }
            Text(L10nKey.aiSettingsPrivacy)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(L10nKey.aiSection)
        }

        Section {
            TextField(L10n.string(.aiServerAddress), text: $model.serverAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(model.settings.allowsServer)
                .accessibilityIdentifier("ai.server.address")
            TextField(L10n.string(.aiServerModel), text: $model.serverModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(model.settings.allowsServer)
                .accessibilityIdentifier("ai.server.model")
            SecureField(L10n.string(model.hasAPIKey ? .aiServerKeySaved : .aiServerKey), text: $apiKey)
                .onSubmit {
                    model.setAPIKey(apiKey)
                    apiKey = ""
                }
                .accessibilityIdentifier("ai.server.key")
            Toggle(isOn: Binding(get: { model.settings.allowsServer }, set: { value in
                if !apiKey.isEmpty {
                    model.setAPIKey(apiKey)
                    apiKey = ""
                }
                Task { await model.setAllowsServer(value) }
            })) {
                Text(L10nKey.aiServerUse)
            }
            .accessibilityIdentifier("ai.server.enabled")
            if model.settings.serverURL != nil || model.hasAPIKey {
                Button(role: .destructive) {
                    Task { await model.removeServer() }
                } label: {
                    TLLabel(.aiServerRemove, systemImage: "trash")
                }
            }
        } header: {
            Text(L10nKey.aiServerSection)
        } footer: {
            Text(L10nKey.aiServerFooter)
        }

        Section {
            Toggle(isOn: Binding(get: { model.settings.keepsHistory }, set: { value in Task { await model.setKeepsHistory(value) } })) {
                Text(L10nKey.aiHistoryKeep)
            }
            .accessibilityIdentifier("ai.history.keep")
            NavigationLink {
                AIHistoryView(model: model)
            } label: {
                LabeledContent {
                    Text(model.history.count, format: .number)
                } label: {
                    Text(L10nKey.aiHistory)
                }
            }
            .accessibilityIdentifier("ai.history")
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                TLLabel(.aiHistoryDelete, systemImage: "trash")
            }
            .disabled(model.history.isEmpty)
            .accessibilityIdentifier("ai.history.delete")
            .confirmationDialog(Text(L10nKey.aiHistoryDelete), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button(role: .destructive) {
                    Task { await model.deleteHistory() }
                } label: {
                    Text(L10nKey.aiHistoryDelete)
                }
                .accessibilityIdentifier("ai.history.deleteConfirm")
            }
        } footer: {
            Text(L10nKey.aiHistoryFooter)
        }
        .task { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }
}

/// What was sent, where, and the answer. Each can be deleted.
struct AIHistoryView: View {
    let model: AISettingsModel

    var body: some View {
        List {
            if model.history.isEmpty {
                Text(L10nKey.aiHistoryEmpty)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.history) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10nKey.aiTask(AITask(rawValue: record.task) ?? .summarize))
                        .font(.headline)
                    Text(verbatim: record.provider == .onDevice
                        ? L10n.format(.aiDisclosureDevice, record.sentCharacters)
                        : L10n.format(.aiDisclosureServer, record.sentCharacters, record.destination))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: record.output)
                        .lineLimit(3)
                    Text(record.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("ai.history.row")
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await model.delete(record) }
                    } label: {
                        Text(L10nKey.commonDelete)
                    }
                }
            }
        }
        .navigationTitle(Text(L10nKey.aiHistory))
    }
}

extension L10nKey {
    static func aiTask(_ task: AITask) -> L10nKey {
        L10nKey(rawValue: "ai.task.\(task.rawValue)") ?? .aiTaskSummarize
    }

    static func aiUnavailable(_ reason: AIUnavailableReason) -> L10nKey {
        L10nKey(rawValue: "ai.unavailable.\(reason.rawValue)") ?? .aiUnavailableNotConfigured
    }
}
