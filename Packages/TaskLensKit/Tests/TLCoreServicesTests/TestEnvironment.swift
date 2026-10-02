import Foundation
import TLCoreServices
import TLData
import TLDomain
import TLFoundation

/// Wires every service against in-memory repositories and a manual clock.
struct TestEnvironment {
    let clock = ManualDateProvider(Date(timeIntervalSinceReferenceDate: 1_000))
    let repositories = Repositories.inMemory()
    let detector: any EntityDetecting

    init(detector: any EntityDetecting = NoEntityDetector()) {
        self.detector = detector
    }

    var workspaces: WorkspaceService {
        WorkspaceService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            contextItems: repositories.contextItems,
            documents: repositories.documents,
            notes: repositories.notes,
            actionRecords: repositories.actionRecords,
            clock: clock,
            logger: .disabled()
        )
    }

    var sessionContent: SessionContentService {
        SessionContentService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            contextItems: repositories.contextItems,
            notes: repositories.notes,
            actionRecords: repositories.actionRecords,
            clock: clock,
            logger: .disabled()
        )
    }

    var pip: PiPWorkspaceService {
        PiPWorkspaceService(cards: repositories.pipCards, presentation: repositories.pipPresentation, clock: clock, logger: .disabled())
    }

    var sessions: SessionService {
        SessionService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            clock: clock,
            logger: .disabled()
        )
    }

    var capture: CaptureService {
        CaptureService(
            sessions: repositories.sessions,
            contextItems: repositories.contextItems,
            detector: detector,
            clock: clock,
            logger: .disabled()
        )
    }

    var notes: NoteService {
        NoteService(notes: repositories.notes, clock: clock, logger: .disabled())
    }

    func calculator(historyLimit: Int = CalculatorService.defaultHistoryLimit) -> CalculatorService {
        CalculatorService(records: repositories.calculations, clock: clock, historyLimit: historyLimit, logger: .disabled())
    }

    func documents(in directory: URL) -> DocumentService {
        DocumentService(documents: repositories.documents, filesDirectory: directory, clock: clock, logger: .disabled())
    }

    func clipboard(historyLimit: Int = ClipboardService.defaultHistoryLimit) -> ClipboardService {
        ClipboardService(
            clipboardItems: repositories.clipboardItems,
            capture: capture,
            clock: clock,
            historyLimit: historyLimit,
            logger: .disabled()
        )
    }
}

struct StubDetector: EntityDetecting {
    let entities: [DetectedEntity]
    func detectEntities(in content: ContextContent) async throws -> [DetectedEntity] { entities }
}

struct FailingDetector: EntityDetecting {
    func detectEntities(in content: ContextContent) async throws -> [DetectedEntity] {
        throw TaskLensError.unavailable(feature: "detector")
    }
}

enum TemporaryDirectory {
    static func make() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskLensServiceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
