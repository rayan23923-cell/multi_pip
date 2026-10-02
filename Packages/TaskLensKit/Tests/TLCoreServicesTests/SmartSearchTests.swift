import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation

@Suite("Smart Search")
struct SmartSearchTests {
    let env = TestEnvironment()

    private func service(semantic: (any SemanticRanking)? = nil) -> SmartSearchService {
        SmartSearchService(
            workspaces: env.repositories.workspaces,
            sessions: env.repositories.sessions,
            contextItems: env.repositories.contextItems,
            notes: env.repositories.notes,
            documents: env.repositories.documents,
            clipboardItems: env.repositories.clipboardItems,
            semantic: semantic,
            clock: env.clock
        )
    }

    private var now: Date { env.clock.now() }

    private func item(_ content: ContextContent, at date: Date, workspace: WorkspaceID? = nil) async throws -> ContextItem {
        let item = ContextItem(workspaceID: workspace, source: .manualEntry, content: content, createdAt: date)
        try await env.repositories.contextItems.upsert(item)
        return item
    }

    private func pdf(_ title: String, in workspace: WorkspaceID, kind: FileKind = .pdf, text: String? = nil) async throws -> Document {
        var metadata: Metadata = [:]
        if let text { metadata[DocumentService.searchTextKey] = .string(text) }
        let document = Document(
            workspaceID: workspace, title: title,
            file: FileReference(relativePath: "\(title).bin", originalFilename: title, contentType: "public.data", kind: kind),
            createdAt: now, metadata: metadata
        )
        try await env.repositories.documents.upsert(document)
        return document
    }

    // MARK: The examples

    @Test func pricesSeenYesterday() async throws {
        let yesterday = Calendar.current.startOfDay(for: now).addingTimeInterval(-12 * 3600)
        let price = try await item(.text("Hotel booking $120"), at: yesterday)
        _ = try await item(.text("Hotel booking $90"), at: yesterday.addingTimeInterval(-3 * 86_400))
        _ = try await item(.text("Check in at the lobby"), at: yesterday)

        for query in ["الأسعار التي شاهدتها أمس", "prices I saw yesterday"] {
            let response = try await service().search(query)
            #expect(response.query.filters.contains(.price), "\(query)")
            #expect(response.query.dateRange != nil, "\(query)")
            #expect(response.hits.map(\.document.targetID) == [price.id.rawValue], "\(query)")
            #expect(response.hits.first?.match == .filter)
        }
    }

    @Test func studyPDF() async throws {
        let study = Workspace(name: "University", kind: .study, createdAt: now)
        let research = Workspace(name: "Market", kind: .research, createdAt: now)
        try await env.repositories.workspaces.upsert(study)
        try await env.repositories.workspaces.upsert(research)
        let wanted = try await pdf("Physics chapter 3", in: study.id)
        _ = try await pdf("Competitors", in: research.id)
        _ = try await pdf("Reading list", in: study.id, kind: .text)

        for query in ["PDF الخاص بالدراسة", "study PDF"] {
            let response = try await service().search(query)
            #expect(response.query.kindHint == "study", "\(query)")
            #expect(response.hits.map(\.document.targetID) == [wanted.id.rawValue], "\(query)")
        }
    }

    @Test func iPhoneLinks() async throws {
        let link = try await item(.url(URL(string: "https://www.apple.com/iphone")!), at: now)
        _ = try await item(.url(URL(string: "https://www.example.com/news")!), at: now)
        _ = try await item(.text("iPhone battery tips"), at: now)

        for query in ["روابط iPhone", "iPhone links"] {
            let response = try await service().search(query)
            #expect(response.query.filters == [.link], "\(query)")
            #expect(response.query.keywords == ["iphone"], "\(query)")
            #expect(response.hits.map(\.document.targetID) == [link.id.rawValue], "\(query)")
            #expect(response.hits.first?.match == .keyword)
        }
    }

    @Test func savedTextsAboutFlutter() async throws {
        let note = Note(title: "Flutter state", body: "Use providers for state.", createdAt: now)
        try await env.repositories.notes.upsert(note)
        let text = try await item(.text("Flutter widgets rebuild when state changes"), at: now)
        _ = try await item(.url(URL(string: "https://flutter.dev")!), at: now)
        _ = try await item(.text("SwiftUI views"), at: now)

        for query in ["النصوص التي حفظتها عن Flutter", "texts I saved about Flutter"] {
            let response = try await service().search(query)
            #expect(Set(response.hits.map(\.document.targetID)) == [note.id.rawValue, text.id.rawValue], "\(query)")
        }
    }

    // MARK: Matching

    @Test func documentTextIsSearchable() async throws {
        let workspace = Workspace(name: "Biology", kind: .study, createdAt: now)
        try await env.repositories.workspaces.upsert(workspace)
        let document = try await pdf("Lecture 4", in: workspace.id, text: "Photosynthesis turns light into energy.")
        let response = try await service().search("photosynthesis")
        #expect(response.hits.map(\.document.targetID) == [document.id.rawValue])
        #expect(response.hits.first?.snippet.contains("Photosynthesis") == true)
    }

    @Test func arabicMatchesWithoutDiacriticsOrArticle() async throws {
        let note = Note(title: "مراجعة الدِّراسة", body: "", createdAt: now)
        try await env.repositories.notes.upsert(note)
        let response = try await service().search("دراسة")
        #expect(response.hits.map(\.document.targetID) == [note.id.rawValue])
        #expect(SearchText.normalize("أَحْمَد") == "احمد")
        #expect(SearchText.tokens("بالدراسة") == ["دراسه"])
    }

    @Test func clipboardIsSearchable() async throws {
        let clip = ClipboardItem(content: .text("Wi-Fi password: orange42"), capturedAt: now)
        try await env.repositories.clipboardItems.upsert(clip)
        let response = try await service().search("password")
        #expect(response.hits.map(\.document.kind) == [.clipboard])
    }

    @Test func emptyQueryFindsNothing() async throws {
        _ = try await item(.text("Anything"), at: now)
        let response = try await service().search("   ")
        #expect(response.hits.isEmpty)
    }

    // MARK: Meaning

    @Test func meaningAddsCloseResultsWhenAvailable() async throws {
        let car = try await item(.text("Buying a used car"), at: now)
        _ = try await item(.text("Grocery list"), at: now)

        let keywordOnly = try await service().search("automobile")
        #expect(keywordOnly.hits.isEmpty)
        #expect(!keywordOnly.usedMeaning)

        let response = try await service(semantic: FakeRanker()).search("automobile")
        #expect(response.usedMeaning)
        #expect(response.hits.map(\.document.targetID) == [car.id.rawValue])
        #expect(response.hits.first?.match == .meaning)
    }

    @Test func meaningIsSkippedForUnsupportedLanguages() async throws {
        _ = try await item(.text("Buying a used car"), at: now)
        let response = try await service(semantic: FakeRanker(available: false)).search("automobile")
        #expect(!response.usedMeaning)
        #expect(response.hits.isEmpty)
    }

    // MARK: Parsing

    @Test func parserReadsHints() {
        let now = Date()
        let parsed = SearchQueryParser.parse("emails from last week", now: now)
        #expect(parsed.filters == [.email])
        #expect(parsed.dateRange != nil)
        #expect(parsed.keywords.isEmpty)

        let today = SearchQueryParser.parse("اليوم", now: now)
        #expect(today.dateRange?.contains(now) == true)

        let plain = SearchQueryParser.parse("budget review", now: now)
        #expect(!plain.hasHints)
        #expect(plain.keywords == ["budget", "review"])
    }
}

private struct FakeRanker: SemanticRanking {
    var available = true

    func isAvailable(for text: String) -> Bool { available }

    func distance(between query: String, and text: String) -> Double? {
        text.localizedCaseInsensitiveContains("car") ? 0.3 : 1.2
    }
}
