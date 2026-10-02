import Foundation
import Testing
import TLData
import TLDomain
import TLFoundation

/// The same contract must hold for every Repository implementation.
@Suite("Repository contract")
struct RepositoryContractTests {
    enum Backend: String, CaseIterable, Sendable {
        case inMemory
        case jsonFile
    }

    private static func makeRepository(_ backend: Backend) -> any Repository<Note> {
        switch backend {
        case .inMemory:
            InMemoryRepository<Note>()
        case .jsonFile:
            JSONFileRepository<Note>(directory: TemporaryDirectory.make(), logger: .disabled())
        }
    }

    private static func note(_ body: String) -> Note {
        Note(body: body, createdAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test(arguments: Backend.allCases)
    func upsertFetchAndDelete(backend: Backend) async throws {
        let repository = Self.makeRepository(backend)
        let first = Self.note("one")
        var second = Self.note("two")

        try await repository.upsert(first)
        try await repository.upsert(second)
        #expect(try await repository.fetch(id: first.id) == first)
        #expect(try await repository.fetchAll().count == 2)

        second.body = "two, edited"
        try await repository.upsert(second)
        #expect(try await repository.fetch(id: second.id)?.body == "two, edited")
        #expect(try await repository.fetchAll().count == 2)

        try await repository.delete(id: first.id)
        #expect(try await repository.fetch(id: first.id) == nil)
        #expect(try await repository.fetchAll().map(\.id) == [second.id])
    }

    @Test(arguments: Backend.allCases)
    func batchOperations(backend: Backend) async throws {
        let repository = Self.makeRepository(backend)
        let notes = (0..<5).map { Self.note("note \($0)") }
        try await repository.upsert(contentsOf: notes)
        #expect(try await repository.fetchAll().count == 5)

        try await repository.delete(ids: Array(notes.prefix(3).map(\.id)))
        #expect(Set(try await repository.fetchAll().map(\.id)) == Set(notes.suffix(2).map(\.id)))
    }

    @Test(arguments: Backend.allCases)
    func requireThrowsNotFound(backend: Backend) async throws {
        let repository = Self.makeRepository(backend)
        let missing = NoteID()
        await #expect(throws: TaskLensError.notFound(entity: "note", id: missing.uuidString)) {
            try await repository.require(id: missing)
        }
    }

    @Test(arguments: Backend.allCases)
    func deletingMissingIDsIsANoOp(backend: Backend) async throws {
        let repository = Self.makeRepository(backend)
        try await repository.delete(id: NoteID())
        try await repository.delete(ids: [NoteID(), NoteID()])
        #expect(try await repository.fetchAll().isEmpty)
    }
}
