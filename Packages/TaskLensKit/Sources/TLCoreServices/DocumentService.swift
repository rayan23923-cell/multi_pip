import Foundation
import TLDomain
import TLFoundation
import UniformTypeIdentifiers

/// Imports, lists and removes documents the user opened in TaskLens (PDF, images, text).
///
/// Files are copied into the store's files directory, so a document keeps
/// working after the original is moved or deleted, and never leaves the device.
public struct DocumentService: Sendable {
    /// Larger files are rejected to protect storage and memory on older devices.
    public static let maximumFileSize: Int64 = 200 * 1024 * 1024
    /// The text viewer shows at most this many characters.
    public static let maximumDisplayedTextLength = 500_000
    static let folderName = "Documents"

    private let documentStore: any Repository<Document>
    private let filesDirectory: URL
    private let clock: any DateProviding
    private let logger: TLLogger

    public init(
        documents: any Repository<Document>,
        filesDirectory: URL,
        clock: any DateProviding = SystemDateProvider(),
        logger: TLLogger = TLLogger(category: "documents")
    ) {
        self.documentStore = documents
        self.filesDirectory = filesDirectory
        self.clock = clock
        self.logger = logger
    }

    // MARK: Queries

    /// Documents in a workspace (or every document with `nil`), most recently opened first.
    public func documents(in workspaceID: WorkspaceID?) async throws -> [Document] {
        let all: [Document]
        if let workspaceID {
            all = try await documentStore.fetchAll(where: { $0.workspaceID == workspaceID })
        } else {
            all = try await documentStore.fetchAll()
        }
        return all.sorted { ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt) }
    }

    public func document(id: DocumentID) async throws -> Document {
        try await documentStore.require(id: id)
    }

    public func fileURL(for document: Document) -> URL {
        filesDirectory.appendingPathComponent(document.file.relativePath)
    }

    // MARK: Import

    /// Copies a file the user picked. The caller handles security-scoped access.
    @discardableResult
    public func importFile(
        at sourceURL: URL,
        workspaceID: WorkspaceID? = nil,
        sessionID: SessionID? = nil
    ) async throws -> Document {
        let filename = sourceURL.lastPathComponent
        let type = (try? sourceURL.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: sourceURL.pathExtension)
        let data: Data
        do {
            let size = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard size <= Self.maximumFileSize else { throw TaskLensError.validationFailed(.contentTooLarge) }
            data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        } catch let error as TaskLensError {
            throw error
        } catch {
            throw TaskLensError.persistenceFailed(operation: .read, details: "\(error)")
        }
        return try await importData(data, filename: filename, contentType: type, workspaceID: workspaceID, sessionID: sessionID)
    }

    /// Stores raw data (e.g. a photo from the photo picker) as a document.
    @discardableResult
    public func importData(
        _ data: Data,
        filename: String,
        contentType: UTType?,
        workspaceID: WorkspaceID? = nil,
        sessionID: SessionID? = nil
    ) async throws -> Document {
        let type = contentType ?? UTType(filenameExtension: (filename as NSString).pathExtension)
        guard let type, let kind = Self.kind(for: type) else {
            throw TaskLensError.unsupportedContent(type: contentType?.identifier ?? "unknown")
        }
        guard !data.isEmpty else { throw TaskLensError.validationFailed(.emptyContent) }
        guard Int64(data.count) <= Self.maximumFileSize else { throw TaskLensError.validationFailed(.contentTooLarge) }

        let fileExtension = type.preferredFilenameExtension ?? (filename as NSString).pathExtension
        let storedName = UUID().uuidString + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        let relativePath = Self.folderName + "/" + storedName
        let destination = filesDirectory.appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            #if os(iOS)
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: destination, options: .atomic)
            #endif
        } catch {
            throw TaskLensError.persistenceFailed(operation: .write, details: "\(error)")
        }

        let title = Self.title(fromFilename: filename)
        let document = Document(
            workspaceID: workspaceID,
            sessionID: sessionID,
            title: title,
            file: FileReference(
                relativePath: relativePath,
                originalFilename: filename,
                contentType: type.identifier,
                kind: kind,
                byteCount: Int64(data.count)
            ),
            createdAt: clock.now()
        )
        do {
            try await documentStore.upsert(document)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        logger.info("Imported document \(document.id) kind=\(kind.rawValue) bytes=\(data.count)")
        return document
    }

    // MARK: Updates

    @discardableResult
    public func markOpened(_ id: DocumentID, pageCount: Int? = nil) async throws -> Document {
        var document = try await documentStore.require(id: id)
        document.lastOpenedAt = clock.now()
        if let pageCount { document.pageCount = pageCount }
        try await documentStore.upsert(document)
        return document
    }

    /// Remembers the zero-based page being read, for resume.
    @discardableResult
    public func setLastReadPage(_ id: DocumentID, page: Int) async throws -> Document {
        var document = try await documentStore.require(id: id)
        var page = max(page, 0)
        if let count = document.pageCount, count > 0 { page = min(page, count - 1) }
        document.lastReadPage = page
        try await documentStore.upsert(document)
        return document
    }

    /// Links a document to a session (and that session's workspace).
    @discardableResult
    public func attach(_ id: DocumentID, to session: Session) async throws -> Document {
        var document = try await documentStore.require(id: id)
        document.sessionID = session.id
        document.workspaceID = session.workspaceID
        try await documentStore.upsert(document)
        return document
    }

    /// Deletes the record and its stored file.
    public func delete(_ id: DocumentID) async throws {
        let document = try await documentStore.require(id: id)
        try await documentStore.delete(id: id)
        do {
            try FileManager.default.removeItem(at: fileURL(for: document))
        } catch {
            // The record is gone; a missing file is not worth failing the delete.
            logger.warning("Could not remove file for document \(id): \(error)")
        }
    }

    /// Deletes stored files no document refers to any more, e.g. after a
    /// workspace and its documents were deleted. Returns how many were removed.
    /// Files newer than `minimumAge` are kept, so an import in progress
    /// (file written, record not yet saved) is never touched.
    @discardableResult
    public func removeOrphanedFiles(minimumAge: TimeInterval = 60) async throws -> Int {
        let folder = filesDirectory.appendingPathComponent(Self.folderName, isDirectory: true)
        guard let stored = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        let referenced = Set(try await documentStore.fetchAll().map { ($0.file.relativePath as NSString).lastPathComponent })
        var removed = 0
        let cutoff = clock.now().addingTimeInterval(-minimumAge)
        for name in stored where !referenced.contains(name) {
            let url = folder.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard modified <= cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        if removed > 0 { logger.info("Removed \(removed) orphaned files") }
        return removed
    }

    // MARK: Reading

    public struct TextContent: Sendable, Equatable {
        public let text: String
        /// True when the file was longer than `maximumDisplayedTextLength`.
        public let isTruncated: Bool
    }

    /// Reads a text document, trying UTF-8 first and then detecting the encoding.
    public func readText(of document: Document) throws -> TextContent {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(for: document), options: .mappedIfSafe)
        } catch {
            throw TaskLensError.persistenceFailed(operation: .read, details: "\(error)")
        }
        guard let text = Self.decodeText(data) else {
            throw TaskLensError.unsupportedContent(type: document.file.contentType)
        }
        if text.count > Self.maximumDisplayedTextLength {
            return TextContent(text: String(text.prefix(Self.maximumDisplayedTextLength)), isTruncated: true)
        }
        return TextContent(text: text, isTruncated: false)
    }

    static func decodeText(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        #if canImport(Darwin)
        var converted: NSString?
        var lossy = ObjCBool(false)
        let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: &lossy)
        if encoding != 0, let converted { return converted as String }
        #endif
        return nil
    }

    // MARK: Context

    /// The whole document as a context item payload.
    public static func output(for document: Document) -> ToolOutput {
        ToolOutput(
            tool: .documents,
            source: source(for: document.kind),
            content: .file(document.file),
            metadata: ["title": .string(document.title), "documentID": .string(document.id.description)]
        )
    }

    /// Text taken from a document (a PDF page, a selection, a text file).
    public static func textOutput(_ text: String, from document: Document, page: Int? = nil) -> ToolOutput {
        var metadata: Metadata = ["title": .string(document.title), "documentID": .string(document.id.description)]
        if let page { metadata["page"] = .number(Double(page + 1)) }
        let limited = String(text.prefix(ContextItem.maximumTextLength))
        return ToolOutput(tool: .documents, source: source(for: document.kind), content: .text(limited), metadata: metadata)
    }

    static func source(for kind: FileKind) -> ContextSource {
        switch kind {
        case .image: .imageViewer
        case .text: .textViewer
        case .pdf, .document: .documentViewer
        }
    }

    // MARK: Types

    /// Supported content: PDF, images and plain text (including source code, CSV, JSON).
    public static func kind(for type: UTType) -> FileKind? {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) || type.conforms(to: .commaSeparatedText)
            || type.conforms(to: .json) || type.conforms(to: .xml) {
            return .text
        }
        return nil
    }

    /// Content types offered in the file picker.
    public static let importableTypes: [UTType] = [.pdf, .image, .plainText, .sourceCode, .commaSeparatedText, .json, .xml]

    static func title(fromFilename filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? filename : base
    }
}
