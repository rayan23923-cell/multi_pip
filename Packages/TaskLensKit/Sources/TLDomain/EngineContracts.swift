import Foundation
import TLFoundation

// Boundaries for the intelligence layer. Implementations arrive in later phases
// (Context Engine, Action Engine). Declaring them now lets features and services
// depend on stable contracts instead of concrete engines.

/// Finds entities in a context item (Context Engine).
public protocol EntityDetecting: Sendable {
    func detectEntities(in content: ContextContent) async throws -> [DetectedEntity]
}

/// Suggests actions for a context item and its entities (Action Engine).
public protocol ActionSuggesting: Sendable {
    func suggestActions(for item: ContextItem) async -> [Action]
}

/// Executes an action (Action Engine). UI-bound actions are performed on the main actor.
public protocol ActionPerforming: Sendable {
    @MainActor
    func perform(_ action: Action, on item: ContextItem) async -> ActionResult
}

/// A detector that finds nothing. Used until the Context Engine exists.
public struct NoEntityDetector: EntityDetecting {
    public init() {}
    public func detectEntities(in content: ContextContent) async throws -> [DetectedEntity] { [] }
}
