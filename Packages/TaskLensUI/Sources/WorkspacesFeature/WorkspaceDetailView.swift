import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

public struct WorkspaceDetailView: View {
    @State private var model: WorkspaceDetailModel
    @State private var isEditing = false
    @State private var pendingDeletion: Workspace?
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    public init(model: WorkspaceDetailModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            if let workspace = model.workspace {
                Section {
                    header(workspace)
                }
                Section {
                    toolsGrid(workspace)
                } header: {
                    Text(L10nKey.workspaceTools)
                }
            }

            Section {
                if model.hasLoaded && model.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: TLSpacing.xs) {
                        Text(L10nKey.workspaceNoSessionsTitle).font(.headline)
                        Text(L10nKey.workspaceNoSessionsMessage).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, TLSpacing.xs)
                }
                ForEach(model.currentSessions) { session in
                    sessionLink(session)
                }
                Button {
                    Task {
                        if let session = await model.startSession() {
                            router.push(.session(session.id))
                        }
                    }
                } label: {
                    TLLabel(.workspaceStartSession, systemImage: "plus.circle")
                }
                // Long press: start a session of another kind.
                .contextMenu {
                    ForEach(SessionKind.allKnown, id: \.self) { kind in
                        Button {
                            Task {
                                if let session = await model.startSession(kind: kind) {
                                    router.push(.session(session.id))
                                }
                            }
                        } label: {
                            TLLabel(L10nKey.sessionKind(kind), systemImage: kind.symbolName)
                        }
                        .accessibilityIdentifier("workspaceDetail.startSession.\(kind.rawValue)")
                    }
                }
                .accessibilityIdentifier("workspaceDetail.startSession")
            } header: {
                Text(L10nKey.workspaceSessions)
            }

            if !model.archivedSessions.isEmpty {
                Section {
                    ForEach(model.archivedSessions) { session in
                        sessionLink(session)
                    }
                } header: {
                    Text(L10nKey.sessionArchived)
                }
                .accessibilityIdentifier("workspaceDetail.archived")
            }
        }
        .navigationTitle(model.workspace?.name ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { isEditing = true } label: { TLLabel(.commonEdit, systemImage: "pencil") }
                        .accessibilityIdentifier("workspaceDetail.edit")
                    Button { Task { await model.toggleFavorite() } } label: {
                        if model.workspace?.isFavorite == true {
                            TLLabel(.commonUnfavorite, systemImage: "star.slash")
                        } else {
                            TLLabel(.commonFavorite, systemImage: "star")
                        }
                    }
                    .accessibilityIdentifier("workspaceDetail.favorite")
                    Button {
                        Task {
                            if let copy = await model.duplicate() {
                                router.push(.workspace(copy.id))
                            }
                        }
                    } label: {
                        TLLabel(.commonDuplicate, systemImage: "plus.square.on.square")
                    }
                    .accessibilityIdentifier("workspaceDetail.duplicate")
                    Divider()
                    Button(role: .destructive) { pendingDeletion = model.workspace } label: {
                        TLLabel(.commonDelete, systemImage: "trash")
                    }
                    .accessibilityIdentifier("workspaceDetail.delete")
                } label: {
                    TLLabel(.commonMore, systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("workspaceDetail.menu")
            }
        }
        .sheet(isPresented: $isEditing) {
            if let workspace = model.workspace {
                WorkspaceEditor(mode: .edit, draft: WorkspaceDraft(workspace)) { draft in
                    await model.update(with: draft)
                }
            }
        }
        .workspaceDeletionAlert(item: $pendingDeletion) { _ in
            Task { await model.delete() }
        }
        .onChange(of: model.isDeleted) { _, isDeleted in
            if isDeleted { dismiss() }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }

    private func sessionLink(_ session: Session) -> some View {
        NavigationLink(value: AppRoute.session(session.id)) {
            SessionRow(session: session)
        }
        .accessibilityIdentifier("sessionRow")
        .swipeActions(edge: .leading) {
            Button { Task { await model.toggleFavorite(session) } } label: {
                if session.isFavorite {
                    TLLabel(.sessionUnfavorite, systemImage: "star.slash")
                } else {
                    TLLabel(.sessionFavorite, systemImage: "star")
                }
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            if session.isArchived {
                Button { Task { await model.unarchive(session) } } label: {
                    TLLabel(.sessionUnarchive, systemImage: "archivebox")
                }
            } else {
                Button { Task { await model.archive(session) } } label: {
                    TLLabel(.sessionArchive, systemImage: "archivebox")
                }
                .tint(.indigo)
            }
        }
        .contextMenu {
            Button { router.resume(session) } label: {
                TLLabel(.sessionResume, systemImage: "play")
            }
            Button { Task { await model.toggleFavorite(session) } } label: {
                if session.isFavorite {
                    TLLabel(.sessionUnfavorite, systemImage: "star.slash")
                } else {
                    TLLabel(.sessionFavorite, systemImage: "star")
                }
            }
        }
    }

    private func header(_ workspace: Workspace) -> some View {
        HStack(spacing: TLSpacing.m) {
            WorkspaceIcon(workspace: workspace, size: 48)
            VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                HStack(spacing: TLSpacing.xs) {
                    Text(L10nKey.workspaceKind(workspace.kind))
                        .font(.headline)
                    if workspace.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .accessibilityLabel(Text(L10nKey.workspacesFavorites))
                    }
                }
                HStack(spacing: TLSpacing.xs) {
                    Text(L10nKey.workspaceLastOpened)
                    if let opened = workspace.lastOpenedAt {
                        Text(opened, format: .dateTime.day().month().hour().minute())
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, TLSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func toolsGrid(_ workspace: Workspace) -> some View {
        if workspace.tools.isEmpty {
            Text(L10nKey.workspaceToolUpcoming).foregroundStyle(.secondary)
        } else {
            ForEach(workspace.tools, id: \.self) { tool in
                if let route = AppRoute.tool(tool, workspaceID: workspace.id) {
                    NavigationLink(value: route) {
                        TLLabel(L10nKey.workspaceTool(tool), systemImage: tool.symbolName)
                    }
                } else {
                    HStack {
                        TLLabel(L10nKey.workspaceTool(tool), systemImage: tool.symbolName)
                        Spacer()
                        Text(L10nKey.workspaceToolUpcoming)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

}
