import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

public struct CommandCenterView: View {
    @State private var model: CommandCenterModel

    public init(model: CommandCenterModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            Section {
                QuickCaptureBar(text: $model.draft, isSaving: model.isSaving) {
                    Task { await model.captureDraft() }
                }
            } header: {
                Text(L10nKey.commandCenterQuickCapture)
            } footer: {
                captureFooter
            }

            if !model.activeSessions.isEmpty {
                Section {
                    ForEach(model.activeSessions) { session in
                        NavigationLink(value: AppRoute.session(session.id)) {
                            SessionRow(session: session, workspaceName: model.workspaceNames[session.workspaceID])
                        }
                    }
                } header: {
                    Text(L10nKey.commandCenterActiveSessions)
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
            } else if model.hasLoaded && model.activeSessions.isEmpty {
                Section {
                    TLEmptyState(
                        title: .commandCenterEmptyTitle,
                        message: .commandCenterEmptyMessage,
                        symbolName: "sparkle.magnifyingglass"
                    )
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(Text(L10nKey.tabCommandCenter))
        .task { await model.load() }
        .refreshable { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }

    @ViewBuilder
    private var captureFooter: some View {
        if let target = model.captureTarget {
            HStack(spacing: TLSpacing.xs) {
                Image(systemName: "arrow.turn.down.right")
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
}
