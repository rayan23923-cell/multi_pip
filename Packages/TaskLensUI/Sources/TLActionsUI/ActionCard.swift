import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization
import TLMediaUI
import Translation
import UIKit

/// Feedback shared by the action buttons of a screen: alerts, the translation
/// sheet, the event editor and the "Copied" confirmation. Owned by the screen
/// and attached once with `.actionFeedback(_:)`.
@MainActor
@Observable
public final class ActionFeedback {
    public var message: L10nKey?
    public var translationText: String?
    public var eventDraft: EventDraft?
    public var copiedActionID: ActionID?
    /// A price waiting for the user's exchange rate.
    public var conversion: CurrencyConversion?
    /// A YouTube video playing in YouTube's embedded player.
    public var video: YouTubeLink?

    public init() {}
}

/// "Convert" on a price: the user types the rate, the result opens in the calculator.
public struct CurrencyConversion: Identifiable {
    public let id = UUID()
    public let amount: Decimal
    public let currency: String?
    let onConverted: (Decimal) -> Void
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
            .sheet(item: $feedback.eventDraft) { draft in
                EventEditor(draft: draft) { feedback.eventDraft = nil }
                    .ignoresSafeArea()
            }
            .sheet(item: $feedback.video) { video in
                YouTubePlayerScreen(video: video)
            }
            .modifier(TranslationPresenter(text: $feedback.translationText))
            .modifier(ConversionPresenter(feedback: feedback))
    }
}

private struct ConversionPresenter: ViewModifier {
    @Bindable var feedback: ActionFeedback
    @State private var rateText = ""

    func body(content: Content) -> some View {
        content.alert(
            Text(L10nKey.actionsConvertTitle),
            isPresented: Binding(get: { feedback.conversion != nil }, set: { if !$0 { feedback.conversion = nil } }),
            presenting: feedback.conversion
        ) { conversion in
            TextField(L10n.string(.actionsConvertRate), text: $rateText)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("actions.convert.rate")
            Button {
                if let rate = ActionPlan.rate(from: rateText) {
                    conversion.onConverted(ActionPlan.converted(conversion.amount, rate: rate))
                } else {
                    feedback.message = .actionsConvertInvalidRate
                }
                rateText = ""
            } label: {
                Text(L10nKey.actionsConvertAction)
            }
            .accessibilityIdentifier("actions.convert.confirm")
            Button(role: .cancel) { rateText = "" } label: { Text(L10nKey.commonCancel) }
        } message: { conversion in
            let amount = conversion.amount.formatted(.number.locale(Locale(identifier: "en_US_POSIX")))
            Text(verbatim: L10n.format(.actionsConvertMessage, amount + " " + (conversion.currency ?? "")))
        }
    }
}

/// What the host screen does for actions that leave the card.
public struct ActionHandlers {
    public var onSave: (() async -> Void)?
    public var onCalculate: ((Decimal) -> Void)?
    public var onCreateNote: ((String) -> Void)?
    public var onSearch: ((String) -> Void)?
    /// Called after an action ran or was handed to the system, so a session
    /// can keep its action history. Not called for actions that could not run.
    public var onPerformed: ((Action, ActionPlan) -> Void)?

    public init(
        onSave: (() async -> Void)? = nil,
        onCalculate: ((Decimal) -> Void)? = nil,
        onCreateNote: ((String) -> Void)? = nil,
        onSearch: ((String) -> Void)? = nil,
        onPerformed: ((Action, ActionPlan) -> Void)? = nil
    ) {
        self.onSave = onSave
        self.onCalculate = onCalculate
        self.onCreateNote = onCreateNote
        self.onSearch = onSearch
        self.onPerformed = onPerformed
    }
}

/// The ranked actions for one piece of content, as list sections:
/// up to three recommended buttons, a few secondary rows, and the rest
/// behind "More". Never a wall of buttons.
///
/// Every action either runs, or says plainly why it cannot yet
/// (coming in a later update, or only available in the app).
public struct ActionCard: View {
    private let suggestions: ActionSuggestions
    private let content: ContextContent?
    private let capabilities: ActionCapabilities
    private let isSaved: Bool
    private let feedback: ActionFeedback
    private let handlers: ActionHandlers
    /// Actions that ask "Are you sure?" before running (AI suggestions that
    /// reach outside TaskLens).
    private let confirming: Set<ActionType>

    @State private var showsMore = false
    @State private var pending: PendingAction?
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `analysis.actions` must be ranked, best first. Hidden types are removed
    /// before grouping, so the next best action moves up.
    public init(
        analysis: ContextAnalysis,
        content: ContextContent?,
        feedback: ActionFeedback,
        capabilities: ActionCapabilities = .app,
        isSaved: Bool = false,
        hiding hiddenTypes: Set<ActionType> = [],
        confirming: Set<ActionType> = [],
        handlers: ActionHandlers = ActionHandlers()
    ) {
        self.suggestions = ActionSuggestions(ranked: analysis.actions.filter { !hiddenTypes.contains($0.type) })
        self.content = content
        self.feedback = feedback
        self.capabilities = capabilities
        self.isSaved = isSaved
        self.handlers = handlers
        self.confirming = confirming
    }

    private struct PendingAction: Identifiable {
        let action: Action
        let plan: ActionPlan
        var id: ActionID { action.id }
    }

    public var body: some View {
        if !suggestions.isEmpty {
            Section {
                recommended
            } header: {
                Text(L10nKey.actionsRecommended)
            }
            .confirmationDialog(
                Text(L10nKey.actionsConfirmTitle),
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending
            ) { pending in
                Button { perform(pending.action, plan: pending.plan) } label: {
                    title(pending.action, saved: false, copied: false)
                }
                Button(role: .cancel) {} label: { Text(L10nKey.commonCancel) }
            } message: { _ in
                Text(L10nKey.actionsConfirmMessage)
            }
            if !suggestions.secondary.isEmpty || !suggestions.more.isEmpty {
                Section {
                    ForEach(suggestions.secondary) { action in
                        row(action)
                    }
                    if showsMore {
                        ForEach(suggestions.more) { action in
                            row(action)
                        }
                    }
                    if !suggestions.more.isEmpty {
                        Button {
                            withAnimation { showsMore.toggle() }
                        } label: {
                            Label {
                                Text(showsMore ? L10nKey.actionsShowLess : L10nKey.commonMore)
                            } icon: {
                                Image(systemName: showsMore ? "chevron.up" : "ellipsis.circle")
                            }
                        }
                        .accessibilityIdentifier("actions.more")
                    }
                } header: {
                    Text(L10nKey.actionsOther)
                }
            }
        }
    }

    // MARK: Recommended buttons

    private var recommended: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: TLSpacing.s))
            : AnyLayout(HStackLayout(alignment: .top, spacing: TLSpacing.s))
        return layout {
            ForEach(Array(suggestions.primary.enumerated()), id: \.element.id) { index, action in
                let plan = ActionPlan.make(for: action, content: content, capabilities: capabilities)
                Group {
                    if index == 0 {
                        control(action, plan: plan, style: .tile).buttonStyle(.borderedProminent)
                    } else {
                        control(action, plan: plan, style: .tile).buttonStyle(.bordered)
                    }
                }
                .accessibilityIdentifier("action.\(action.type.rawValue)")
            }
        }
        .padding(.vertical, TLSpacing.xs)
    }

    // MARK: Rows

    private func row(_ action: Action) -> some View {
        control(action, plan: ActionPlan.make(for: action, content: content, capabilities: capabilities), style: .row)
            .accessibilityIdentifier("action.\(action.type.rawValue)")
    }

    private enum Style { case tile, row }

    @ViewBuilder
    private func control(_ action: Action, plan: ActionPlan, style: Style) -> some View {
        switch plan {
        case .share(let text):
            ShareLink(item: text) { label(action, plan: plan, style: style) }
        case .save:
            Button {
                Task { await handlers.onSave?() }
            } label: {
                label(action, plan: plan, style: style)
            }
            .disabled(isSaved || handlers.onSave == nil)
        default:
            Button {
                if confirming.contains(action.type) {
                    pending = PendingAction(action: action, plan: plan)
                } else {
                    perform(action, plan: plan)
                }
            } label: { label(action, plan: plan, style: style) }
        }
    }

    private func perform(_ action: Action, plan: ActionPlan) {
        switch plan {
        case .comingLater, .openApp, .unavailable, .share, .save:
            break
        default:
            handlers.onPerformed?(action, plan)
        }
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
            if let onCalculate = handlers.onCalculate { onCalculate(value) } else { feedback.message = .actionsOpenApp }
        case .convert(let amount, let currency):
            if let onCalculate = handlers.onCalculate {
                feedback.conversion = CurrencyConversion(amount: amount, currency: currency, onConverted: onCalculate)
            } else {
                feedback.message = .actionsOpenApp
            }
        case .createNote(let text):
            if let onCreateNote = handlers.onCreateNote { onCreateNote(text) } else { feedback.message = .actionsOpenApp }
        case .search(let query):
            if let onSearch = handlers.onSearch { onSearch(query) } else { feedback.message = .actionsOpenApp }
        case .createEvent(let draft):
            feedback.eventDraft = draft
        case .playVideo(let video):
            feedback.video = video
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

    // MARK: Labels

    private func title(_ action: Action, saved: Bool, copied: Bool) -> Text {
        if saved { return Text(L10nKey.commonSaved) }
        if copied { return Text(L10nKey.commonCopied) }
        if let key = L10nKey.action(action) { return Text(key) }
        return Text(verbatim: action.type.rawValue)
    }

    private func symbol(_ action: Action, saved: Bool, copied: Bool) -> String {
        if saved { return "checkmark.circle.fill" }
        if copied { return "checkmark" }
        if action.titleKey == Action.openInYouTubeTitleKey { return "arrow.up.forward.app" }
        return action.type.symbolName
    }

    /// "Later" or "In App", for actions that cannot run here and now.
    private func note(for plan: ActionPlan) -> L10nKey? {
        switch plan {
        case .comingLater: .actionsLater
        case .openApp: .actionsInApp
        default: nil
        }
    }

    @ViewBuilder
    private func label(_ action: Action, plan: ActionPlan, style: Style) -> some View {
        let saved = plan == .save && isSaved
        let copied = feedback.copiedActionID == action.id
        let note = note(for: plan)
        switch style {
        case .tile:
            VStack(spacing: TLSpacing.xxs) {
                Image(systemName: symbol(action, saved: saved, copied: copied))
                    .font(.title3)
                    .accessibilityHidden(true)
                title(action, saved: saved, copied: copied)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let note {
                    Text(note)
                        .font(.caption2)
                        .opacity(0.8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.vertical, TLSpacing.xxs)
        case .row:
            HStack {
                Label {
                    title(action, saved: saved, copied: copied)
                } icon: {
                    Image(systemName: symbol(action, saved: saved, copied: copied))
                }
                if let note {
                    Spacer()
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        case .search: "magnifyingglass"
        case .askAI: "sparkles"
        case .playVideo: "play.rectangle"
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
