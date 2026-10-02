import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

/// AI choices in Settings: on/off, the optional AI server, history, deletion.
@MainActor
@Observable
public final class AISettingsModel {
    public private(set) var settings: AISettings
    public private(set) var availability: AIAvailability?
    public private(set) var history: [AIRecord] = []
    public private(set) var hasAPIKey: Bool
    public var serverAddress: String
    public var serverModel: String
    public var errorMessage: String?

    private let service: AIService
    private let secrets: any SecretStoring

    public init(service: AIService, secrets: any SecretStoring) {
        self.service = service
        self.secrets = secrets
        let settings = service.currentSettings
        self.settings = settings
        self.serverAddress = settings.serverURL?.absoluteString ?? ""
        self.serverModel = settings.serverModel
        self.hasAPIKey = secrets.secret(for: AIServerProvider.apiKeySecret) != nil
    }

    public func load() async {
        settings = service.currentSettings
        hasAPIKey = secrets.secret(for: AIServerProvider.apiKeySecret) != nil
        availability = await service.availability()
        history = (try? await service.history()) ?? []
    }

    public func setEnabled(_ isEnabled: Bool) async {
        change { $0.isEnabled = isEnabled }
        await load()
    }

    public func setKeepsHistory(_ keeps: Bool) async {
        change { $0.keepsHistory = keeps }
        // Turning history off also deletes what was kept.
        if !keeps { await deleteHistory() }
    }

    /// Turns the server on only with a valid HTTPS address and a model name.
    public func setAllowsServer(_ allows: Bool) async {
        if allows {
            let url = URL(string: serverAddress.trimmingCharacters(in: .whitespacesAndNewlines))
            let model = serverModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard AISettings.isValidServerURL(url), !model.isEmpty else {
                errorMessage = L10n.string(.aiServerInvalid)
                return
            }
            change {
                $0.serverURL = url
                $0.serverModel = model
                $0.allowsServer = true
            }
        } else {
            change { $0.allowsServer = false }
        }
        await load()
    }

    /// Stored in the Keychain on this device only. Empty removes it.
    public func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        secrets.setSecret(trimmed.isEmpty ? nil : trimmed, for: AIServerProvider.apiKeySecret)
        hasAPIKey = !trimmed.isEmpty
    }

    /// Removes the server address, model and key.
    public func removeServer() async {
        secrets.setSecret(nil, for: AIServerProvider.apiKeySecret)
        hasAPIKey = false
        serverAddress = ""
        serverModel = ""
        change {
            $0.allowsServer = false
            $0.serverURL = nil
            $0.serverModel = ""
        }
        await load()
    }

    public func delete(_ record: AIRecord) async {
        try? await service.delete(record.id)
        history.removeAll { $0.id == record.id }
    }

    public func deleteHistory() async {
        do {
            try await service.deleteHistory()
            history = []
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    private func change(_ update: (inout AISettings) -> Void) {
        service.update(update)
        settings = service.currentSettings
    }
}
