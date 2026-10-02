import Foundation
import TLDomain
import TLFoundation
import UniformTypeIdentifiers

/// One thing another app shared with TaskLens, loaded and normalized.
public struct SharedAttachment: Sendable, Identifiable {
    public enum Payload: Sendable {
        case text(String)
        case url(URL)
        /// A copy of the shared file in the intake's temporary folder.
        case file(URL, type: UTType, filename: String, byteCount: Int64)
        case unsupported(UnsupportedReason, typeIdentifiers: [String])
    }

    public enum UnsupportedReason: String, Sendable {
        /// No representation TaskLens understands.
        case type
        case tooLarge
        /// The provider failed to deliver its data.
        case unreadable
        /// More than `ShareIntake.maximumAttachments` were shared.
        case tooMany
    }

    public let id: UUID
    public let payload: Payload

    public init(id: UUID = UUID(), payload: Payload) {
        self.id = id
        self.payload = payload
    }

    public var isSupported: Bool {
        if case .unsupported = payload { return false }
        return true
    }
}

/// Loads `NSItemProvider`s from a share sheet into `SharedAttachment`s.
///
/// Files are streamed to disk with `loadFileRepresentation` and never held in
/// memory, which keeps the share extension well under its memory limit.
/// Loading never throws: anything unusable becomes `.unsupported`, so one bad
/// item cannot break the share.
@MainActor
public enum ShareIntake {
    public static let maximumAttachments = 10
    public static let maximumTextLength = ContextItem.maximumTextLength

    /// Loads providers in order. Stops early (returning what was loaded) if the task is cancelled.
    public static func load(_ providers: [NSItemProvider], into directory: URL) async -> [SharedAttachment] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var attachments: [SharedAttachment] = []
        for (index, provider) in providers.enumerated() {
            if Task.isCancelled { break }
            if index >= maximumAttachments {
                attachments.append(SharedAttachment(payload: .unsupported(.tooMany, typeIdentifiers: provider.registeredTypeIdentifiers)))
                continue
            }
            attachments.append(await load(provider, into: directory))
        }
        return attachments
    }

    /// Attachments of all extension items, flattened.
    public static func providers(in items: [NSExtensionItem]) -> [NSItemProvider] {
        items.flatMap { $0.attachments ?? [] }
    }

    static func load(_ provider: NSItemProvider, into directory: URL) async -> SharedAttachment {
        let identifiers = provider.registeredTypeIdentifiers
        let types = identifiers.compactMap(UTType.init)
        func unsupported(_ reason: SharedAttachment.UnsupportedReason) -> SharedAttachment {
            SharedAttachment(payload: .unsupported(reason, typeIdentifiers: identifiers))
        }

        do {
            // 1. PDFs and images are always files.
            if let type = types.first(where: { $0.conforms(to: .pdf) || $0.conforms(to: .image) }) {
                return SharedAttachment(payload: try await copyFile(provider, type: type, into: directory))
            }
            // 2. Web links.
            if types.contains(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }),
               let url = try await loadURL(provider), !url.isFileURL {
                return SharedAttachment(payload: .url(url))
            }
            // 3. Plain text.
            if types.contains(where: { $0.conforms(to: .plainText) }), let text = try? await loadText(provider) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return unsupported(.unreadable) }
                if trimmed.count > maximumTextLength { return unsupported(.tooLarge) }
                return SharedAttachment(payload: .text(text))
            }
            // 4. Other files TaskLens can open (CSV, JSON, source code...).
            if let type = types.first(where: { DocumentService.kind(for: $0) != nil }) {
                return SharedAttachment(payload: try await copyFile(provider, type: type, into: directory))
            }
            return unsupported(.type)
        } catch let error as IntakeError {
            return unsupported(error == .tooLarge ? .tooLarge : .unreadable)
        } catch {
            return unsupported(.unreadable)
        }
    }

    enum IntakeError: Error, Equatable {
        case tooLarge
        case unreadable
    }

    // MARK: Loading

    private static func loadURL(_ provider: NSItemProvider) async throws -> URL? {
        guard provider.canLoadObject(ofClass: NSURL.self) else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                if let url = (object as? NSURL) as URL? {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? IntakeError.unreadable)
                }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async throws -> String {
        guard provider.canLoadObject(ofClass: NSString.self) else { throw IntakeError.unreadable }
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, error in
                if let string = object as? NSString {
                    continuation.resume(returning: string as String)
                } else {
                    continuation.resume(throwing: error ?? IntakeError.unreadable)
                }
            }
        }
    }

    /// Streams the file into `directory`. The provider's own URL is only valid
    /// inside the callback, so the copy happens there.
    private static func copyFile(_ provider: NSItemProvider, type: UTType, into directory: URL) async throws -> SharedAttachment.Payload {
        let suggestedName = await originalFilename(of: provider)
        let progressBox = ProgressBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                progressBox.progress = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    guard let url else {
                        continuation.resume(throwing: error ?? IntakeError.unreadable)
                        return
                    }
                    do {
                        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                        guard size <= DocumentService.maximumFileSize else { throw IntakeError.tooLarge }
                        let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                        let base = suggestedName.map { ($0 as NSString).deletingPathExtension } ?? url.deletingPathExtension().lastPathComponent
                        let filename = ext.isEmpty ? base : "\(base).\(ext)"
                        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: .file(destination, type: type, filename: filename, byteCount: size))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            progressBox.cancel()
        }
    }

    /// The shared file's own name. The copy handed to `loadFileRepresentation`
    /// can have a generic name ("PDF document.pdf"), so prefer the provider's
    /// suggested name, then the name of its file URL.
    private static func originalFilename(of provider: NSItemProvider) async -> String? {
        if let name = provider.suggestedName, !name.isEmpty { return name }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
              let url = try? await loadURL(provider), url.isFileURL
        else { return nil }
        return url.lastPathComponent
    }

    /// Holds the loading progress so cancellation can stop a large transfer.
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _progress: Progress?
        var progress: Progress? {
            get { lock.withLock { _progress } }
            set { lock.withLock { _progress = newValue } }
        }
        func cancel() { progress?.cancel() }
    }
}

/// Turns shared attachments into previews and saves them as context items.
public struct ShareService: Sendable {
    /// What the share sheet shows for one attachment.
    public struct Preview: Sendable, Identifiable {
        public let attachment: SharedAttachment
        /// Content for text and links. Files get content when saved.
        public let content: ContextContent?
        public let analysis: ContextAnalysis
        public var id: UUID { attachment.id }
        public var isSupported: Bool { attachment.isSupported }
    }

    private let capture: CaptureService
    private let documents: DocumentService

    public init(capture: CaptureService, documents: DocumentService) {
        self.capture = capture
        self.documents = documents
    }

    /// Context Engine + Action Engine for one attachment. Pure and fast.
    public static func preview(for attachment: SharedAttachment) -> Preview {
        switch attachment.payload {
        case .text(let text):
            let content = ContentClassifier.classify(text)
            return Preview(attachment: attachment, content: content, analysis: ActionEngine.analyze(content, context: ActionContext(source: .shareExtension)))
        case .url(let url):
            return Preview(attachment: attachment, content: .url(url), analysis: ActionEngine.analyze(.url(url), context: ActionContext(source: .shareExtension)))
        case .file(_, let type, let filename, let size):
            let kind = DocumentService.kind(for: type) ?? .document
            let reference = FileReference(relativePath: filename, originalFilename: filename,
                                          contentType: type.identifier, kind: kind, byteCount: size)
            return Preview(attachment: attachment, content: nil, analysis: ActionEngine.analyze(.file(reference), context: ActionContext(source: .shareExtension)))
        case .unsupported:
            return Preview(attachment: attachment, content: nil, analysis: ContextAnalysis(category: .unknown, entities: [], actions: []))
        }
    }

    /// Saves every supported preview into a session (or the inbox). Unsupported ones are skipped.
    @discardableResult
    public func save(_ previews: [Preview], into sessionID: SessionID?, workspaceID: WorkspaceID? = nil) async throws -> [ContextItem] {
        var items: [ContextItem] = []
        for preview in previews where preview.isSupported {
            try Task.checkCancellation()
            switch preview.attachment.payload {
            case .text, .url:
                guard let content = preview.content else { continue }
                items.append(try await capture.capture(content, source: .shareExtension, into: sessionID,
                                                       metadata: ["category": .string(preview.analysis.category.rawValue)]))
            case .file(let url, _, let filename, _):
                let document = try await documents.importFile(
                    at: url, filename: filename, workspaceID: workspaceID, sessionID: sessionID
                )
                var output = DocumentService.output(for: document)
                output.source = .shareExtension
                items.append(try await capture.capture(output, into: sessionID))
            case .unsupported:
                continue
            }
        }
        return items
    }
}
