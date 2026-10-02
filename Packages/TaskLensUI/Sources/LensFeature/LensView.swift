import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization
import UIKit

public struct LensView: View {
    @State private var model: LensModel
    @Environment(\.openURL) private var openURL
    @FocusState private var isInputFocused: Bool

    public init(model: LensModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            Section {
                TextField(L10n.string(.lensPlaceholder), text: $model.input, axis: .vertical)
                    .lineLimit(3...10)
                    .focused($isInputFocused)
                    .accessibilityIdentifier("lens.input")
                HStack {
                    PasteButton(payloadType: String.self) { [model] strings in
                        Task { @MainActor in model.paste(strings) }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    Spacer()
                    Button {
                        isInputFocused = false
                        model.analyze()
                    } label: {
                        TLLabel(.lensTitle, systemImage: "viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canAnalyze)
                    .accessibilityIdentifier("lens.analyze")
                }
                .buttonStyle(.borderless)
            } header: {
                Text(L10nKey.lensInput)
            } footer: {
                Text(L10nKey.lensSubtitle)
            }

            if let content = model.content {
                Section {
                    LabeledContent {
                        Text(L10nKey.itemType(content.itemType))
                    } label: {
                        Label {
                            Text(L10nKey.lensDetectedType)
                        } icon: {
                            Image(systemName: content.itemType.symbolName)
                        }
                    }
                    .accessibilityIdentifier("lens.detectedType")
                }

                Section {
                    ForEach(model.actions, id: \.type) { action in
                        actionRow(action, content: content)
                    }
                } header: {
                    Text(L10nKey.lensActions)
                }
            }
        }
        .navigationTitle(Text(L10nKey.lensTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadTarget() }
        .errorAlert(message: $model.errorMessage)
    }

    @ViewBuilder
    private func actionRow(_ action: Action, content: ContextContent) -> some View {
        switch action.type {
        case .openURL:
            if case .url(let url) = content {
                Button { openURL(url) } label: { actionLabel(action, systemImage: "safari") }
            }
        case .copy:
            Button {
                UIPasteboard.general.string = model.shareableText
            } label: {
                actionLabel(action, systemImage: "doc.on.doc")
            }
        case .share:
            if let text = model.shareableText {
                ShareLink(item: text) { actionLabel(action, systemImage: "square.and.arrow.up") }
            }
        case .saveToSession:
            Button {
                Task { await model.save() }
            } label: {
                if model.savedItem != nil {
                    TLLabel(.lensSaved, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    actionLabel(action, systemImage: "tray.and.arrow.down")
                }
            }
            .disabled(model.savedItem != nil)
            .accessibilityIdentifier("lens.save")
        default:
            EmptyView()
        }
    }

    private func actionLabel(_ action: Action, systemImage: String) -> some View {
        Label {
            Text(LocalizedStringKey(action.titleKey), bundle: L10n.bundle)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
