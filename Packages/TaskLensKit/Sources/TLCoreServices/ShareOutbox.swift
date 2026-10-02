import Foundation
import TLDomain
import TLFoundation
import UniformTypeIdentifiers

/// Hand-off folder between the share extension and the app.
///
/// The extension never writes the app's store: the app keeps its stores cached
/// in memory, so a second writer could silently lose data. Instead the
/// extension drops each share here as an envelope (a folder with a manifest and
/// the shared files), and the app saves envelopes into sessions the next time
/// it becomes active.
///
/// An envelope is written to a hidden temporary folder and renamed into place,
/// so the app never sees a half-written share.
public struct ShareOutbox: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The outbox inside a store's root folder.
    public init(storeRoot: URL) {
        self.init(directory: storeRoot.appendingPathComponent("ShareOutbox", isDirectory: true))
    }

    static let manifestName = "manifest.json"

    struct Manifest: Codable {
        var version = 1
        var createdAt: Date
        var sessionID: SessionID?
        var entries: [Entry]
    }

    struct Entry: Codable {
        enum Kind: String, Codable { case text, url, file }
        var kind: Kind
        var text: String?
        var url: URL?
        /// File name inside the envelope.
        var storedName: String?
        var filename: String?
        var typeIdentifier: String?
        var byteCount: Int64?
    }

    // MARK: Extension side

    /// Writes the supported attachments as one envelope. Shared files are moved
    /// (not copied) into it. Returns the number of items queued.
    @discardableResult
    public func enqueue(_ attachments: [SharedAttachment], sessionID: SessionID?, now: Date = Date()) throws -> Int {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString
        let staging = directory.appendingPathComponent(".\(name).tmp", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            var entries: [Entry] = []
            for attachment in attachments {
                switch attachment.payload {
                case .text(let text):
                    entries.append(Entry(kind: .text, text: text))
                case .url(let url):
                    entries.append(Entry(kind: .url, url: url))
                case .file(let source, let type, let filename, let byteCount):
                    let storedName = "\(entries.count)-\(UUID().uuidString)" + (source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)")
                    try fileManager.moveItem(at: source, to: staging.appendingPathComponent(storedName))
                    entries.append(Entry(kind: .file, storedName: storedName, filename: filename,
                                         typeIdentifier: type.identifier, byteCount: byteCount))
                case .unsupported:
                    continue
                }
            }
            guard !entries.isEmpty else {
                try? fileManager.removeItem(at: staging)
                return 0
            }
            let manifest = Manifest(createdAt: now, sessionID: sessionID, entries: entries)
            try Self.encoder.encode(manifest).write(to: staging.appendingPathComponent(Self.manifestName), options: .atomic)
            try fileManager.moveItem(at: staging, to: directory.appendingPathComponent(name, isDirectory: true))
            return entries.count
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    // MARK: App side

    /// Finished envelopes, oldest first. Staging folders are skipped.
    public func pendingEnvelopes() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left < right
            }
    }

    /// Saves every pending envelope. Items go to the session chosen in the
    /// share sheet, or the inbox if that session has ended or was deleted.
    /// Entries that fail to save stay in the outbox for the next attempt.
    /// Returns the saved items.
    @discardableResult
    public func deliver(using service: ShareService, sessions: SessionService) async -> [ContextItem] {
        var saved: [ContextItem] = []
        for envelope in pendingEnvelopes() {
            if Task.isCancelled { break }
            saved += await deliver(envelope, using: service, sessions: sessions)
        }
        return saved
    }

    private func deliver(_ envelope: URL, using service: ShareService, sessions: SessionService) async -> [ContextItem] {
        let fileManager = FileManager.default
        let manifestURL = envelope.appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? Self.decoder.decode(Manifest.self, from: data)
        else {
            // Unreadable envelope: nothing can be recovered from it.
            try? fileManager.removeItem(at: envelope)
            return []
        }

        var sessionID = manifest.sessionID
        var workspaceID: WorkspaceID?
        if let id = sessionID {
            if let session = try? await sessions.session(id: id), session.isActive {
                workspaceID = session.workspaceID
            } else {
                sessionID = nil
            }
        }

        var saved: [ContextItem] = []
        var remaining: [Entry] = []
        for entry in manifest.entries {
            guard let attachment = attachment(for: entry, in: envelope) else { continue }
            let preview = ShareService.preview(for: attachment)
            do {
                saved += try await service.save([preview], into: sessionID, workspaceID: workspaceID)
            } catch {
                remaining.append(entry)
            }
        }

        if remaining.isEmpty {
            try? fileManager.removeItem(at: envelope)
        } else {
            manifest.entries = remaining
            if let data = try? Self.encoder.encode(manifest) {
                try? data.write(to: manifestURL, options: .atomic)
            }
        }
        return saved
    }

    private func attachment(for entry: Entry, in envelope: URL) -> SharedAttachment? {
        switch entry.kind {
        case .text:
            return entry.text.map { SharedAttachment(payload: .text($0)) }
        case .url:
            return entry.url.map { SharedAttachment(payload: .url($0)) }
        case .file:
            guard let storedName = entry.storedName else { return nil }
            let url = envelope.appendingPathComponent(storedName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let type = entry.typeIdentifier.flatMap(UTType.init) ?? .data
            return SharedAttachment(payload: .file(url, type: type, filename: entry.filename ?? storedName,
                                                   byteCount: entry.byteCount ?? 0))
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
