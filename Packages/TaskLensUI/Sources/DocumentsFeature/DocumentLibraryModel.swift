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
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    /// Imports files picked in the Files app. Returns the imported documents.
    @discardableResult
    public func importFiles(_ urls: [URL]) async -> [Document] {
        await importEach(urls) { url in
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            return try await self.documentService.importFile(at: url, workspaceID: self.workspaceID, sessionID: try await self.targetSessionID())
        }
    }

    /// Imports raw data, e.g. a photo from the photo picker.
    @discardableResult
    public func importData(_ data: Data, filename: String, contentType: UTType?) async -> Document? {
        await importEach([data]) { data in
            try await self.documentService.importData(
                data, filename: filename, contentType: contentType,
                workspaceID: self.workspaceID, sessionID: try await self.targetSessionID()
            )
        }.first
    }

    public func delete(_ id: DocumentID) async {
        do {
            try await documentService.delete(id)
            documents.removeAll { $0.id == id }
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    private func targetSessionID() async throws -> SessionID? {
        guard let workspaceID else { return nil }
        return try await sessionService.activeSession(in: workspaceID)?.id
    }

    private func importEach<Input>(_ inputs: [Input], _ work: (Input) async throws -> Document) async -> [Document] {
        isImporting = true
        defer { isImporting = false }
        var imported: [Document] = []
        for input in inputs {
            do {
                imported.append(try await work(input))
            } catch {
                errorMessage = L10n.message(for: error)
            }
        }
        if !imported.isEmpty {
            await load()
        }
        return imported
    }
}
