import Foundation
import TLFoundation

public typealias AIRecordID = Identifier<AIRecord>

/// Where an AI request ran.
public struct AIProviderKind: ExtensibleKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Apple Intelligence on this device. Nothing leaves the device.
    public static let onDevice: AIProviderKind = "onDevice"
    /// The AI server the user set up in Settings. Text is sent over the network.
    public static let server: AIProviderKind = "server"
}

/// One AI request the user ran, kept only while "Keep AI history" is on so
/// they can see what was sent and delete it.
public struct AIRecord: Entity {
    public static let entityName = "aiRecord"

    public let id: AIRecordID
    /// The task's raw value ("summarize", "translate", …).
    public var task: String
    public var provider: AIProviderKind
    /// Where it went: "This iPhone" for on-device, the server host otherwise.
    public var destination: String
    /// How many characters were sent.
    public var sentCharacters: Int
    /// The start of what was sent, to recognize the request.
    public var inputPreview: String
    public var output: String
    public let createdAt: Date

    public init(
        id: AIRecordID = AIRecordID(), task: String, provider: AIProviderKind, destination: String,
        sentCharacters: Int, inputPreview: String, output: String, createdAt: Date
    ) {
        self.id = id
        self.task = task
        self.provider = provider
        self.destination = destination
        self.sentCharacters = sentCharacters
        self.inputPreview = inputPreview
        self.output = output
        self.createdAt = createdAt
    }
}
