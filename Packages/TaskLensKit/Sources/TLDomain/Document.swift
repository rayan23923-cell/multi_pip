import Foundation
import TLFoundation

public typealias DocumentID = Identifier<Document>

/// A file the user opened or imported for reading (PDF, image, other document).
public struct Document: Entity {
    public static let entityName = "document"

    public let id: DocumentID
    public var workspaceID: WorkspaceID?
    public var sessionID: SessionID?
    public var title: String
    public var file: FileReference
    public var pageCount: Int?
    /// Zero-based page the user was reading, for resume.
    public var lastReadPage: Int?
    public let createdAt: Date
    public var lastOpenedAt: Date?
    public var metadata: Metadata

    public init(
        id: DocumentID = DocumentID(),
        workspaceID: WorkspaceID? = nil,
        sessionID: SessionID? = nil,
        title: String,
        file: FileReference,
        pageCount: Int? = nil,
        lastReadPage: Int? = nil,
        createdAt: Date,
        lastOpenedAt: Date? = nil,
        metadata: Metadata = [:]
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.title = title
        self.file = file
        self.pageCount = pageCount
        self.lastReadPage = lastReadPage
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.metadata = metadata
    }

    public var kind: FileKind { file.kind }
}
