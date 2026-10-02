import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization

public struct SessionDetailView: View {
    @State private var model: SessionDetailModel

    public init(model: SessionDetailModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            if let session = model.session {
                Section {
                    header(for: session)
                }
            }
            Section {
                ForEach(model.items) { item in
                    ContextItemRow(item: item)
                }
            } header: {
                Text(L10nKey.sessionItems)
            }
        }
        .overlay {
            if model.hasLoaded && model.items.isEmpty {
                TLEmptyState(
                    title: .sessionNoItemsTitle,
                    message: .sessionNoItemsMessage,
                    symbolName: "tray"
                )
            }
        }
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
            if let session = model.session, !session.isEnded {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if session.isActive {
                            Button { Task { await model.pause() } } label: {
                                TLLabel(.sessionPause, systemImage: "pause")
                            }
                        } else {
                            Button { Task { await model.resume() } } label: {
                                TLLabel(.sessionResume, systemImage: "play")
                            }
                        }
                        Button(role: .destructive) { Task { await model.end() } } label: {
                            TLLabel(.sessionEnd, systemImage: "stop")
                        }
                    } label: {
                        TLLabel(.commonMore, systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }

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
                Spacer()
                StatusBadge(L10nKey.sessionState(session.state), tint: session.state.tint)
            }
            HStack(spacing: TLSpacing.xs) {
                Text(L10nKey.sessionStartedAt)
                Text(session.startedAt, format: .dateTime.day().month().hour().minute())
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, TLSpacing.xs)
    }
}
