import AppIntents
import Foundation
import TLCoreServices
import TLDomain
import TLFoundation
import TLLocalization
import TLNavigation

// App Intents for Siri, Shortcuts, Spotlight and the Action button.
// Each intent is thin: the work is in `SystemActions` (TaskLensKit), which
// has its own tests. Intents that show a screen open TaskLens and leave a
// `tasklens://` link for `RootView`; the others run without opening the app.
// Nothing here uses the network.

// MARK: Workspaces and sessions

struct StartWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.startWorkspace.title"
    static let description: IntentDescription? = IntentDescription("intent.startWorkspace.description")
    static let openAppWhenRun = true

    @Parameter(title: "intent.param.workspaceKind", default: .research)
    var kind: WorkspaceKindOption

    init() {}

    init(kind: WorkspaceKindOption) {
        self.kind = kind
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = IntentDependencies.container
        let name = L10n.string(L10nKey.workspaceKind(kind.kind))
        let workspace = try await container.systemActions.startWorkspace(kind: kind.kind, name: name)
        IntentDependencies.navigator.open(DeepLink.workspace(workspace.id))
        await container.refreshWidgets()
        return .result()
    }
}

struct OpenWorkspaceIntent: OpenIntent {
    static let title: LocalizedStringResource = "intent.openWorkspace.title"
    static let description: IntentDescription? = IntentDescription("intent.openWorkspace.description")

    @Parameter(title: "intent.param.workspace", requestValueDialog: "intent.prompt.workspace")
    var target: WorkspaceEntity

    init() {}

    init(target: WorkspaceEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = IntentDependencies.container
        let workspace = try await container.workspaces.markOpened(WorkspaceID(target.id))
        IntentDependencies.navigator.open(DeepLink.workspace(workspace.id))
        return .result()
    }
}

struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.startSession.title"
    static let description: IntentDescription? = IntentDescription("intent.startSession.description")
    static let openAppWhenRun = true

    @Parameter(title: "intent.param.workspace", requestValueDialog: "intent.prompt.workspace")
    var workspace: WorkspaceEntity

    /// Empty means the workspace's default session kind.
    @Parameter(title: "intent.param.sessionKind")
    var kind: SessionKindOption?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = IntentDependencies.container
        let session = try await container.systemActions.startSession(in: WorkspaceID(workspace.id), kind: kind?.kind)
        IntentDependencies.navigator.open(DeepLink.session(session.id))
        await container.refreshWidgets()
        return .result()
    }
}

struct OpenSessionIntent: OpenIntent {
    static let title: LocalizedStringResource = "intent.openSession.title"
    static let description: IntentDescription? = IntentDescription("intent.openSession.description")

    @Parameter(title: "intent.param.session", requestValueDialog: "intent.prompt.session")
    var target: SessionEntity

    init() {}

    init(target: SessionEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Resume makes the session active again and shows where the user stopped.
        IntentDependencies.navigator.open(DeepLink.resume(SessionID(target.id)))
        return .result()
    }
}

// MARK: Content

struct SaveContentIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.saveContent.title"
    static let description: IntentDescription? = IntentDescription("intent.saveContent.description")

    @Parameter(title: "intent.param.text", requestValueDialog: "intent.prompt.text")
    var text: String

    /// A specific session. Takes priority over `sessionKind`.
    @Parameter(title: "intent.param.session")
    var session: SessionEntity?

    /// "Save to Shopping Session": the latest open session of this kind, or a new one.
    @Parameter(title: "intent.param.sessionKind")
    var sessionKind: SessionKindOption?

    init() {}

    init(text: String, session: SessionEntity? = nil, sessionKind: SessionKindOption? = nil) {
        self.text = text
        self.session = session
        self.sessionKind = sessionKind
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let actions = IntentDependencies.container.systemActions
        var sessionID = session.map { SessionID($0.id) }
        if sessionID == nil, let sessionKind {
            let workspaceName = L10n.string(L10nKey.workspaceKind(WorkspaceKind(rawValue: sessionKind.rawValue)))
            sessionID = try await actions.sessionForSaving(kind: sessionKind.kind, workspaceName: workspaceName).id
        }
        let saved = try await actions.save(text, into: sessionID)
        await IntentDependencies.container.refreshWidgets()
        return .result(dialog: "\(Self.message(for: saved.destination))")
    }

    static func message(for destination: SystemActions.Destination) -> String {
        switch destination {
        case .session(let session): L10n.format(.intentResultSavedToSession, SessionEntity.title(of: session))
        case .inbox: L10n.string(.intentResultSavedToInbox)
        }
    }
}

/// "Save to Shopping Session": the kind is required so Siri can ask for it by name.
struct SaveToSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.saveToSession.title"
    static let description: IntentDescription? = IntentDescription("intent.saveToSession.description")

    @Parameter(title: "intent.param.sessionKind", default: .shopping)
    var sessionKind: SessionKindOption

    @Parameter(title: "intent.param.text", requestValueDialog: "intent.prompt.text")
    var text: String

    init() {}

    init(text: String, sessionKind: SessionKindOption) {
        self.text = text
        self.sessionKind = sessionKind
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await SaveContentIntent(text: text, sessionKind: sessionKind).perform()
    }
}

struct SendToTaskLensIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.sendToTaskLens.title"
    static let description: IntentDescription? = IntentDescription("intent.sendToTaskLens.description")
    static let openAppWhenRun = true

    @Parameter(title: "intent.param.text", requestValueDialog: "intent.prompt.lensText")
    var text: String

    init() {}

    init(text: String) {
        self.text = text
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskLensError.validationFailed(.emptyContent)
        }
        IntentDependencies.navigator.open(DeepLink.lens(text: text))
        return .result()
    }
}

struct StartLensIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.startLens.title"
    static let description: IntentDescription? = IntentDescription("intent.startLens.description")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentDependencies.navigator.open(DeepLink.lens)
        return .result()
    }
}

struct OpenClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.openClipboard.title"
    static let description: IntentDescription? = IntentDescription("intent.openClipboard.description")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentDependencies.navigator.open(DeepLink.clipboard)
        return .result()
    }
}

struct CreateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.createNote.title"
    static let description: IntentDescription? = IntentDescription("intent.createNote.description")

    @Parameter(title: "intent.param.text", requestValueDialog: "intent.prompt.note")
    var text: String

    init() {}

    init(text: String) {
        self.text = text
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let note = try await IntentDependencies.container.systemActions.createNote(text)
        let name = note.title.isEmpty ? String(note.body.prefix(60)) : note.title
        return .result(dialog: "\(L10n.format(.intentResultNoteCreated, name))")
    }
}

// MARK: Numbers

struct CalculateIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.calculate.title"
    static let description: IntentDescription? = IntentDescription("intent.calculate.description")

    @Parameter(title: "intent.param.expression", requestValueDialog: "intent.prompt.expression")
    var expression: String

    init() {}

    init(expression: String) {
        self.expression = expression
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let completion = try IntentDependencies.container.systemActions.calculate(expression)
        let value = completion.result.formatted(.number.precision(.fractionLength(0...CalculatorEngine.resultScale)))
        return .result(value: value, dialog: "\(L10n.format(.intentResultEquals, completion.expression, value))")
    }
}

struct ConvertCurrencyIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.convertCurrency.title"
    static let description: IntentDescription? = IntentDescription("intent.convertCurrency.description")

    @Parameter(title: "intent.param.amount", requestValueDialog: "intent.prompt.amount")
    var amount: Double

    /// Units of the target currency per one unit of the amount's currency.
    @Parameter(title: "intent.param.rate", requestValueDialog: "intent.prompt.rate")
    var rate: Double

    /// ISO code such as "EUR", used only to format the result.
    @Parameter(title: "intent.param.currency")
    var currencyCode: String?

    init() {}

    init(amount: Double, rate: Double, currencyCode: String? = nil) {
        self.amount = amount
        self.rate = rate
        self.currencyCode = currencyCode
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let actions = IntentDependencies.container.systemActions
        let result = try actions.convert(Self.decimal(amount), rate: Self.decimal(rate))
        let formatted = Self.format(result, currencyCode: currencyCode)
        let source = Self.decimal(amount).formatted(.number)
        return .result(
            value: NSDecimalNumber(decimal: result).doubleValue,
            dialog: "\(L10n.format(.intentResultEquals, source, formatted))"
        )
    }

    /// Doubles from Shortcuts carry binary noise (1.1 → 1.100000000000000088);
    /// going through the shortest text form keeps the number the user typed.
    static func decimal(_ value: Double) -> Decimal {
        Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(value)
    }

    static func format(_ value: Decimal, currencyCode: String?) -> String {
        let code = currencyCode?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        if code.count == 3, Locale.commonISOCurrencyCodes.contains(code) {
            return value.formatted(.currency(code: code))
        }
        return value.formatted(.number.precision(.fractionLength(0...4)))
    }
}
