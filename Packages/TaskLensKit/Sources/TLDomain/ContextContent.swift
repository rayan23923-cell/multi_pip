import Foundation
import TLFoundation

/// The payload of something the user gave to TaskLens.
public enum ContextContent: Codable, Sendable, Hashable {
    case text(String)
    case url(URL)
    case file(FileReference)

    public var itemType: ContextItemType {
        switch self {
        case .text: .text
        case .url: .url
        case .file(let reference): reference.kind.itemType
        }
    }

    /// Short, non-sensitive description for logs (type and size only).
    public var logDescription: String {
        switch self {
        case .text(let text): "text(\(text.count) chars)"
        case .url: "url"
        case .file(let reference): "file(\(reference.kind.rawValue), \(reference.byteCount ?? -1) bytes)"
        }
    }
}

/// A file stored in the shared container. `relativePath` is relative to the
/// store's files directory so the container can move without breaking links.
public struct FileReference: Codable, Sendable, Hashable {
    public var relativePath: String
    public var originalFilename: String?
    /// Uniform Type Identifier, e.g. `com.adobe.pdf`.
    public var contentType: String
    public var kind: FileKind
    public var byteCount: Int64?

    public init(
        relativePath: String,
        originalFilename: String? = nil,
        contentType: String,
        kind: FileKind,
        byteCount: Int64? = nil
    ) {
        self.relativePath = relativePath
        self.originalFilename = originalFilename
        self.contentType = contentType
        self.kind = kind
        self.byteCount = byteCount
    }
}

public enum FileKind: String, Codable, Sendable, CaseIterable {
    case image
    case pdf
    /// Plain text files (.txt, .md, .csv, source code...).
    case text
    case document
    /// PowerPoint presentations (.pptx).
    case powerpoint

    var itemType: ContextItemType {
        switch self {
        case .image: .image
        case .pdf: .pdf
        case .text, .document, .powerpoint: .document
        }
    }
}
