import Foundation
import SettingsFeature
import TLCoreServices
import TLData
import TLDomain
import TLFoundation

/// Composition root: the only place that knows concrete implementations.
/// Features receive services; services receive repository protocols.
struct AppContainer: Sendable {
    let workspaces: WorkspaceService
    let sessions: SessionService
    let capture: CaptureService
    let notes: NoteService
    let clipboard: ClipboardService
    let search: SearchService
    let calculator: CalculatorService
    let documents: DocumentService
    let toolCapture: ToolCaptureService
    let share: ShareService
    /// Where the share extension leaves shared items for the app.
    let shareOutbox: ShareOutbox
    let storage: SettingsView.StorageDescription
    let logger: TLLogger

    init(
        repositories: Repositories,
        filesDirectory: URL,
        storeRoot: URL,
        storage: SettingsView.StorageDescription,
        clock: any DateProviding = SystemDateProvider(),
        logger: TLLogger = TLLogger(category: "app")
    ) {
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
            clock: clock,
            logger: logger.scoped("workspaces")
        )
        self.sessions = SessionService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            clock: clock,
            logger: logger.scoped("sessions")
        )
        self.capture = capture
        self.notes = NoteService(notes: repositories.notes, clock: clock, logger: logger.scoped("notes"))
        self.clipboard = ClipboardService(
            clipboardItems: repositories.clipboardItems,
            capture: capture,
            clock: clock,
            logger: logger.scoped("clipboard")
        )
        self.search = SearchService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            contextItems: repositories.contextItems
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
        self.storage = storage
        self.logger = logger
    }

    /// Persistent container for the running app. Falls back to memory if the
    /// store cannot be opened, so the app still launches and the user is told
    /// (in Settings) that data is temporary.
    static func live(
        bundle: Bundle = .main,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AppContainer {
        let logger = TLLogger(category: "app")
        let groupIdentifier = bundle.object(forInfoDictionaryKey: "TLAppGroupIdentifier") as? String
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
    func deliverSharedItems() async -> Int {
        let items = await shareOutbox.deliver(using: share, sessions: sessions)
        if !items.isEmpty {
            logger.info("Delivered \(items.count) shared item(s)")
        }
        return items.count
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
