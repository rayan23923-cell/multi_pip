import Foundation

/// The single error type surfaced across module boundaries.
///
/// It carries no user-facing text. The UI layer maps `localizationKey` to a
/// localized message, so errors stay testable and translatable.
public enum TaskLensError: Error, Equatable, Sendable {
    case notFound(entity: String, id: String)
    case validationFailed(ValidationFailure)
    case invalidState(InvalidStateReason)
    case persistenceFailed(operation: PersistenceOperation, details: String)
    case unsupportedContent(type: String)
    case unavailable(feature: String)
}

public enum ValidationFailure: String, Sendable, Codable, CaseIterable {
    case emptyName
    case nameTooLong
    case emptyContent
    case contentTooLarge
    case invalidURL
}

public enum InvalidStateReason: String, Sendable, Codable, CaseIterable {
    case sessionEnded
    case sessionAlreadyActive
    case workspaceArchived
}

public enum PersistenceOperation: String, Sendable, Codable, CaseIterable {
    case read
    case write
    case delete
    case locateStore
}

extension TaskLensError {
    /// Stable key the UI uses to look up a localized message.
    public var localizationKey: String {
        switch self {
        case .notFound: "error.notFound"
        case .validationFailed(let failure): "error.validation.\(failure.rawValue)"
        case .invalidState(let reason): "error.state.\(reason.rawValue)"
        case .persistenceFailed: "error.persistence"
        case .unsupportedContent: "error.unsupportedContent"
        case .unavailable: "error.unavailable"
        }
    }

    /// Every key `localizationKey` can produce. Used by tests to keep
    /// the string catalog in sync with the error model.
    public static var allLocalizationKeys: [String] {
        var keys = ["error.notFound", "error.persistence", "error.unsupportedContent", "error.unavailable"]
        keys += ValidationFailure.allCases.map { "error.validation.\($0.rawValue)" }
        keys += InvalidStateReason.allCases.map { "error.state.\($0.rawValue)" }
        return keys
    }
}

extension TaskLensError: CustomStringConvertible {
    /// Developer-facing description for logs. Never includes user content.
    public var description: String {
        switch self {
        case .notFound(let entity, let id): "notFound(\(entity), \(id))"
        case .validationFailed(let failure): "validationFailed(\(failure.rawValue))"
        case .invalidState(let reason): "invalidState(\(reason.rawValue))"
        case .persistenceFailed(let operation, let details): "persistenceFailed(\(operation.rawValue)): \(details)"
        case .unsupportedContent(let type): "unsupportedContent(\(type))"
        case .unavailable(let feature): "unavailable(\(feature))"
        }
    }
}
