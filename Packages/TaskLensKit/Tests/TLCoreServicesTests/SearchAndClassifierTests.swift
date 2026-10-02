import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

@Suite("SearchService")
struct SearchServiceTests {
    private func search(_ env: TestEnvironment) -> SearchService {
        SearchService(
            workspaces: env.repositories.workspaces,
            sessions: env.repositories.sessions,
            contextItems: env.repositories.contextItems
        )
    }

    @Test func findsWorkspacesSessionsAndItems() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "Physics Course")
        let session = try await env.sessions.start(in: workspace.id, title: "Physics revision")
        let item = try await env.capture.capture(.text("physics formulas"), source: .manualEntry, into: session.id)
        try await env.capture.capture(.text("unrelated"), source: .manualEntry)

        let results = try await search(env).search("PHYSICS")

        #expect(results.workspaces.map(\.id) == [workspace.id])
        #expect(results.sessions.map(\.id) == [session.id])
        #expect(results.items.map(\.id) == [item.id])
    }

    @Test func arabicMatchingIgnoresDiacritics() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "مَشْرُوع التخرج")
        let results = try await search(env).search("مشروع")
        #expect(results.workspaces.map(\.id) == [workspace.id])
    }

    @Test func matchesLinks() async throws {
        let env = TestEnvironment()
        let item = try await env.capture.capture(.url(URL(string: "https://developer.apple.com/swift")!), source: .browser)
        #expect(try await search(env).search("apple.com").items.map(\.id) == [item.id])
    }

    @Test func blankQueryReturnsNothingAndArchivedAreHidden() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "Archive me")
        try await env.workspaces.setArchived(workspace.id, true)
        #expect(try await search(env).search("   ").isEmpty)
        #expect(try await search(env).search("Archive").workspaces.isEmpty)
    }
}

@Suite("ContentClassifier")
struct ContentClassifierTests {
    @Test(arguments: ["https://apple.com", "  http://example.com/a?b=1  ", "HTTPS://Example.com"])
    func linksBecomeURLs(input: String) {
        #expect(ContentClassifier.classify(input).itemType == .url)
    }

    @Test(arguments: ["hello world", "$125", "0770 123 4567", "apple.com", "https://a.com and more", "mailto:a@b.com", "https://"])
    func everythingElseIsText(input: String) {
        #expect(ContentClassifier.classify(input) == .text(input))
    }
}
