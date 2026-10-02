import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization

public struct ClipboardView: View {
    @State private var model: ClipboardModel
    @State private var isConfirmingClear = false

    public init(model: ClipboardModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            Section {
                PasteButton(payloadType: String.self) { [model] strings in
                    Task { @MainActor in await model.paste(strings) }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            } footer: {
                Text(L10nKey.clipboardSubtitle)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }

            if model.hasLoaded && model.history.isEmpty {
                Section {
                    TLEmptyState(
                        title: .clipboardEmptyTitle,
                        message: .clipboardEmptyMessage,
                        symbolName: "doc.on.clipboard"
                    )
                }
                .listRowBackground(Color.clear)
            } else if !model.history.isEmpty {
                Section {
                    ForEach(model.history) { item in
                        row(item)
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await model.delete(item) }
                                } label: {
                                    TLLabel(.commonDelete, systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(L10nKey.clipboardHistory)
                } footer: {
                    Text(L10nKey.commandCenterSavesTo)
                }
            }
        }
        .navigationTitle(Text(L10nKey.clipboardTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.history.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) { isConfirmingClear = true } label: {
                        Text(L10nKey.clipboardClear)
                    }
                }
            }
        }
        .alert(Text(L10nKey.clipboardClear), isPresented: $isConfirmingClear) {
            Button(role: .destructive) {
                Task { await model.clear() }
            } label: {
                Text(L10nKey.commonDelete)
            }
            Button(role: .cancel) {} label: { Text(L10nKey.commonCancel) }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .errorAlert(message: $model.errorMessage)
    }

    private func row(_ item: ClipboardItem) -> some View {
        HStack(alignment: .top, spacing: TLSpacing.m) {
            Image(systemName: item.content.itemType.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                preview(item.content)
                    .lineLimit(3)
                Text(item.capturedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: TLSpacing.s)
            if item.promotedItemID != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text(L10nKey.clipboardSaved))
            } else {
                Button {
                    Task { await model.save(item) }
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .accessibilityLabel(Text(L10nKey.actionSaveToSession))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func preview(_ content: ContextContent) -> some View {
        switch content {
        case .text(let text):
            Text(text)
        case .url(let url):
            Text(url.absoluteString)
                .foregroundStyle(.tint)
                .environment(\.layoutDirection, .leftToRight)
        case .file(let reference):
            Text(reference.originalFilename ?? reference.relativePath)
        }
    }
}
