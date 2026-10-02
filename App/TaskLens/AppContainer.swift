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
    let storage: SettingsView.StorageDescription
    let logger: TLLogger

    init(
        repositories: Repositories,
        storage: SettingsView.StorageDescription,
        clock: any DateProviding = SystemDateProvider(),
        logger: TLLogger = TLLogger(category: "app")
    ) {
        let capture = CaptureService(
            sessions: repositories.sessions,
            contextItems: repositories.contextItems,
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
        self.storage = storage
        self.logger = logger
    }

    /// Persistent container for the running app. Falls back to memory if the
    /// store cannot be opened, so the app still launches and the user is told
    /// (in Settings) that data is temporary.
    static func live(bundle: Bundle = .main) -> AppContainer {
        let logger = TLLogger(category: "app")
        let groupIdentifier = bundle.object(forInfoDictionaryKey: "TLAppGroupIdentifier") as? String
        do {
            let location = try StoreLocation.resolve(appGroupIdentifier: groupIdentifier, logger: logger)
            let repositories = try Repositories.fileBacked(at: location, logger: logger.scoped("persistence"))
            logger.info("Store opened (\(location.kind.rawValue))")
            return AppContainer(
                repositories: repositories,
                storage: location.kind == .appGroup ? .appGroup : .local,
                logger: logger
            )
        } catch {
            logger.fault("Falling back to in-memory store: \(error)")
            return AppContainer(repositories: .inMemory(), storage: .memory, logger: logger)
        }
    }

    static func preview() -> AppContainer {
        AppContainer(repositories: .inMemory(), storage: .memory, logger: .disabled())
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
