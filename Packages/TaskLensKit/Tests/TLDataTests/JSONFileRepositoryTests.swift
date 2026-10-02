import Foundation
import Testing
import TLData
import TLDomain
import TLFoundation

@Suite("JSONFileRepository")
struct JSONFileRepositoryTests {
    @Test func persistsAcrossInstances() async throws {
        let directory = TemporaryDirectory.make()
        let workspace = Workspace(name: "Study", createdAt: Date(timeIntervalSinceReferenceDate: 10))

        let writer = JSONFileRepository<Workspace>(directory: directory, logger: .disabled())
        try await writer.upsert(workspace)

        let reader = JSONFileRepository<Workspace>(directory: directory, logger: .disabled())
        #expect(try await reader.fetchAll() == [workspace])
    }

    @Test func writesVersionedEnvelopeNamedAfterEntity() async throws {
        let directory = TemporaryDirectory.make()
        let repository = JSONFileRepository<Workspace>(directory: directory, logger: .disabled())
        try await repository.upsert(Workspace(name: "A", createdAt: Date()))

        let url = directory.appendingPathComponent("workspace.json")
        #expect(repository.fileURL == url)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(object?["schemaVersion"] as? Int == 1)
        #expect((object?["items"] as? [Any])?.count == 1)
    }

    @Test func corruptFileSurfacesPersistenceError() async throws {
        let directory = TemporaryDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("note.json"))

        let repository = JSONFileRepository<Note>(directory: directory, logger: .disabled())
        do {
            _ = try await repository.fetchAll()
            Issue.record("Expected a persistence error")
        } catch let error as TaskLensError {
            guard case .persistenceFailed(operation: .read, _) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
        }
    }

    @Test func fileBackedRepositoriesShareOneDirectory() async throws {
        let location = StoreLocation(rootURL: TemporaryDirectory.make())
        let repositories = try Repositories.fileBacked(at: location, logger: .disabled())
        try await repositories.notes.upsert(Note(body: "x", createdAt: Date()))

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: location.filesDirectory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(FileManager.default.fileExists(atPath: location.dataDirectory.appendingPathComponent("note.json").path))
    }

    @Test func storeLocationFallsBackWithoutAppGroup() throws {
        let location = try StoreLocation.resolve(appGroupIdentifier: nil, logger: .disabled())
        #expect(location.kind == .applicationSupport)
        #expect(location.rootURL.lastPathComponent == StoreLocation.directoryName)
    }
}
