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

    @Test func corruptFileIsKeptAsideAndTheStoreKeepsWorking() async throws {
        let directory = TemporaryDirectory.make()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("note.json"))

        let repository = JSONFileRepository<Note>(directory: directory, logger: .disabled())
        #expect(try await repository.fetchAll().isEmpty)
        let copies = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("note.unreadable-") }
        #expect(copies.count == 1)

        try await repository.upsert(Note(body: "new", createdAt: Date()))
        #expect(try await repository.fetchAll().count == 1)
    }

    @Test func oneUnreadableRecordDoesNotHideTheOthers() async throws {
        let directory = TemporaryDirectory.make()
        let writer = JSONFileRepository<Workspace>(directory: directory, logger: .disabled())
        let workspace = Workspace(name: "Kept", createdAt: Date(timeIntervalSinceReferenceDate: 10))
        try await writer.upsert(workspace)

        // A record this version can't read, as a damaged entry or a newer app might leave.
        let url = directory.appendingPathComponent("workspace.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var items = try #require(object["items"] as? [Any])
        items.append(["id": "not-a-uuid", "name": 42])
        object["items"] = items
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let reader = JSONFileRepository<Workspace>(directory: directory, logger: .disabled())
        #expect(try await reader.fetchAll() == [workspace])
        let copies = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("workspace.unreadable-") }
        #expect(copies.count == 1)
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

@Suite("Data control")
struct DataControlTests {
    @Test func exportsEverythingAndDeletesEverything() async throws {
        let location = StoreLocation(rootURL: TemporaryDirectory.make())
        let repositories = try Repositories.fileBacked(at: location, logger: .disabled())
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let workspace = Workspace(name: "Study", createdAt: date)
        try await repositories.workspaces.upsert(workspace)
        try await repositories.notes.upsert(Note(title: "Plan", body: "Read", createdAt: date))
        try await repositories.workflows.upsert(Workflow(name: "Save", trigger: .manual, steps: [WorkflowStep(kind: .save)], createdAt: date))
        let file = location.filesDirectory.appendingPathComponent("a.pdf")
        try Data("pdf".utf8).write(to: file)

        let control = DataControl(repositories: repositories, filesDirectory: location.filesDirectory)
        let url = try await control.export(to: TemporaryDirectory.make(), now: date)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((object["workspaces"] as? [Any])?.count == 1)
        #expect((object["notes"] as? [Any])?.count == 1)
        #expect((object["workflows"] as? [Any])?.count == 1)
        #expect(object["formatVersion"] as? Int == 1)

        try await control.deleteEverything()
        #expect(try await repositories.workspaces.fetchAll().isEmpty)
        #expect(try await repositories.notes.fetchAll().isEmpty)
        #expect(try await repositories.workflows.fetchAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // A new instance reads the same (empty) store from disk.
        let reopened = try Repositories.fileBacked(at: location, logger: .disabled())
        #expect(try await reopened.notes.fetchAll().isEmpty)
    }
}
