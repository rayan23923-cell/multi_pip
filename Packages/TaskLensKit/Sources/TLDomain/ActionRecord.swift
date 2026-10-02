import Foundation
import TLFoundation

public typealias ActionRecordID = Identifier<ActionRecord>

/// An action the user ran on something in a session, and how it ended.
/// Kept on device so a session shows what was done, not only what was saved.
public struct ActionRecord: Entity {
    public static let entityName = "actionRecord"
    /// Longest `detail` kept; longer values are cut.
    public static let maximumDetailLength = 200

    public let id: ActionRecordID
    public let sessionID: SessionID
    public var itemID: ContextItemID?
    public var actionType: ActionType
    public var outcome: Outcome
    /// What the action worked on or produced ("+9647701234567", "= 375").
    public var detail: String?
    public let performedAt: Date

    public init(
        id: ActionRecordID = ActionRecordID(),
        sessionID: SessionID,
        itemID: ContextItemID? = nil,
        actionType: ActionType,
        outcome: Outcome,
        detail: String? = nil,
        performedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.itemID = itemID
        self.actionType = actionType
        self.outcome = outcome
        self.detail = detail.map { String($0.prefix(Self.maximumDetailLength)) }
        self.performedAt = performedAt
    }

    public enum Outcome: String, Codable, Sendable, CaseIterable {
        /// Done inside TaskLens (copied, saved, note created).
        case completed
        /// Handed to the system or another app (call, maps, calendar editor).
        case handedOff
        case failed
    }
}
