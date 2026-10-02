import Combine
import SwiftUI
import TLActionsUI
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation
import UIKit

public struct ClipboardView: View {
    @State private var model: ClipboardModel
    @State private var isConfirmingClear = false
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    public init(model: ClipboardModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            Section {
                if model.hasNewContent {
                    Label {
                        Text(L10nKey.clipboardNewContent)
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.tint)
                    }
                    .accessibilityIdentifier("clipboard.newContent")
                }
                PasteButton(payloadType: String.self) { [model] strings in
                    Task { @MainActor in await model.paste(strings) }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("clipboard.paste")
            } footer: {
                Text(L10nKey.clipboardPrivacyNote)
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
        .sheet(item: Binding(
            get: { model.selectedItem },
            set: { model.selectedItemID = $0?.id }
        )) { item in
            ClipboardItemDetail(item: item, model: model) { route in
                model.selectedItemID = nil
                router.push(route)
            }
        }
        .task {
            await model.load()
            model.refreshPasteboardHint()
        }
        .refreshable { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshPasteboardHint() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            model.refreshPasteboardHint()
        }
        .errorAlert(message: $model.errorMessage)
    }

    private func row(_ item: ClipboardItem) -> some View {
        let category = model.analysis(for: item).category
        return HStack(alignment: .top, spacing: TLSpacing.m) {
            Button {
                model.selectedItemID = item.id
            } label: {
                HStack(alignment: .top, spacing: TLSpacing.m) {
                    Image(systemName: category.symbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                        ContentPreview(item.content, lineLimit: 3)
                            .foregroundStyle(.primary)
                        HStack(spacing: TLSpacing.xs) {
                            Text(L10nKey.category(category))
                            Text(verbatim: "·")
                                .accessibilityHidden(true)
                            Text(item.capturedAt, format: .relative(presentation: .named))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("clipboardRow.\(category.rawValue)")

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
}

/// Detected type, preview, entities and suggested actions for one entry.
private struct ClipboardItemDetail: View {
    let item: ClipboardItem
    let model: ClipboardModel
    /// Leaves the detail sheet for another screen.
    let navigate: (AppRoute) -> Void
    @Environment(AppRouter.self) private var router
    @State private var feedback = ActionFeedback()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let analysis = model.analysis(for: item)
        NavigationStack {
            List {
                Section {
                    DetectedTypeRow(analysis.category)
                    DetectedValueRow(analysis)
                } header: {
                    Text(L10nKey.lensPreview)
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
                    isSaved: model.history.first(where: { $0.id == item.id })?.promotedItemID != nil,
                    handlers: ActionHandlers(
                        onSave: { await model.save(item) },
                        onCalculate: { navigate(.calculatorInput($0)) },
                        onCreateNote: { navigate(.noteDraft($0)) },
                        onSearch: { query in
                            dismiss()
                            router.search(query)
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
                        .accessibilityIdentifier("clipboardDetail.done")
                }
            }
            .actionFeedback(feedback)
        }
        .presentationDetents([.medium, .large])
    }
}
