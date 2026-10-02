import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

public struct WorkspaceListView: View {
    @State private var model: WorkspaceListModel
    @State private var isCreating = false

    public init(model: WorkspaceListModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            ForEach(model.workspaces) { workspace in
                NavigationLink(value: AppRoute.workspace(workspace.id)) {
                    WorkspaceRow(workspace: workspace)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await model.delete(workspace.id) }
                    } label: {
                        TLLabel(.commonDelete, systemImage: "trash")
                    }
                    Button {
                        Task { await model.archive(workspace.id) }
                    } label: {
                        TLLabel(.workspacesArchive, systemImage: "archivebox")
                    }
                    .tint(.indigo)
                }
            }
        }
        .overlay {
            if model.hasLoaded && model.workspaces.isEmpty {
                TLEmptyState(
                    title: .workspacesEmptyTitle,
                    message: .workspacesEmptyMessage,
                    symbolName: "square.grid.2x2"
                )
            }
        }
        .navigationTitle(Text(L10nKey.tabWorkspaces))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    TLLabel(.workspacesCreate, systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            CreateWorkspaceView { name, color in
                await model.create(name: name, color: color)
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }
}

struct CreateWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: WorkspaceColor = .blue
    @State private var isSaving = false

    private let onCreate: (String, WorkspaceColor) async -> Bool

    init(onCreate: @escaping (String, WorkspaceColor) async -> Bool) {
        self.onCreate = onCreate
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.string(.workspacesName), text: $name)
                    .submitLabel(.done)
                Section {
                    HStack(spacing: TLSpacing.m) {
                        ForEach(WorkspaceColor.allKnown, id: \.self) { option in
                            Button {
                                color = option
                            } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if option == color {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: option.rawValue))
                            .accessibilityAddTraits(option == color ? .isSelected : [])
                        }
                    }
                } header: {
                    Text(L10nKey.workspacesColor)
                }
            }
            .navigationTitle(Text(L10nKey.workspacesCreate))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(L10nKey.commonCancel) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isSaving = true
                            let created = await onCreate(name, color)
                            isSaving = false
                            if created { dismiss() }
                        }
                    } label: {
                        Text(L10nKey.commonCreate)
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
