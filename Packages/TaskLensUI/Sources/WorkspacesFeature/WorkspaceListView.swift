import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

public struct WorkspaceListView: View {
    @State private var model: WorkspaceListModel
    @State private var isCreating = false
    @State private var editing: Workspace?
    @State private var pendingDeletion: Workspace?

    public init(model: WorkspaceListModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            ForEach(model.workspaces) { workspace in
                NavigationLink(value: AppRoute.workspace(workspace.id)) {
                    WorkspaceRow(workspace: workspace)
                }
                .accessibilityIdentifier("workspaceRow.\(workspace.name)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeletion = workspace
                    } label: {
                        TLLabel(.commonDelete, systemImage: "trash")
                    }
                    Button {
                        editing = workspace
                    } label: {
                        TLLabel(.commonEdit, systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        Task { await model.toggleFavorite(workspace) }
                    } label: {
                        favoriteLabel(for: workspace)
                    }
                    .tint(.yellow)
                }
                .contextMenu {
                    Button { editing = workspace } label: { TLLabel(.commonEdit, systemImage: "pencil") }
                    Button { Task { await model.duplicate(workspace) } } label: {
                        TLLabel(.commonDuplicate, systemImage: "plus.square.on.square")
                    }
                    Button { Task { await model.toggleFavorite(workspace) } } label: { favoriteLabel(for: workspace) }
                    Divider()
                    Button(role: .destructive) { pendingDeletion = workspace } label: {
                        TLLabel(.commonDelete, systemImage: "trash")
                    }
                }
            }
            .onMove { source, destination in
                Task { await model.move(fromOffsets: source, toOffset: destination) }
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
            ToolbarItem(placement: .topBarLeading) {
                if !model.workspaces.isEmpty {
                    EditButton()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    TLLabel(.workspacesCreate, systemImage: "plus")
                }
                .accessibilityIdentifier("workspaces.add")
            }
        }
        .sheet(isPresented: $isCreating) {
            WorkspaceEditor(mode: .create) { draft in
                await model.create(draft)
            }
        }
        .sheet(item: $editing) { workspace in
            WorkspaceEditor(mode: .edit, draft: WorkspaceDraft(workspace)) { draft in
                await model.update(workspace.id, with: draft)
            }
        }
        .workspaceDeletionAlert(item: $pendingDeletion) { workspace in
            Task { await model.delete(workspace.id) }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }

    private func favoriteLabel(for workspace: Workspace) -> some View {
        workspace.isFavorite
            ? TLLabel(.commonUnfavorite, systemImage: "star.slash")
            : TLLabel(.commonFavorite, systemImage: "star")
    }
}

extension View {
    /// Asks before deleting, because deletion cascades to sessions and items.
    func workspaceDeletionAlert(item: Binding<Workspace?>, onConfirm: @escaping (Workspace) -> Void) -> some View {
        alert(
            Text(L10nKey.workspaceDeleteTitle),
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            presenting: item.wrappedValue
        ) { workspace in
            Button(role: .destructive) {
                onConfirm(workspace)
            } label: {
                Text(L10nKey.commonDelete)
            }
            .accessibilityIdentifier("workspace.confirmDelete")
            Button(role: .cancel) {} label: { Text(L10nKey.commonCancel) }
        } message: { _ in
            Text(L10nKey.workspaceDeleteMessage)
        }
    }
}
