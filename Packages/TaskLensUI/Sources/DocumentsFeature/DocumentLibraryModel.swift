import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization
import UniformTypeIdentifiers

/// Documents imported into a workspace (or all documents with `nil`).
@MainActor
@Observable
public final class DocumentLibraryModel {
    public let workspaceID: WorkspaceID?
    public private(set) var documents: [Document] = []
    public private(set) var hasLoaded = false
    public private(set) var isImporting = false
    public var errorMessage: String?

    private let documentService: DocumentService
    private let sessionService: SessionService

    public init(workspaceID: WorkspaceID?, documentService: DocumentService, sessionService: SessionService) {
        self.workspaceID = workspaceID
        self.documentService = documentService
        self.sessionService = sessionService
    }

    public func load() async {
        do {
            documents = try await documentService.documents(in: workspaceID)
            hasLoaded = true
            // Clean up files left behind by deleted workspaces.
            try? await documentService.removeOrphanedFiles()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    /// Imports files picked in the Files app. Returns the imported documents.
    @discardableResult
    public func importFiles(_ urls: [URL]) async -> [Document] {
        isImporting = true
        defer { isImporting = false }
        let sessionID = await targetSessionID()
        var imported: [Document] = []
        for url in urls {
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            do {
                imported.append(try await documentService.importFile(at: url, workspaceID: workspaceID, sessionID: sessionID))
            } catch {
                errorMessage = L10n.message(for: error)
            }
        }
        if !imported.isEmpty { await load() }
        return imported
    }

    /// Imports raw data, e.g. a photo from the photo picker.
    @discardableResult
    public func importData(_ data: Data, filename: String, contentType: UTType?) async -> Document? {
        isImporting = true
        defer { isImporting = false }
        do {
            let document = try await documentService.importData(
                data, filename: filename, contentType: contentType,
                workspaceID: workspaceID, sessionID: await targetSessionID()
            )
            await load()
            return document
        } catch {
            errorMessage = L10n.message(for: error)
            return nil
        }
    }

    public func delete(_ id: DocumentID) async {
        do {
            try await documentService.delete(id)
            documents.removeAll { $0.id == id }
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    /// The workspace's active session, so imports show up in what the user is working on.
    private func targetSessionID() async -> SessionID? {
        guard let workspaceID else { return nil }
        return try? await sessionService.activeSession(in: workspaceID)?.id
    }
}
