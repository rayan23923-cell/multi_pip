import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

public struct CommandCenterView: View {
    @State private var model: CommandCenterModel
    @State private var isCreatingWorkspace = false
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        .onChange(of: router.pendingSearch, initial: true) { _, query in
            guard let query else { return }
            router.pendingSearch = nil
            model.query = query
        }
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

    private var quickActionColumns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 220 : 96), spacing: TLSpacing.s)]
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
            LazyVGrid(columns: quickActionColumns, spacing: TLSpacing.s) {
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
                Button { router.push(.notes(nil)) } label: {
                    QuickActionTile(.workspaceToolNotes, systemImage: WorkspaceTool.notes.symbolName, tint: .yellow)
                }
                .accessibilityIdentifier("commandCenter.notes")
                Button { router.push(.calculator(nil)) } label: {
                    QuickActionTile(.workspaceToolCalculator, systemImage: WorkspaceTool.calculator.symbolName, tint: .gray)
                }
                .accessibilityIdentifier("commandCenter.calculator")
                Button { router.push(.browser(nil)) } label: {
                    QuickActionTile(.workspaceToolBrowser, systemImage: WorkspaceTool.browser.symbolName, tint: .blue)
                }
                .accessibilityIdentifier("commandCenter.browser")
                Button { router.push(.documents(nil)) } label: {
                    QuickActionTile(.workspaceToolDocuments, systemImage: WorkspaceTool.documents.symbolName, tint: .teal)
                }
                .accessibilityIdentifier("commandCenter.documents")
                Button { router.push(.pip) } label: {
                    QuickActionTile(.pipTitle, systemImage: "pip", tint: .indigo)
                }
                .accessibilityIdentifier("commandCenter.pip")
                Button { router.push(.workflows) } label: {
                    QuickActionTile(.workflowsTitle, systemImage: "arrow.triangle.branch", tint: .pink)
                }
                .accessibilityIdentifier("commandCenter.workflows")
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
                    .swipeActions(edge: .leading) {
                        Button { router.resume(session) } label: {
                            TLLabel(.sessionResume, systemImage: "play")
                        }
                        .tint(.green)
                    }
                    .contextMenu {
                        Button { router.resume(session) } label: {
                            TLLabel(.sessionResume, systemImage: "play")
                        }
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
        let response = model.searchResults
        if response.query.hasHints {
            Section {
                SearchHintsRow(query: response.query)
            }
        }
        if response.hits.isEmpty {
            ContentUnavailableView.search(text: model.query)
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(response.hits) { hit in
                    NavigationLink(value: Self.route(for: hit.document)) {
                        SearchHitRow(hit: hit)
                    }
                    .accessibilityIdentifier("search.hit")
                }
            } footer: {
                Text(response.usedMeaning ? L10nKey.searchOnDeviceMeaning : L10nKey.searchOnDevice)
            }
        }
    }

    /// Where a result opens.
    static func route(for document: SearchDocument) -> AppRoute {
        switch document.kind {
        case .workspace:
            return .workspace(WorkspaceID(document.targetID))
        case .session:
            return .session(SessionID(document.targetID))
        case .note:
            return .note(NoteID(document.targetID))
        case .document:
            switch document.fileKind {
            case .some(.image): return .image(DocumentID(document.targetID))
            case .some(.text): return .textDocument(DocumentID(document.targetID))
            case .some(.powerpoint): return .powerPoint(DocumentID(document.targetID))
            default: return .pdf(DocumentID(document.targetID))
            }
        case .clipboard:
            if let url = document.url { return .browserPage(url) }
            return .clipboard
        case .item:
            if let sessionID = document.sessionID { return .session(sessionID) }
            if let url = document.url { return .browserPage(url) }
            return .lensInput(document.body)
        }
    }
}

/// One result: what it is, its title, the matching text, and how it matched.
struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .top, spacing: TLSpacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: hit.document.title.isEmpty ? hit.snippet : hit.document.title)
                    .font(.body)
                    .lineLimit(2)
                if !hit.snippet.isEmpty && !hit.document.title.isEmpty {
                    Text(verbatim: hit.snippet)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: TLSpacing.xs) {
                    Text(Self.kindKey(hit.document.kind))
                    Text(verbatim: "·")
                        .accessibilityHidden(true)
                    Text(hit.document.date, style: .date)
                    if hit.match == .meaning {
                        Text(verbatim: "·")
                            .accessibilityHidden(true)
                        Text(L10nKey.searchMeaning)
                            .accessibilityIdentifier("search.meaning")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch hit.document.kind {
        case .workspace: "square.stack"
        case .session: "clock"
        case .note: "note.text"
        case .document: hit.document.fileKind == .image ? "photo" : "doc.richtext"
        case .clipboard: "doc.on.clipboard"
        case .item: hit.document.url != nil ? "link" : hit.document.fileKind == .image ? "photo" : "text.alignleft"
        }
    }

    static func kindKey(_ kind: SearchResultKind) -> L10nKey {
        L10nKey(rawValue: "search.kind.\(kind.rawValue)") ?? .searchKindItem
    }
}

/// "Looking for: Prices · Yesterday · Study", read from the query.
struct SearchHintsRow: View {
    let query: ParsedSearchQuery

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: TLSpacing.xs) { content }
            VStack(alignment: .leading, spacing: TLSpacing.xs) { content }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.hints")
    }

    @ViewBuilder
    private var content: some View {
        Text(L10nKey.searchLookingFor)
            .foregroundStyle(.secondary)
        ForEach(SearchFilter.allCases.filter { query.filters.contains($0) && !($0 == .document && query.filters.contains(.pdf)) }, id: \.self) { filter in
            chip(Text(L10nKey(rawValue: "search.filter.\(filter.rawValue)") ?? .searchFilterText))
        }
        if let range = query.dateRange {
            chip(Text(range.start, format: .dateTime.day().month()))
        }
        if let kind = query.kindHint {
            chip(Text(L10nKey(rawValue: "workspace.kind.\(kind)") ?? .workspaceKindCustom))
        }
    }

    private func chip(_ text: Text) -> some View {
        text
            .padding(.horizontal, TLSpacing.s)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
    }
}
