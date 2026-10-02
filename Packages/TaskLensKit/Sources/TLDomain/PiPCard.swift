import Foundation
import TLFoundation

public typealias PiPCardID = Identifier<PiPCard>

/// Something the user keeps in view in Picture in Picture: a note, a document
/// page, a calculation or a piece of context.
///
/// iOS shows Picture in Picture as video. TaskLens draws the card into video
/// frames, so the window is read-only: it can be moved, resized, paged with
/// the system skip buttons, or tapped to return to TaskLens. It is not an
/// overlay that can be typed into, and it cannot show other apps' content.
public struct PiPCard: Entity {
    public static let entityName = "pipCard"
    /// Longest body kept. A Picture in Picture window is small; more is never readable.
    public static let maximumBodyLength = 600
    public static let maximumTitleLength = 120

    public let id: PiPCardID
    public var kind: Kind
    public var title: String
    public var body: String
    /// A short line under the body: "= 375", a host name.
    public var detail: String?
    /// Where the card came from, to open it again (Restore).
    public var origin: Origin
    public var workspaceID: WorkspaceID?
    public var position: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: PiPCardID = PiPCardID(),
        kind: Kind,
        title: String,
        body: String,
        detail: String? = nil,
        origin: Origin = Origin(),
        workspaceID: WorkspaceID? = nil,
        position: Int = 0,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = String(title.prefix(Self.maximumTitleLength))
        self.body = String(body.prefix(Self.maximumBodyLength))
        self.detail = detail.map { String($0.prefix(Self.maximumTitleLength)) }
        self.origin = origin
        self.workspaceID = workspaceID
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case note
        case document
        case calculation
        /// Text, a link or a detected value from Lens, the clipboard or a session.
        case context
    }

    /// What the card shows, so the same thing is not added twice and Restore
    /// can open it again.
    public struct Origin: Codable, Sendable, Hashable {
        public var noteID: NoteID?
        public var documentID: DocumentID?
        /// Zero-based page of a document.
        public var page: Int?
        public var itemID: ContextItemID?
        public var sessionID: SessionID?
        public var url: URL?

        public init(
            noteID: NoteID? = nil,
            documentID: DocumentID? = nil,
            page: Int? = nil,
            itemID: ContextItemID? = nil,
            sessionID: SessionID? = nil,
            url: URL? = nil
        ) {
            self.noteID = noteID
            self.documentID = documentID
            self.page = page
            self.itemID = itemID
            self.sessionID = sessionID
            self.url = url
        }

        /// Whether two cards show the same thing (the same note, the same page).
        public func matches(_ other: Origin) -> Bool {
            if let noteID { return noteID == other.noteID }
            if let documentID { return documentID == other.documentID && page == other.page }
            if let itemID { return itemID == other.itemID }
            return false
        }
    }
}

/// The Picture in Picture state that outlives the app: which card is shown
/// and whether Picture in Picture was running. There is one.
public struct PiPPresentation: Entity {
    public static let entityName = "pipPresentation"
    /// The only record's id.
    public static let sharedID = PiPPresentationID(UUID(uuidString: "6D1C2B4A-0F4E-4C55-9A57-2E0C5B6F7A01")!)

    public let id: PiPPresentationID
    public var currentCardID: PiPCardID?
    /// True between start and stop. Still true at launch means the app was
    /// closed while Picture in Picture was running; iOS ended it with the app.
    public var isRunning: Bool
    public var startedAt: Date?
    public var stoppedAt: Date?
    public var stopReason: StopReason?

    public init(
        currentCardID: PiPCardID? = nil,
        isRunning: Bool = false,
        startedAt: Date? = nil,
        stoppedAt: Date? = nil,
        stopReason: StopReason? = nil
    ) {
        self.id = Self.sharedID
        self.currentCardID = currentCardID
        self.isRunning = isRunning
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.stopReason = stopReason
    }

    public enum StopReason: String, Codable, Sendable, CaseIterable {
        /// Closed with the stop button, in TaskLens or in the window.
        case user
        /// The user tapped the window to return to TaskLens.
        case restored
        /// iOS stopped it: a call, another app's Picture in Picture or video.
        case interrupted
        /// The video frames could not be shown.
        case failed
        /// TaskLens was closed while it ran. Found at the next launch.
        case appClosed
    }
}

public typealias PiPPresentationID = Identifier<PiPPresentation>
