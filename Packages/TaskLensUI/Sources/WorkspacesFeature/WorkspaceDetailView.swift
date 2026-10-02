import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

public struct WorkspaceDetailView: View {
    @State private var model: WorkspaceDetailModel
    @Environment(AppRouter.self) private var router

    public init(model: WorkspaceDetailModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            Section {
                ForEach(model.sessions) { session in
                    NavigationLink(value: AppRoute.session(session.id)) {
                        SessionRow(session: session)
                    }
                }
            } header: {
                Text(L10nKey.workspaceSessions)
            }
        }
        .overlay {
            if model.hasLoaded && model.sessions.isEmpty {
                TLEmptyState(
                    title: .workspaceNoSessionsTitle,
                    message: .workspaceNoSessionsMessage,
                    symbolName: "square.stack"
                )
            }
        }
        .navigationTitle(model.workspace?.name ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
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
                    }
                } label: {
                    TLLabel(.workspaceStartSession, systemImage: "plus")
                }
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }
}
