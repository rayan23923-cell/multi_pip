import Foundation
import TLFoundation

/// The last place the user was in a TaskLens tool during a session.
///
/// Only TaskLens's own state is kept: which tool, which page or document, which
/// link. Other apps cannot be returned to an earlier screen, and TaskLens
/// does not pretend to.
public struct SessionResumeState: Codable, Sendable, Hashable {
    public var tool: WorkspaceTool
    /// The page open in the in-app browser.
    public var url: URL?
    /// The document open in a viewer, and its page when it has pages.
    public var documentID: DocumentID?
    public var page: Int?
    public var noteID: NoteID?
    public var updatedAt: Date

    public init(
        tool: WorkspaceTool,
        url: URL? = nil,
        documentID: DocumentID? = nil,
        page: Int? = nil,
        noteID: NoteID? = nil,
        updatedAt: Date
    ) {
        self.tool = tool
        self.url = url
        self.documentID = documentID
        self.page = page
        self.noteID = noteID
        self.updatedAt = updatedAt
    }
}
