import Foundation
import TLDomain
import TLFoundation

/// The full set of repositories the app needs, behind protocol types.
public struct Repositories: Sendable {
    public let workspaces: any Repository<Workspace>
    public let sessions: any Repository<Session>
    public let contextItems: any Repository<ContextItem>
    public let documents: any Repository<Document>
    public let notes: any Repository<Note>
    public let clipboardItems: any Repository<ClipboardItem>
    public let calculations: any Repository<CalculationRecord>
    public let actionRecords: any Repository<ActionRecord>
    public let pipCards: any Repository<PiPCard>
    public let pipPresentation: any Repository<PiPPresentation>
    /// AI requests, kept only while the user keeps AI history.
    public let aiRecords: any Repository<AIRecord>

    public init(
        workspaces: any Repository<Workspace>,
        sessions: any Repository<Session>,
        contextItems: any Repository<ContextItem>,
        documents: any Repository<Document>,
        notes: any Repository<Note>,
        clipboardItems: any Repository<ClipboardItem>,
        calculations: any Repository<CalculationRecord> = InMemoryRepository<CalculationRecord>(),
        actionRecords: any Repository<ActionRecord> = InMemoryRepository<ActionRecord>(),
        pipCards: any Repository<PiPCard> = InMemoryRepository<PiPCard>(),
        pipPresentation: any Repository<PiPPresentation> = InMemoryRepository<PiPPresentation>(),
        aiRecords: any Repository<AIRecord> = InMemoryRepository<AIRecord>()
    ) {
        self.workspaces = workspaces
        self.sessions = sessions
        self.contextItems = contextItems
        self.documents = documents
        self.notes = notes
        self.clipboardItems = clipboardItems
        self.calculations = calculations
        self.actionRecords = actionRecords
        self.pipCards = pipCards
        self.pipPresentation = pipPresentation
        self.aiRecords = aiRecords
    }

    public static func inMemory() -> Repositories {
        Repositories(
            workspaces: InMemoryRepository<Workspace>(),
            sessions: InMemoryRepository<Session>(),
            contextItems: InMemoryRepository<ContextItem>(),
            documents: InMemoryRepository<Document>(),
            notes: InMemoryRepository<Note>(),
            clipboardItems: InMemoryRepository<ClipboardItem>(),
            calculations: InMemoryRepository<CalculationRecord>(),
            actionRecords: InMemoryRepository<ActionRecord>(),
            pipCards: InMemoryRepository<PiPCard>(),
            pipPresentation: InMemoryRepository<PiPPresentation>(),
            aiRecords: InMemoryRepository<AIRecord>()
        )
    }

    public static func fileBacked(
        at location: StoreLocation,
        logger: TLLogger = TLLogger(category: "persistence")
    ) throws -> Repositories {
        try location.prepareDirectories()
        let directory = location.dataDirectory
        return Repositories(
            workspaces: JSONFileRepository<Workspace>(directory: directory, logger: logger),
            sessions: JSONFileRepository<Session>(directory: directory, logger: logger),
            contextItems: JSONFileRepository<ContextItem>(directory: directory, logger: logger),
            documents: JSONFileRepository<Document>(directory: directory, logger: logger),
            notes: JSONFileRepository<Note>(directory: directory, logger: logger),
            clipboardItems: JSONFileRepository<ClipboardItem>(directory: directory, logger: logger),
            calculations: JSONFileRepository<CalculationRecord>(directory: directory, logger: logger),
            actionRecords: JSONFileRepository<ActionRecord>(directory: directory, logger: logger),
            pipCards: JSONFileRepository<PiPCard>(directory: directory, logger: logger),
            pipPresentation: JSONFileRepository<PiPPresentation>(directory: directory, logger: logger),
            aiRecords: JSONFileRepository<AIRecord>(directory: directory, logger: logger)
        )
    }
}
