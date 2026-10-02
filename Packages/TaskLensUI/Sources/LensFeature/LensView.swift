import SwiftUI
import TLActionsUI
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

public struct LensView: View {
    @State private var model: LensModel
    @State private var feedback = ActionFeedback()
    @Environment(AppRouter.self) private var router
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

            if let content = model.content, let analysis = model.analysis {
                Section {
                    DetectedTypeRow(analysis.category)
                        .accessibilityIdentifier("lens.detectedType")
                }

                EntitiesSection(analysis.entities)

                ContextActionsSection(
                    actions: analysis.actions,
                    content: content,
                    feedback: feedback,
                    isSaved: model.savedItem != nil,
                    onSave: { await model.save() },
                    onCalculate: { router.push(.calculatorInput($0)) }
                )
            }
        }
        .navigationTitle(Text(L10nKey.lensTitle))
        .navigationBarTitleDisplayMode(.inline)
        .actionFeedback(feedback)
        .task { await model.loadTarget() }
        .errorAlert(message: $model.errorMessage)
    }
}
