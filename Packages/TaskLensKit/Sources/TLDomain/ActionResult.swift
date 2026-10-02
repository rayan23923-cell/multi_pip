import Foundation
import TLFoundation

/// What happened when an action ran.
public struct ActionResult: Sendable, Equatable {
    public let actionID: ActionID
    public let actionType: ActionType
    public let outcome: Outcome
    public let completedAt: Date
    /// Items created by the action (e.g. a note or a new context item).
    public let producedItemIDs: [ContextItemID]

    public init(
        actionID: ActionID,
        actionType: ActionType,
        outcome: Outcome,
        completedAt: Date,
        producedItemIDs: [ContextItemID] = []
    ) {
        self.actionID = actionID
        self.actionType = actionType
        self.outcome = outcome
        self.completedAt = completedAt
        self.producedItemIDs = producedItemIDs
    }

    public enum Outcome: Sendable, Equatable {
        case succeeded(output: JSONValue?)
        /// The action handed off to the system (e.g. a call confirmation sheet).
        case handedOff
        case cancelled
        case failed(TaskLensError)
    }

    public var isSuccess: Bool {
        switch outcome {
        case .succeeded, .handedOff: true
        case .cancelled, .failed: false
        }
    }
}
