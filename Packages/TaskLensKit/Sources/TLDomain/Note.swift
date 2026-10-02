import Foundation
import TLFoundation

public typealias NoteID = Identifier<Note>

public struct Note: Entity {
    public static let entityName = "note"

    public let id: NoteID
    public var workspaceID: WorkspaceID?
    public var sessionID: SessionID?
    public var title: String
    public var body: String
    public var isPinned: Bool
    /// Context items this note was created from or refers to.
    public var linkedItemIDs: [ContextItemID]
    public let createdAt: Date
    public var updatedAt: Date
    public var metadata: Metadata

    public init(
        id: NoteID = NoteID(),
        workspaceID: WorkspaceID? = nil,
        sessionID: SessionID? = nil,
        title: String = "",
        body: String = "",
        isPinned: Bool = false,
        linkedItemIDs: [ContextItemID] = [],
        createdAt: Date,
        updatedAt: Date? = nil,
        metadata: Metadata = [:]
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.title = title
        self.body = body
        self.isPinned = isPinned
        self.linkedItemIDs = linkedItemIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.metadata = metadata
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
