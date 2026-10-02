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
    /// An image or PDF to read as soon as the screen opens.
    private let openingFile: URL?

    public init(model: LensModel, openingFile: URL? = nil) {
        _model = State(initialValue: model)
        self.openingFile = openingFile
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

            ImageLensInputSection(model: model.imageLens)

            if model.imageLens.phase != .idle {
                ImageLensResultSections(model: model.imageLens, feedback: feedback) { finding in
                    ActionHandlers(
                        onSave: { await model.imageLens.save(finding) },
                        onCalculate: { router.push(.calculatorInput($0)) },
                        onCreateNote: { router.push(.noteDraft($0)) },
                        onSearch: { router.search($0) }
                    )
                }
            } else if let content = model.content, let analysis = model.analysis {
                Section {
                    DetectedTypeRow(analysis.category)
                        .accessibilityIdentifier("lens.detectedType")
                    DetectedValueRow(analysis)
                } header: {
                    Text(L10nKey.lensDetectedContent)
                }

                ActionCard(
                    analysis: analysis,
                    content: content,
                    feedback: feedback,
                    isSaved: model.savedItem != nil,
                    handlers: ActionHandlers(
                        onSave: { await model.save() },
                        onCalculate: { router.push(.calculatorInput($0)) },
                        onCreateNote: { router.push(.noteDraft($0)) },
                        onSearch: { router.search($0) }
                    )
                )

                EntitiesSection(analysis.entities)
            }
        }
        .navigationTitle(Text(L10nKey.lensTitle))
        .navigationBarTitleDisplayMode(.inline)
        .actionFeedback(feedback)
        .task {
            await model.loadTarget()
            if let openingFile, model.imageLens.phase == .idle {
                await model.imageLens.read(fileAt: openingFile, source: .fileImport)
            }
        }
        .errorAlert(message: $model.errorMessage)
    }
}
