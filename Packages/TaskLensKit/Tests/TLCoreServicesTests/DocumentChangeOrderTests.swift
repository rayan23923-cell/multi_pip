import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

@Suite("Document changes")
struct DocumentChangeOrderTests {
    /// The search indexer, the reader's page and opening a document all change the
    /// same record at once. None of them may undo another's change.
    @Test func simultaneousChangesAreAllKept() async throws {
        let env = TestEnvironment()
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory)

        for round in 0..<20 {
            let document = try await service.importData(Data("%PDF-1.4".utf8), filename: "Deck \(round).pdf", contentType: .pdf)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = try? await service.setSearchText(document.id, text: "indexed text") }
                group.addTask { _ = try? await service.markOpened(document.id, pageCount: 10) }
                group.addTask { _ = try? await service.setLastReadPage(document.id, page: 2) }
            }
            let stored = try await service.document(id: document.id)
            #expect(stored.lastReadPage == 2, "Round \(round): the reading page was lost")
            #expect(DocumentService.searchText(of: stored) == "indexed text", "Round \(round): the search text was lost")
            #expect(stored.pageCount == 10, "Round \(round): the page count was lost")
            #expect(stored.lastOpenedAt != nil)
        }
    }
}
