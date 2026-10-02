import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

public struct CommandCenterView: View {
    @State private var model: CommandCenterModel
    @State private var isCreatingWorkspace = false
    @Environment(AppRouter.self) private var router

    public init(model: CommandCenterModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            if model.isSearching {
                searchResults
            } else {
                dashboard
            }
        }
        .navigationTitle(Text(L10nKey.tabCommandCenter))
        .searchable(text: $model.query, prompt: Text(L10nKey.commandCenterSearchPrompt))
        .task(id: model.query) {
            // Light debounce while typing.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await model.search()
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: $isCreatingWorkspace) {
            WorkspaceEditor(mode: .create) { draft in
                guard let workspace = await model.createWorkspace(draft) else { return false }
                router.push(.workspace(workspace.id))
                return true
            }
        }
        .errorAlert(message: $model.errorMessage)
    }

    // MARK: Dashboard

    @ViewBuilder
    private var dashboard: some View {
        Section {
            QuickCaptureBar(text: $model.draft, isSaving: model.isSaving) {
                Task { await model.captureDraft() }
            }
        } header: {
            Text(L10nKey.commandCenterQuickCapture)
        } footer: {
            captureFooter
        }

        Section {
            AdaptiveStack {
                Button { isCreatingWorkspace = true } label: {
                    QuickActionTile(.workspacesCreate, systemImage: "plus.square.on.square")
                }
                .accessibilityIdentifier("commandCenter.newWorkspace")
                Button { router.push(.lens) } label: {
                    QuickActionTile(.lensTitle, systemImage: "viewfinder", tint: .purple)
                }
                .accessibilityIdentifier("commandCenter.lens")
                Button { router.push(.clipboard) } label: {
                    QuickActionTile(.clipboardTitle, systemImage: "doc.on.clipboard", tint: .orange)
                }
                .accessibilityIdentifier("commandCenter.clipboard")
            }
            .buttonStyle(.borderless)
            .listRowInsets(EdgeInsets(top: TLSpacing.s, leading: TLSpacing.s, bottom: TLSpacing.s, trailing: TLSpacing.s))
            .listRowBackground(Color.clear)
        } header: {
            Text(L10nKey.commandCenterQuickActions)
        }

        Section {
            if model.featuredWorkspaces.isEmpty {
                Text(L10nKey.commandCenterNoWorkspaces)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: TLSpacing.s) {
                        ForEach(model.featuredWorkspaces) { workspace in
                            Button { router.push(.workspace(workspace.id)) } label: {
                                WorkspaceCard(workspace: workspace)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("commandCenter.workspace.\(workspace.name)")
                        }
                    }
                    .padding(.horizontal, TLSpacing.l)
                }
                .listRowInsets(EdgeInsets(top: TLSpacing.s, leading: 0, bottom: TLSpacing.s, trailing: 0))
                .listRowBackground(Color.clear)
            }
        } header: {
            HStack {
                Text(L10nKey.tabWorkspaces)
                Spacer()
                if !model.workspaces.isEmpty {
                    Button {
                        router.selectedTab = .workspaces
                    } label: {
                        Text(L10nKey.commandCenterSeeAll)
                    }
                    .font(.footnote)
                    .textCase(nil)
                }
            }
        }

        if !model.activeSessions.isEmpty {
            Section {
                ForEach(model.activeSessions) { session in
                    NavigationLink(value: AppRoute.session(session.id)) {
                        SessionRow(session: session, workspaceName: model.workspaceName(for: session.workspaceID))
                    }
                }
            } header: {
                Text(L10nKey.commandCenterActiveSessions)
            }
        }

        if !model.recentSessions.isEmpty {
            Section {
                ForEach(model.recentSessions) { session in
                    NavigationLink(value: AppRoute.session(session.id)) {
                        SessionRow(session: session, workspaceName: model.workspaceName(for: session.workspaceID))
                    }
                }
            } header: {
                Text(L10nKey.commandCenterRecentSessions)
            }
        }

        if !model.recentItems.isEmpty {
            Section {
                ForEach(model.recentItems) { item in
                    ContextItemRow(item: item)
                }
            } header: {
                Text(L10nKey.commandCenterRecentItems)
            }
        }
    }

    @ViewBuilder
    private var captureFooter: some View {
        if let target = model.captureTarget {
            HStack(spacing: TLSpacing.xs) {
                Image(systemName: "arrow.turn.down.right")
                    .accessibilityHidden(true)
                if let title = target.title {
                    Text(title)
                } else {
                    Text(L10nKey.sessionUntitled)
                }
            }
        } else {
            Text(L10nKey.commandCenterSavesTo)
        }
    }

    // MARK: Search

    @ViewBuilder
    private var searchResults: some View {
        let results = model.searchResults
        if results.isEmpty {
            ContentUnavailableView.search(text: model.query)
                .listRowBackground(Color.clear)
        } else {
            if !results.workspaces.isEmpty {
                Section {
                    ForEach(results.workspaces) { workspace in
                        NavigationLink(value: AppRoute.workspace(workspace.id)) {
                            WorkspaceRow(workspace: workspace)
                        }
                    }
                } header: {
                    Text(L10nKey.tabWorkspaces)
                }
            }
            if !results.sessions.isEmpty {
                Section {
                    ForEach(results.sessions) { session in
                        NavigationLink(value: AppRoute.session(session.id)) {
                            SessionRow(session: session, workspaceName: model.workspaceName(for: session.workspaceID))
                        }
                    }
                } header: {
                    Text(L10nKey.workspaceSessions)
                }
            }
            if !results.items.isEmpty {
                Section {
                    ForEach(results.items) { item in
                        ContextItemRow(item: item)
                    }
                } header: {
                    Text(L10nKey.sessionItems)
                }
            }
        }
    }
}
