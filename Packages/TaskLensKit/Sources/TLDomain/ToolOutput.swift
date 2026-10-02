import Foundation
import TLFoundation

/// Content a tool hands to the CONTENT → CONTEXT pipeline.
///
/// Every tool (notes, calculator, browser, viewers) describes what it can
/// contribute as a `ToolOutput`. `CaptureService` turns it into a stored
/// `ContextItem`, so all tools feed sessions and the Action Engine the same way.
public struct ToolOutput: Sendable, Hashable {
    public var tool: WorkspaceTool
    public var source: ContextSource
    public var content: ContextContent
    public var metadata: Metadata

    public init(tool: WorkspaceTool, source: ContextSource, content: ContextContent, metadata: Metadata = [:]) {
        self.tool = tool
        self.source = source
        self.content = content
        self.metadata = metadata
    }

    /// Metadata key holding the producing tool's raw value.
    public static let toolMetadataKey = "tool"

    /// Metadata stored on the resulting context item, including the tool name.
    public var itemMetadata: Metadata {
        var merged = metadata
        merged[Self.toolMetadataKey] = .string(tool.rawValue)
        return merged
    }
}

/// A tool screen model that can describe its current content as a `ToolOutput`.
@MainActor
public protocol ContextProducing: AnyObject {
    /// What the tool would save right now, or `nil` when there is nothing to save.
    var toolOutput: ToolOutput? { get }
}
