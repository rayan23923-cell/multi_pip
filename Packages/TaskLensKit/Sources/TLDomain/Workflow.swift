import Foundation
import TLFoundation

public typealias WorkflowID = Identifier<Workflow>

/// A user-defined pipeline: Trigger → Input → Detection → Actions → Result.
/// Example: "When I share a URL → Save to Research".
public struct Workflow: Entity {
    public static let entityName = "workflow"

    public let id: WorkflowID
    public var name: String
    public var trigger: WorkflowTrigger
    public var steps: [WorkflowStep]
    /// Disabled workflows never run, not even from a share.
    public var isEnabled: Bool
    public let createdAt: Date
    public var updatedAt: Date
    public var lastRunAt: Date?

    public init(
        id: WorkflowID = WorkflowID(),
        name: String,
        trigger: WorkflowTrigger,
        steps: [WorkflowStep],
        isEnabled: Bool = true,
        createdAt: Date,
        updatedAt: Date? = nil,
        lastRunAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.steps = steps
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastRunAt = lastRunAt
    }

    /// True when a step may send content to an AI server or otherwise needs
    /// the user's word first. Such workflows never run without confirmation.
    public var isSensitive: Bool { steps.contains { $0.kind.isSensitive } }
}

/// What starts a workflow.
public struct WorkflowTrigger: ExtensibleKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Only from the Run button.
    public static let manual: WorkflowTrigger = "manual"
    /// A link shared to TaskLens.
    public static let sharedURL: WorkflowTrigger = "sharedURL"
    /// An image shared to TaskLens.
    public static let sharedImage: WorkflowTrigger = "sharedImage"
    /// Text shared to TaskLens.
    public static let sharedText: WorkflowTrigger = "sharedText"
    /// A PDF shared to TaskLens.
    public static let sharedPDF: WorkflowTrigger = "sharedPDF"
    /// Shared text that contains an amount of money.
    public static let currency: WorkflowTrigger = "currency"

    public static let all: [WorkflowTrigger] = [.manual, .sharedURL, .sharedImage, .sharedText, .sharedPDF, .currency]
}

/// One action in a workflow.
public struct WorkflowStep: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: WorkflowStepKind
    /// Step options: a target currency and rate, a workspace name, a language.
    public var parameters: [String: String]

    public init(id: UUID = UUID(), kind: WorkflowStepKind, parameters: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.parameters = parameters
    }

    public enum ParameterKey {
        public static let workspace = "workspace"
        public static let currency = "currency"
        public static let rate = "rate"
        public static let language = "language"
    }
}

public struct WorkflowStepKind: ExtensibleKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Read the text in an image (on device).
    public static let recognizeText: WorkflowStepKind = "recognizeText"
    /// Find links, prices, phones, dates (on device).
    public static let extract: WorkflowStepKind = "extract"
    /// Convert an amount with the rate the user entered.
    public static let convertCurrency: WorkflowStepKind = "convertCurrency"
    /// Work out a calculation and keep it in the calculator history.
    public static let calculate: WorkflowStepKind = "calculate"
    /// Save to a workspace's active session (or the inbox).
    public static let save: WorkflowStepKind = "save"
    /// Create a note with the result.
    public static let createNote: WorkflowStepKind = "createNote"
    /// AI: summarize, translate, or turn into notes.
    public static let summarize: WorkflowStepKind = "summarize"
    public static let translate: WorkflowStepKind = "translate"
    public static let generateNotes: WorkflowStepKind = "generateNotes"

    public static let all: [WorkflowStepKind] = [
        .recognizeText, .extract, .convertCurrency, .calculate, .summarize, .translate, .generateNotes, .createNote, .save,
    ]

    /// AI steps may send text to the AI server the user set up.
    public var usesAI: Bool { [.summarize, .translate, .generateNotes].contains(self) }
    public var isSensitive: Bool { usesAI }
}
