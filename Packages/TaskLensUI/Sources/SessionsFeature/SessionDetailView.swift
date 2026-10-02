import SwiftUI
import TLActionsUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

public struct SessionDetailView: View {
    @State private var model: SessionDetailModel
    @State private var selectedItem: ContextItem?
    @State private var isRenaming = false
    @State private var newTitle = ""
    @State private var isConfirmingDelete = false
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    public init(model: SessionDetailModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            if let session = model.session {
                Section {
                    header(for: session)
                    if session.isActive == false {
                        Button {
                            Task { await model.resume() }
                        } label: {
                            TLLabel(.sessionResume, systemImage: "play.circle.fill")
                        }
                        .accessibilityIdentifier("session.resume")
                    }
                }
            }
            if let resumption = model.resumption {
                pickUpSection(resumption)
            }
            if !model.items.isEmpty {
                Section {
                    Picker(selection: $model.sort) {
                        ForEach(SessionSort.allCases, id: \.self) { sort in
                            Text(L10nKey.sessionSortOption(sort)).tag(sort)
                        }
                    } label: {
                        Text(L10nKey.sessionSort)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("session.sort")
                }
            }
            itemSections
            if !model.recentActions.isEmpty {
                Section {
                    ForEach(model.recentActions) { record in
                        ActionRecordRow(record: record)
                    }
                } header: {
                    Text(L10nKey.sessionActionHistory)
                }
            }
        }
        .overlay {
            if model.hasLoaded && model.items.isEmpty {
                TLEmptyState(title: .sessionNoItemsTitle, message: .sessionNoItemsMessage, symbolName: "tray")
            } else if model.hasLoaded && model.visibleItems.isEmpty && !model.query.isEmpty {
                ContentUnavailableView.search(text: model.query)
            }
        }
        .searchable(text: $model.query, prompt: Text(L10nKey.sessionSearchPrompt))
        .safeAreaInset(edge: .bottom) {
            if model.canCapture {
                QuickCaptureBar(text: $model.draft, isSaving: model.isSaving) {
                    Task { await model.captureDraft() }
                }
                .padding(.horizontal, TLSpacing.l)
                .padding(.vertical, TLSpacing.s)
                .background(.bar)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { menu }
        }
        .sheet(item: $selectedItem) { item in
            SessionItemDetail(item: item, model: model) { route in
                selectedItem = nil
                router.push(route)
            }
        }
        .alert(Text(L10nKey.sessionRename), isPresented: $isRenaming) {
            TextField(L10n.string(.sessionName), text: $newTitle)
                .accessibilityIdentifier("session.renameField")
            Button { Task { await model.rename(to: newTitle) } } label: { Text(L10nKey.commonSave) }
            Button(role: .cancel) {} label: { Text(L10nKey.commonCancel) }
        }
        .alert(Text(L10nKey.sessionDelete), isPresented: $isConfirmingDelete) {
            Button(role: .destructive) { Task { await model.delete() } } label: { Text(L10nKey.commonDelete) }
            Button(role: .cancel) {} label: { Text(L10nKey.commonCancel) }
        } message: {
            Text(L10nKey.sessionDeleteMessage)
        }
        .onChange(of: model.isDeleted) { _, deleted in
            if deleted { dismiss() }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }

    // MARK: Items

    @ViewBuilder
    private var itemSections: some View {
        if model.sort == .type {
            ForEach(model.groups, id: \.kind) { group in
                Section {
                    ForEach(group.items) { row($0) }
                } header: {
                    Text(L10nKey.sessionItemKind(group.kind))
                        .accessibilityIdentifier("session.group.\(group.kind.rawValue)")
                }
            }
        } else if !model.visibleItems.isEmpty {
            Section {
                ForEach(model.visibleItems) { row($0) }
            } header: {
                Text(L10nKey.sessionItems)
            }
        }
    }

    private func row(_ item: ContextItem) -> some View {
        let important = model.isImportant(item)
        return Button {
            selectedItem = item
        } label: {
            HStack(alignment: .top) {
                ContextItemRow(item: item)
                if important {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel(Text(L10nKey.sessionImportant))
                }
            }
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("sessionItem")
        .swipeActions(edge: .leading) {
            Button { Task { await model.toggleImportant(item) } } label: {
                if important {
                    TLLabel(.sessionUnmarkImportant, systemImage: "star.slash")
                } else {
                    TLLabel(.sessionMarkImportant, systemImage: "star")
                }
            }
            .tint(.yellow)
        }
        .contextMenu {
            Button { Task { await model.toggleImportant(item) } } label: {
                if important {
                    TLLabel(.sessionUnmarkImportant, systemImage: "star.slash")
                } else {
                    TLLabel(.sessionMarkImportant, systemImage: "star")
                }
            }
        }
    }

    // MARK: Resume

    private func pickUpSection(_ resumption: SessionContentService.Resumption) -> some View {
        Section {
            if let state = resumption.resumeState,
               let route = AppRoute.resuming(state, workspaceID: resumption.workspace.id) {
                Button {
                    router.push(route)
                } label: {
                    resumeLabel(state)
                }
                .accessibilityIdentifier("session.resumeTool")
            }
            ForEach(resumption.recentContext) { item in
                Button { selectedItem = item } label: { ContextItemRow(item: item) }
                    .foregroundStyle(.primary)
            }
        } header: {
            Text(L10nKey.sessionPickUp)
        } footer: {
            Text(L10nKey.sessionPickUpNote)
        }
        .accessibilityIdentifier("session.pickUp")
    }

    @ViewBuilder
    private func resumeLabel(_ state: SessionResumeState) -> some View {
        switch state.tool {
        case .browser:
            Label {
                VStack(alignment: .leading) {
                    Text(L10nKey.sessionResumePage)
                    if let host = state.url?.host() {
                        Text(verbatim: host).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "safari")
            }
        case .documents:
            Label {
                Text(verbatim: L10n.format(.sessionResumeDocument, (state.page ?? 0) + 1))
            } icon: {
                Image(systemName: "doc.richtext")
            }
        case .notes:
            TLLabel(.sessionResumeNote, systemImage: "note.text")
        default:
            TLLabel(.sessionResumeTool, systemImage: "arrow.uturn.forward")
        }
    }

    // MARK: Header and menu

    private var title: Text {
        if let title = model.session?.title {
            Text(title)
        } else {
            Text(L10nKey.sessionUntitled)
        }
    }

    private func header(for session: Session) -> some View {
        VStack(alignment: .leading, spacing: TLSpacing.s) {
            HStack {
                TLLabel(L10nKey.sessionKind(session.kind), systemImage: session.kind.symbolName)
                    .font(.headline)
                if session.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel(Text(L10nKey.sessionFavorites))
                }
                Spacer()
                if session.isArchived {
                    StatusBadge(.sessionStateArchived, tint: .secondary)
                } else {
                    StatusBadge(L10nKey.sessionState(session.state), tint: session.state.tint)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("session.header")
            HStack(spacing: TLSpacing.xs) {
                Text(L10nKey.sessionStartedAt)
                Text(session.startedAt, format: .dateTime.day().month().hour().minute())
                Text(verbatim: "·")
                Text(L10nKey.sessionLastActivity)
                Text(session.lastActivityAt, format: .relative(presentation: .named))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if !model.counts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TLSpacing.s) {
                        ForEach(SessionItemKind.allCases.filter { model.counts[$0] != nil }, id: \.self) { kind in
                            HStack(spacing: TLSpacing.xxs) {
                                Text(L10nKey.sessionItemKind(kind))
                                Text(model.counts[kind] ?? 0, format: .number)
                                    .fontWeight(.semibold)
                            }
                            .font(.caption)
                            .padding(.horizontal, TLSpacing.s)
                            .padding(.vertical, TLSpacing.xxs)
                            .background(.fill.tertiary, in: Capsule())
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .accessibilityIdentifier("session.counts")
            }
        }
        .padding(.vertical, TLSpacing.xs)
    }

    private var menu: some View {
        Menu {
            if let session = model.session {
                Button {
                    newTitle = session.title ?? ""
                    isRenaming = true
                } label: {
                    TLLabel(.sessionRename, systemImage: "pencil")
                }
                .accessibilityIdentifier("session.rename")
                Button { Task { await model.toggleFavorite() } } label: {
                    if session.isFavorite {
                        TLLabel(.sessionUnfavorite, systemImage: "star.slash")
                    } else {
                        TLLabel(.sessionFavorite, systemImage: "star")
                    }
                }
                .accessibilityIdentifier("session.favorite")
                if session.isActive {
                    Button { Task { await model.pause() } } label: {
                        TLLabel(.sessionPause, systemImage: "pause")
                    }
                } else {
                    Button { Task { await model.resume() } } label: {
                        TLLabel(.sessionResume, systemImage: "play")
                    }
                }
                if session.isActive {
                    Menu {
                        ForEach(SessionService.focusDurations, id: \.self) { minutes in
                            Button { Task { await model.setFocus(minutes: minutes) } } label: {
                                Text(verbatim: L10n.format(.sessionFocusMinutes, minutes))
                            }
                            .accessibilityIdentifier("session.focus.\(minutes)")
                        }
                        if model.isFocusing() {
                            Button(role: .destructive) { Task { await model.setFocus(minutes: nil) } } label: {
                                TLLabel(.sessionFocusStop, systemImage: "timer")
                            }
                            .accessibilityIdentifier("session.focus.stop")
                        }
                    } label: {
                        TLLabel(.sessionFocus, systemImage: "timer")
                    }
                    .accessibilityIdentifier("session.focus")
                }
                if !session.isEnded {
                    Button { Task { await model.end() } } label: {
                        TLLabel(.sessionEnd, systemImage: "stop")
                    }
                }
                if session.isArchived {
                    Button { Task { await model.unarchive() } } label: {
                        TLLabel(.sessionUnarchive, systemImage: "archivebox")
                    }
                } else {
                    Button { Task { await model.archive() } } label: {
                        TLLabel(.sessionArchive, systemImage: "archivebox")
                    }
                    .accessibilityIdentifier("session.archive")
                }
                Divider()
                Button(role: .destructive) { isConfirmingDelete = true } label: {
                    TLLabel(.sessionDelete, systemImage: "trash")
                }
                .accessibilityIdentifier("session.delete")
            }
        } label: {
            TLLabel(.commonMore, systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("session.menu")
    }
}

/// One entry of the action history: what was done, on what, and when.
private struct ActionRecordRow: View {
    let record: ActionRecord

    var body: some View {
        HStack(alignment: .top, spacing: TLSpacing.m) {
            Image(systemName: record.actionType.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                if let key = L10nKey.action(Action(type: record.actionType)) {
                    Text(key)
                } else {
                    Text(verbatim: record.actionType.rawValue)
                }
                if let detail = record.detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: TLSpacing.xxs) {
                Text(L10nKey.actionOutcome(record.outcome))
                    .font(.caption)
                Text(record.performedAt, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("actionRecord.\(record.actionType.rawValue)")
    }
}

/// An item of the session with its analysis and actions. Actions run here
/// are added to the session's history.
private struct SessionItemDetail: View {
    let item: ContextItem
    let model: SessionDetailModel
    let navigate: (AppRoute) -> Void
    @State private var feedback = ActionFeedback()
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router

    var body: some View {
        let analysis = ActionEngine.analyze(item.content, itemID: item.id, context: ActionContext(source: item.source))
        let current = model.items.first { $0.id == item.id } ?? item
        NavigationStack {
            List {
                Section {
                    DetectedTypeRow(analysis.category)
                    DetectedValueRow(analysis)
                    Button { Task { await model.toggleImportant(current) } } label: {
                        if model.isImportant(current) {
                            TLLabel(.sessionUnmarkImportant, systemImage: "star.slash")
                        } else {
                            TLLabel(.sessionMarkImportant, systemImage: "star")
                        }
                    }
                    .accessibilityIdentifier("sessionItem.important")
                } footer: {
                    ContentPreview(item.content, lineLimit: 12)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.top, TLSpacing.s)
                }

                ActionCard(
                    analysis: analysis,
                    content: item.content,
                    feedback: feedback,
                    isSaved: true,
                    hiding: [.saveToSession],
                    handlers: ActionHandlers(
                        onCalculate: { navigate(.calculatorInput($0)) },
                        onCreateNote: { navigate(.noteDraft($0)) },
                        onSearch: { query in
                            dismiss()
                            router.search(query)
                        },
                        onPerformed: { action, plan in
                            Task { await model.record(action.type, outcome: Self.outcome(of: plan), detail: action.valueText, itemID: item.id) }
                        }
                    )
                )

                EntitiesSection(analysis.entities)
            }
            .navigationTitle(Text(L10nKey.commonDetails))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(L10nKey.commonDone) }
                        .accessibilityIdentifier("sessionItem.done")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                        router.keepInPiP(.item(current))
                    } label: {
                        TLLabel(.pipKeep, systemImage: "pip.enter")
                    }
                    .accessibilityIdentifier("sessionItem.keepInPiP")
                }
            }
            .actionFeedback(feedback)
        }
        .presentationDetents([.medium, .large])
    }

    /// Opening something outside TaskLens is a hand-off; the rest completes here.
    static func outcome(of plan: ActionPlan) -> ActionRecord.Outcome {
        switch plan {
        case .open, .createEvent, .translate: .handedOff
        default: .completed
        }
    }
}
