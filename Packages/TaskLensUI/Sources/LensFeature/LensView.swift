import AIFeature
import SwiftUI
import TLActionsUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation

public struct LensView: View {
    @State private var model: LensModel
    @State private var feedback = ActionFeedback()
    @Environment(AppRouter.self) private var router
    /// Owned by the app so a capture outlives this screen; nil in previews.
    @Environment(ScreenLensModel.self) private var screenLens: ScreenLensModel?
    @FocusState private var isInputFocused: Bool
    /// An image or PDF to read as soon as the screen opens.
    private let openingFile: URL?

    public init(model: LensModel, openingFile: URL? = nil) {
        _model = State(initialValue: model)
        self.openingFile = openingFile
    }

    /// What AI would work on: the image or screen text when Lens read one,
    /// otherwise the analyzed text. Nil until Lens has something.
    private var aiSource: (text: String, entities: [String])? {
        if model.imageLens.phase == .done, let report = model.imageLens.report, !report.text.text.isEmpty {
            return (report.text.text, LensModel.entityLines(report.findings))
        }
        if let screenLens, screenLens.state == .done, let report = screenLens.results.report, !report.text.text.isEmpty {
            return (report.text.text, LensModel.entityLines(report.findings))
        }
        if model.imageLens.phase == .idle, model.content != nil, let analysis = model.analysis {
            return (model.input, LensModel.entityLines(analysis.entities))
        }
        return nil
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

            if let screenLens {
                ScreenLensSection(model: screenLens)
            }

            if model.imageLens.phase != .idle {
                ImageLensResultSections(model: model.imageLens, feedback: feedback) { finding in
                    ActionHandlers(
                        onSave: { await model.imageLens.save(finding) },
                        onCalculate: { router.push(.calculatorInput($0)) },
                        onCreateNote: { router.push(.noteDraft($0)) },
                        onSearch: { router.search($0) }
                    )
                }
            } else if let screenLens, screenLens.state == .done {
                ScreenLensFoundSection(model: screenLens)
                SelectedFindingSection(model: screenLens.results, feedback: feedback) { finding in
                    ActionHandlers(
                        onSave: { await screenLens.results.save(finding) },
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

            if let ai = model.ai, let source = aiSource {
                AIAssistSection(
                    model: ai,
                    content: source.text,
                    entities: source.entities,
                    feedback: feedback,
                    handlers: ActionHandlers(
                        onCalculate: { router.push(.calculatorInput($0)) },
                        onCreateNote: { router.push(.noteDraft($0)) },
                        onSearch: { router.search($0) }
                    ),
                    saveText: { await model.saveText($0) }
                )
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
