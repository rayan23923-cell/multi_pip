import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization
import Translation
import UIKit

/// Feedback shared by the action rows of a screen: alerts, the translation
/// sheet and the "Copied" confirmation. Owned by the screen and attached once
/// with `.actionFeedback(_:)`, so it works however long the list is.
@MainActor
@Observable
public final class ActionFeedback {
    public var message: L10nKey?
    public var translationText: String?
    public var copiedActionID: ActionID?

    public init() {}
}

extension View {
    public func actionFeedback(_ feedback: ActionFeedback) -> some View {
        modifier(ActionFeedbackPresenter(feedback: feedback))
    }
}

private struct ActionFeedbackPresenter: ViewModifier {
    @Bindable var feedback: ActionFeedback

    func body(content: Content) -> some View {
        content
            .alert(
                Text(feedback.message ?? .actionsUnavailable),
                isPresented: Binding(get: { feedback.message != nil }, set: { if !$0 { feedback.message = nil } })
            ) {
                Button(role: .cancel) {} label: { Text(L10nKey.commonOk) }
            }
            .modifier(TranslationPresenter(text: $feedback.translationText))
    }
}

/// The suggested actions for one piece of content, as a list section.
///
/// Every action either runs, or says plainly why it cannot yet
/// (coming in a later update, or only available in the app).
public struct ContextActionsSection: View {
    private let actions: [Action]
    private let content: ContextContent?
    private let capabilities: ActionCapabilities
    private let isSaved: Bool
    private let feedback: ActionFeedback
    private let onSave: (() async -> Void)?
    private let onCalculate: ((Decimal) -> Void)?

    @Environment(\.openURL) private var openURL

    public init(
        actions: [Action],
        content: ContextContent?,
        feedback: ActionFeedback,
        capabilities: ActionCapabilities = .app,
        isSaved: Bool = false,
        hiding hiddenTypes: Set<ActionType> = [],
        onSave: (() async -> Void)? = nil,
        onCalculate: ((Decimal) -> Void)? = nil
    ) {
        self.actions = actions.filter { !hiddenTypes.contains($0.type) }
        self.content = content
        self.feedback = feedback
        self.capabilities = capabilities
        self.isSaved = isSaved
        self.onSave = onSave
        self.onCalculate = onCalculate
    }

    public var body: some View {
        if !actions.isEmpty {
            Section {
                ForEach(actions) { action in
                    row(action, plan: ActionPlan.make(for: action, content: content, capabilities: capabilities))
                        .accessibilityIdentifier("action.\(action.type.rawValue)")
                }
            } header: {
                Text(L10nKey.lensActions)
            }
        }
    }

    @ViewBuilder
    private func row(_ action: Action, plan: ActionPlan) -> some View {
        switch plan {
        case .share(let text):
            ShareLink(item: text) { label(action) }
        case .save:
            Button {
                Task { await onSave?() }
            } label: {
                if isSaved {
                    TLLabel(.commonSaved, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    label(action)
                }
            }
            .disabled(isSaved || onSave == nil)
        default:
            Button { perform(action, plan: plan) } label: { label(action, plan: plan) }
        }
    }

    private func perform(_ action: Action, plan: ActionPlan) {
        switch plan {
        case .open(let url):
            openURL(url)
        case .copy(let text):
            UIPasteboard.general.string = text
            feedback.copiedActionID = action.id
            let feedback = feedback
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if feedback.copiedActionID == action.id { feedback.copiedActionID = nil }
            }
        case .calculate(let value):
            if let onCalculate { onCalculate(value) } else { feedback.message = .actionsOpenApp }
        case .translate(let text):
            if #available(iOS 17.4, *) {
                feedback.translationText = text
            } else {
                feedback.message = .actionsTranslateUnavailable
            }
        case .comingLater:
            feedback.message = .actionsComingLater
        case .openApp:
            feedback.message = .actionsOpenApp
        case .unavailable:
            feedback.message = .actionsUnavailable
        case .share, .save:
            break
        }
    }

    @ViewBuilder
    private func label(_ action: Action, plan: ActionPlan? = nil) -> some View {
        let copied = feedback.copiedActionID == action.id
        HStack {
            Label {
                if copied {
                    Text(L10nKey.commonCopied)
                } else if let key = L10nKey.action(action) {
                    Text(key)
                } else {
                    Text(verbatim: action.type.rawValue)
                }
            } icon: {
                Image(systemName: copied ? "checkmark" : action.type.symbolName)
            }
            if plan == .comingLater || plan == .openApp {
                Spacer()
                Text(plan == .comingLater ? L10nKey.actionsLater : L10nKey.actionsInApp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Apple's on-device translation sheet (iOS 17.4+). TaskLens hands the text
/// to the system and does not send it anywhere itself.
private struct TranslationPresenter: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        if #available(iOS 17.4, *) {
            content.translationPresentation(
                isPresented: Binding(get: { text != nil }, set: { if !$0 { text = nil } }),
                text: text ?? ""
            )
        } else {
            content
        }
    }
}

extension ActionType {
    public var symbolName: String {
        switch self {
        case .copy: "doc.on.doc"
        case .share: "square.and.arrow.up"
        case .saveToSession: "tray.and.arrow.down"
        case .createNote: "note.text.badge.plus"
        case .openURL: "safari"
        case .call: "phone"
        case .sendMessage: "message"
        case .sendEmail: "envelope"
        case .addContact: "person.crop.circle.badge.plus"
        case .addToCalendar: "calendar.badge.plus"
        case .openInMaps: "map"
        case .calculate: "plus.forwardslash.minus"
        case .convertCurrency: "dollarsign.arrow.circlepath"
        case .extractText: "text.viewfinder"
        case .translate: "translate"
        case .summarize: "text.badge.star"
        case .createReminder: "checklist"
        default: "bolt"
        }
    }
}

extension ContentCategory {
    public var symbolName: String {
        switch self {
        case .plainText: "text.alignleft"
        case .url: "link"
        case .phone: "phone"
        case .email: "envelope"
        case .currency: "banknote"
        case .number: "number"
        case .date: "calendar"
        case .address: "mappin.and.ellipse"
        case .json: "curlybraces"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .document: "doc"
        case .unknown: "questionmark.square.dashed"
        }
    }
}
