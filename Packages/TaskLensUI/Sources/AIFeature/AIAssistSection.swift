import SwiftUI
import TLActionsUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization

/// "AI (optional)" below Lens results: pick a task, see what will be sent and
/// where, then Send. The answer and its suggested actions appear here; the
/// deterministic actions above never depend on it.
public struct AIAssistSection: View {
    @Bindable var model: AIAssistModel
    let content: String
    let entities: [String]
    let feedback: ActionFeedback
    let handlers: ActionHandlers
    let saveText: (String) async -> Void

    /// `content` is the text Lens has (typed, OCR'd, or a document's text);
    /// `saveText` saves an answer the user chose to keep.
    public init(
        model: AIAssistModel, content: String, entities: [String], feedback: ActionFeedback,
        handlers: ActionHandlers, saveText: @escaping (String) async -> Void
    ) {
        self.model = model
        self.content = content
        self.entities = entities
        self.feedback = feedback
        self.handlers = handlers
        self.saveText = saveText
    }

    public var body: some View {
        Section {
            if case .unavailable(let reason) = model.phase {
                unavailable(reason)
            } else {
                controls
            }
        } header: {
            Text(L10nKey.aiSection)
        } footer: {
            Text(L10nKey.aiFooter)
        }
        .task(id: content) { await model.setContent(content, entities: entities) }
        .task(id: model.task) { await model.refresh() }
        .onChange(of: model.includesSessionContext) { _, _ in Task { await model.refresh() } }
        .onChange(of: model.targetLanguage) { _, _ in Task { await model.refresh() } }

        if case .answered(let answer, let provider) = model.phase {
            AIAnswerSections(answer: answer, provider: provider, feedback: feedback, handlers: answerHandlers(answer)) {
                model.clear()
            }
        }
    }

    private func answerHandlers(_ answer: AIAnswer) -> ActionHandlers {
        var handlers = handlers
        let saveText = saveText
        handlers.onSave = { await saveText(answer.text) }
        return handlers
    }

    @ViewBuilder
    private var controls: some View {
        Picker(selection: $model.task) {
            ForEach(model.tasks, id: \.self) { task in
                Text(L10nKey.aiTask(task)).tag(task)
            }
        } label: {
            Text(L10nKey.aiTaskLabel)
        }
        .accessibilityIdentifier("ai.task")

        if model.task.needsQuestion {
            TextField(L10n.string(.aiQuestion), text: $model.question, axis: .vertical)
                .accessibilityIdentifier("ai.question")
        }
        if model.task == .translate {
            Picker(selection: $model.targetLanguage) {
                Text(L10nKey.aiLanguageArabic).tag(AIAssistModel.TargetLanguage.arabic)
                Text(L10nKey.aiLanguageEnglish).tag(AIAssistModel.TargetLanguage.english)
            } label: {
                Text(L10nKey.aiTargetLanguage)
            }
        }
        if model.task.usesSessionContext || model.task.needsQuestion {
            Toggle(isOn: $model.includesSessionContext) {
                Text(L10nKey.aiIncludeSession)
            }
            .accessibilityIdentifier("ai.includeSession")
        }

        if let disclosure = model.disclosure {
            AIDisclosureView(disclosure: disclosure)
        }

        switch model.phase {
        case .running:
            HStack {
                ProgressView()
                Text(L10nKey.aiRunning)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ai.running")
        case .failed:
            Text(L10nKey.aiFailed)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ai.failed")
            retryButton
        default:
            Button {
                Task { await model.send() }
            } label: {
                TLLabel(.aiSend, systemImage: "sparkles")
            }
            .disabled(!model.canSend)
            .accessibilityIdentifier("ai.send")
        }
    }

    @ViewBuilder
    private func unavailable(_ reason: AIUnavailableReason) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10nKey.aiUnavailable(reason))
                Text(L10nKey.aiStillWorks)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: reason == .offline ? "wifi.slash" : "sparkles")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ai.unavailable")
        if reason == .offline || reason == .modelNotReady {
            retryButton
        }
    }

    private var retryButton: some View {
        Button {
            Task { await model.retry() }
        } label: {
            TLLabel(.aiRetry, systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("ai.retry")
    }
}

/// "Sends 1,240 characters to Apple Intelligence on this iPhone. Nothing
/// leaves your device." — or the server host. Shown before every request.
struct AIDisclosureView: View {
    let disclosure: AIDisclosure

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                if disclosure.leavesDevice {
                    Text(verbatim: L10n.format(.aiDisclosureServer, disclosure.characters, disclosure.destination))
                } else {
                    Text(verbatim: L10n.format(.aiDisclosureDevice, disclosure.characters))
                }
                if disclosure.includesSessionContext {
                    Text(L10nKey.aiDisclosureSession)
                }
                if disclosure.isTruncated {
                    Text(L10nKey.aiDisclosureTruncated)
                }
            }
            .font(.footnote)
        } icon: {
            Image(systemName: disclosure.leavesDevice ? "network" : "lock.iphone")
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ai.disclosure")
    }
}

/// The answer, then the actions AI suggested. Suggestions only run when tapped;
/// those that leave TaskLens ask for confirmation first.
struct AIAnswerSections: View {
    let answer: AIAnswer
    let provider: AIProviderKind
    let feedback: ActionFeedback
    let handlers: ActionHandlers
    let clear: () -> Void

    var body: some View {
        Section {
            Text(verbatim: answer.text)
                .textSelection(.enabled)
                .accessibilityIdentifier("ai.answer")
            Button(role: .destructive, action: clear) {
                TLLabel(.aiClear, systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("ai.clear")
        } header: {
            Text(provider == .onDevice ? L10nKey.aiAnswerDevice : L10nKey.aiAnswerServer)
        }

        let content = ContextContent.text(answer.text)
        let analysis = ActionEngine.analyze(content, context: ActionContext(source: .manualEntry))
        let suggested = Set(answer.suggestions)
        // Always offer keeping the answer; suggested actions appear only if AI named them.
        let offered = analysis.actions.filter { suggested.contains($0.type) || $0.type == .createNote || $0.type == .copy || $0.type == .saveToSession }
        if !offered.isEmpty {
            ActionCard(
                analysis: ContextAnalysis(category: analysis.category, entities: analysis.entities, actions: offered),
                content: content,
                feedback: feedback,
                confirming: AIAnswer.sensitiveActions,
                handlers: handlers
            )
            Text(L10nKey.aiSuggestionsNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
    }
}
