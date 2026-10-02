import Observation
import SwiftUI
import TLDesignSystem
import TLLocalization

/// Settings › Your Data: export a copy, or delete everything.
@MainActor
@Observable
public final class DataControlModel {
    public private(set) var exportedFile: URL?
    public private(set) var isWorking = false
    public private(set) var didDeleteEverything = false
    public var errorMessage: String?

    private let export: @Sendable () async throws -> URL
    private let deleteEverything: @Sendable () async throws -> Void
    /// Lets the rest of the app reload after everything was deleted.
    @ObservationIgnored public var onDeleted: (() -> Void)?

    public init(export: @escaping @Sendable () async throws -> URL, deleteEverything: @escaping @Sendable () async throws -> Void) {
        self.export = export
        self.deleteEverything = deleteEverything
    }

    public func makeExport() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            exportedFile = try await export()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    public func deleteAll() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await deleteEverything()
            exportedFile = nil
            didDeleteEverything = true
            onDeleted?()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }
}

struct DataControlSection: View {
    @Bindable var model: DataControlModel
    @State private var isConfirmingDelete = false

    var body: some View {
        Section {
            Button {
                Task { await model.makeExport() }
            } label: {
                TLLabel(.settingsDataExport, systemImage: "square.and.arrow.up")
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier("settings.export")
            if let file = model.exportedFile {
                ShareLink(item: file) {
                    TLLabel(.settingsDataShareExport, systemImage: "doc.badge.arrow.up")
                }
                .accessibilityIdentifier("settings.export.share")
            }
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                TLLabel(.settingsDataDeleteAll, systemImage: "trash")
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier("settings.deleteAll")
            .confirmationDialog(Text(L10nKey.settingsDataDeleteAllTitle), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button(role: .destructive) {
                    Task { await model.deleteAll() }
                } label: {
                    Text(L10nKey.settingsDataDeleteAll)
                }
                .accessibilityIdentifier("settings.deleteAll.confirm")
            } message: {
                Text(L10nKey.settingsDataDeleteAllMessage)
            }
            if model.didDeleteEverything {
                Label {
                    Text(L10nKey.settingsDataDeleted)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .accessibilityIdentifier("settings.deleted")
            }
        } header: {
            Text(L10nKey.settingsData)
        } footer: {
            Text(L10nKey.settingsDataFooter)
        }
        .errorAlert(message: $model.errorMessage)
    }
}
