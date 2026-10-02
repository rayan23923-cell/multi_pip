import Foundation
import LensFeature
import SettingsFeature
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import WidgetKit

/// Composition root: the only place that knows concrete implementations.
/// Features receive services; services receive repository protocols.
struct AppContainer: Sendable {
    let workspaces: WorkspaceService
    let sessions: SessionService
    let sessionContent: SessionContentService
    /// Remembers tool positions for Resume.
    let toolState: ToolStateRecorder
    /// Cards kept for Picture in Picture.
    let pip: PiPWorkspaceService
    /// What Siri, Shortcuts and widgets can ask for.
    let systemActions: SystemActions
    /// Where widgets read their snapshot. Nil when this build has no App Group
    /// container (unsigned simulator builds); widgets then show their empty state.
    let widgetStore: WidgetSnapshotStore?
    /// Fires when sessions or their items change; drives Live Activities and widgets.
    let storeChanges: StoreChangeSignal
    /// Which session Live Activities should exist.
    let sessionActivities: SessionActivityService
    let capture: CaptureService
    let notes: NoteService
    let clipboard: ClipboardService
    let search: SmartSearchService
    let calculator: CalculatorService
    let documents: DocumentService
    let toolCapture: ToolCaptureService
    let share: ShareService
    /// Where the share extension leaves shared items for the app.
    let shareOutbox: ShareOutbox
    let storage: SettingsView.StorageDescription
    /// Optional AI over Lens; the app works fully without it.
    let ai: AIService
    /// Where the AI server key is kept.
    let aiSecrets: any SecretStoring
    /// User workflows and the runner that performs their steps.
    let workflows: WorkflowService
    let workflowRunner: WorkflowRunner
    /// Runs enabled workflows on items shared to the app.
    let workflowAutomation: WorkflowAutomation
    let logger: TLLogger

    init(
        repositories: Repositories,
        filesDirectory: URL,
        storeRoot: URL,
        storage: SettingsView.StorageDescription,
        widgetStore: WidgetSnapshotStore? = nil,
        storeChanges: StoreChangeSignal = StoreChangeSignal(),
        clock: any DateProviding = SystemDateProvider(),
        aiSettings: any AISettingsStoring = InMemoryAISettingsStore(),
        aiSecrets: any SecretStoring = InMemorySecretStore(),
        aiProviders: [any AIProvider]? = nil,
        logger: TLLogger = TLLogger(category: "app")
    ) {
        let repositories = repositories.observingSessions(storeChanges)
        let capture = CaptureService(
            sessions: repositories.sessions,
            contextItems: repositories.contextItems,
            detector: ContextEngine(),
            clock: clock,
            logger: logger.scoped("capture")
        )
        self.workspaces = WorkspaceService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            contextItems: repositories.contextItems,
            documents: repositories.documents,
            notes: repositories.notes,
            actionRecords: repositories.actionRecords,
            clock: clock,
            logger: logger.scoped("workspaces")
        )
        self.sessions = SessionService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            clock: clock,
            logger: logger.scoped("sessions")
        )
        self.sessionContent = SessionContentService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            contextItems: repositories.contextItems,
            notes: repositories.notes,
            actionRecords: repositories.actionRecords,
            clock: clock,
            logger: logger.scoped("sessions")
        )
        self.toolState = ToolStateRecorder(service: sessionContent, clock: clock)
        self.pip = PiPWorkspaceService(
            cards: repositories.pipCards,
            presentation: repositories.pipPresentation,
            clock: clock,
            logger: logger.scoped("pip")
        )
        self.capture = capture
        self.notes = NoteService(notes: repositories.notes, clock: clock, logger: logger.scoped("notes"))
        self.clipboard = ClipboardService(
            clipboardItems: repositories.clipboardItems,
            capture: capture,
            clock: clock,
            logger: logger.scoped("clipboard")
        )
        self.search = SmartSearchService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            contextItems: repositories.contextItems,
            notes: repositories.notes,
            documents: repositories.documents,
            clipboardItems: repositories.clipboardItems,
            semantic: OnDeviceSemanticRanker(),
            clock: clock
        )
        self.calculator = CalculatorService(
            records: repositories.calculations,
            clock: clock,
            logger: logger.scoped("calculator")
        )
        self.documents = DocumentService(
            documents: repositories.documents,
            filesDirectory: filesDirectory,
            clock: clock,
            logger: logger.scoped("documents")
        )
        self.toolCapture = ToolCaptureService(capture: capture, sessions: self.sessions)
        self.share = ShareService(capture: capture, documents: self.documents)
        self.shareOutbox = ShareOutbox(storeRoot: storeRoot)
        self.systemActions = SystemActions(workspaces: self.workspaces, sessions: self.sessions, capture: capture, notes: self.notes)
        self.widgetStore = widgetStore
        self.storeChanges = storeChanges
        self.sessionActivities = SessionActivityService(workspaces: self.workspaces, sessions: self.sessions, capture: capture, clock: clock)
        self.storage = storage
        self.aiSecrets = aiSecrets
        self.ai = AIService(
            providers: aiProviders ?? [
                AppleIntelligenceProvider(),
                AIServerProvider(settings: aiSettings, secrets: aiSecrets, network: NetworkMonitor.shared),
            ],
            settings: aiSettings,
            records: repositories.aiRecords,
            clock: clock,
            logger: logger.scoped("ai")
        )
        self.workflows = WorkflowService(workflows: repositories.workflows, clock: clock)
        self.workflowRunner = WorkflowRunner(
            capture: capture, notes: self.notes, calculator: self.calculator,
            workspaces: self.workspaces, sessions: self.sessions,
            ai: self.ai, reader: LensWorkflowReader()
        )
        self.workflowAutomation = WorkflowAutomation(service: self.workflows, runner: self.workflowRunner, documents: self.documents)
        self.logger = logger
    }

    /// The one container of this process, shared by the app and its App Intents
    /// so both read and write the same store.
    static let shared = AppContainer.live()

    /// Persistent container for the running app. Falls back to memory if the
    /// store cannot be opened, so the app still launches and the user is told
    /// (in Settings) that data is temporary.
    static func live(
        bundle: Bundle = .main,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AppContainer {
        let logger = TLLogger(category: "app")
        let groupIdentifier = bundle.object(forInfoDictionaryKey: "TLAppGroupIdentifier") as? String
        let isUITest = arguments.contains("-TaskLensUITestStore")
        do {
            let location = try uiTestStoreLocation(arguments: arguments)
                ?? StoreLocation.resolve(appGroupIdentifier: groupIdentifier, logger: logger)
            let repositories = try Repositories.fileBacked(at: location, logger: logger.scoped("persistence"))
            logger.info("Store opened (\(location.kind.rawValue))")
            return AppContainer(
                repositories: repositories,
                filesDirectory: location.filesDirectory,
                storeRoot: location.rootURL,
                storage: location.kind == .appGroup ? .appGroup : .local,
                widgetStore: WidgetSnapshotStore.shared(appGroupIdentifier: groupIdentifier),
                aiSettings: isUITest
                    ? InMemoryAISettingsStore(AISettings(allowsServer: arguments.contains("-TaskLensAIOffline")))
                    : UserDefaultsAISettingsStore(),
                aiSecrets: isUITest ? InMemorySecretStore() : KeychainSecretStore(),
                aiProviders: AITestProviders.make(arguments: arguments),
                logger: logger
            )
        } catch {
            logger.fault("Falling back to in-memory store: \(error)")
            return AppContainer(
                repositories: .inMemory(),
                filesDirectory: temporaryFilesDirectory(),
                storeRoot: temporaryFilesDirectory(),
                storage: .memory,
                logger: logger
            )
        }
    }

    /// UI tests run against an isolated store so they never touch real data.
    /// `-TaskLensUITestStore` selects it; `-TaskLensResetStore` wipes it first.
    static func uiTestStoreLocation(arguments: [String]) throws -> StoreLocation? {
        guard arguments.contains("-TaskLensUITestStore") else { return nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskLensUITestStore", isDirectory: true)
        if arguments.contains("-TaskLensResetStore") {
            try? FileManager.default.removeItem(at: root)
        }
        return StoreLocation(rootURL: root, kind: .custom)
    }

    static func preview() -> AppContainer {
        AppContainer(
            repositories: .inMemory(),
            filesDirectory: temporaryFilesDirectory(),
            storeRoot: temporaryFilesDirectory(),
            storage: .memory,
            logger: .disabled()
        )
    }

    /// Files for in-memory stores go to a throwaway folder.
    private static func temporaryFilesDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TaskLensFiles-\(UUID().uuidString)", isDirectory: true)
    }

    /// Saves items left by the share extension into their sessions (or the inbox).
    @discardableResult
    @discardableResult
    func deliverSharedItems() async -> [ContextItem] {
        let items = await shareOutbox.deliver(using: share, sessions: sessions)
        if !items.isEmpty {
            logger.info("Delivered \(items.count) shared item(s)")
        }
        return items
    }

    /// Writes what widgets show and asks WidgetKit to redraw them.
    func refreshWidgets() async {
        guard let widgetStore else { return }
        do {
            let snapshot = try await WidgetSnapshot.make(workspaces: workspaces, sessions: sessions, capture: capture, now: Date())
            try widgetStore.write(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            logger.error("Widget snapshot failed: \(error)")
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
