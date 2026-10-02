import Foundation
import TLFoundation

public typealias ClipboardItemID = Identifier<ClipboardItem>

/// Something the user explicitly pasted into TaskLens.
///
/// iOS does not let apps watch the pasteboard in the background, so clipboard
/// items only exist when the user pastes (e.g. through a paste button).
public struct ClipboardItem: Entity {
    public static let entityName = "clipboardItem"

    public let id: ClipboardItemID
    public var content: ContextContent
    /// Pasteboard type identifiers that were offered, for diagnostics and routing.
    public var offeredTypes: [String]
    public let capturedAt: Date
    /// Set once the user saves this clipboard entry into a session.
    public var promotedItemID: ContextItemID?

    public init(
        id: ClipboardItemID = ClipboardItemID(),
        content: ContextContent,
        offeredTypes: [String] = [],
        capturedAt: Date,
        promotedItemID: ContextItemID? = nil
    ) {
        self.id = id
        self.content = content
        self.offeredTypes = offeredTypes
        self.capturedAt = capturedAt
        self.promotedItemID = promotedItemID
    }
}
