import Foundation
import Testing
import TLCoreServices
import TLDomain
import TLFoundation
import UniformTypeIdentifiers

@Suite("Browser address")
struct BrowserAddressTests {
    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("https://example.com/a?b=1", "https://example.com/a?b=1"),
        ("http://example.com", "http://example.com"),
        ("  apple.com/iphone  ", "https://apple.com/iphone"),
        ("localhost:8080", "https://localhost:8080"),
        ("192.168.1.10", "https://192.168.1.10"),
    ])
    func acceptsWebAddresses(input: String, expected: String) {
        #expect(BrowserAddress.url(from: input)?.absoluteString == expected)
    }

    @Test(arguments: [
        "", "hello", "two words.com", "javascript:alert(1)", "file:///etc/hosts",
        "data:text/html,hi", "mailto:a@b.com", "ftp://example.com", "https://",
    ])
    func rejectsEverythingElse(input: String) {
        #expect(BrowserAddress.url(from: input) == nil)
    }

    @Test func outputKeepsTitle() async throws {
        let env = TestEnvironment()
        let url = try #require(URL(string: "https://example.com"))
        let item = try await env.capture.capture(BrowserAddress.output(for: url, title: "Example"))
        #expect(item.content == .url(url))
        #expect(item.source == .browser)
        #expect(item.metadata["title"] == .string("Example"))
        #expect(item.metadata["tool"] == .string("browser"))
    }
}

@Suite("Documents")
struct DocumentServiceTests {
    @Test func importsTextAndReadsIt() async throws {
        let env = TestEnvironment()
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory)

        let document = try await service.importData(
            Data("مرحبا\nHello".utf8), filename: "notes.txt", contentType: .plainText
        )
        #expect(document.kind == .text)
        #expect(document.title == "notes")
        #expect(document.file.relativePath.hasPrefix("Documents/"))
        #expect(FileManager.default.fileExists(atPath: service.fileURL(for: document).path))

        let content = try service.readText(of: document)
        #expect(content.text == "مرحبا\nHello")
        #expect(!content.isTruncated)
    }

    @Test func detectsKindsAndRejectsUnsupported() async throws {
        let env = TestEnvironment()
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory)

        #expect(try await service.importData(Data([1]), filename: "a.pdf", contentType: nil).kind == .pdf)
        #expect(try await service.importData(Data([1]), filename: "b.png", contentType: nil).kind == .image)
        #expect(try await service.importData(Data([1]), filename: "c.swift", contentType: nil).kind == .text)
        await #expect(throws: TaskLensError.unsupportedContent(type: "unknown")) {
            try await service.importData(Data([1]), filename: "d.unknownext", contentType: nil)
        }
        await #expect(throws: TaskLensError.validationFailed(.emptyContent)) {
            try await service.importData(Data(), filename: "e.txt", contentType: .plainText)
        }
    }

    @Test func importsFromURLAndDeletesFile() async throws {
        let env = TestEnvironment()
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory.appendingPathComponent("Files"))
        let source = directory.appendingPathComponent("Report.csv")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("a,b\n1,2".utf8).write(to: source)

        let document = try await service.importFile(at: source)
        #expect(document.kind == .text)
        #expect(document.file.originalFilename == "Report.csv")
        let stored = service.fileURL(for: document)
        #expect(FileManager.default.fileExists(atPath: stored.path))

        try await service.delete(document.id)
        #expect(!FileManager.default.fileExists(atPath: stored.path))
        #expect(try await service.documents(in: nil).isEmpty)
    }

    @Test func pagesOpeningAndSessions() async throws {
        let env = TestEnvironment()
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory)
        let workspace = try await env.workspaces.create(name: "Study", kind: .study)
        let session = try await env.sessions.start(in: workspace.id)

        let first = try await service.importData(Data([1]), filename: "a.pdf", contentType: .pdf)
        env.clock.advance(by: 10)
        let second = try await service.importData(Data([1]), filename: "b.pdf", contentType: .pdf)
        env.clock.advance(by: 10)
        try await service.markOpened(first.id, pageCount: 5)
        #expect(try await service.documents(in: nil).map(\.id) == [first.id, second.id])

        #expect(try await service.setLastReadPage(first.id, page: 9).lastReadPage == 4)
        #expect(try await service.setLastReadPage(first.id, page: -1).lastReadPage == 0)

        try await service.attach(first.id, to: session)
        #expect(try await service.documents(in: workspace.id).map(\.id) == [first.id])

        let item = try await env.capture.capture(DocumentService.output(for: try await service.document(id: first.id)), into: session.id)
        #expect(item.type == .pdf)
        #expect(item.source == .documentViewer)
        #expect(item.sessionID == session.id)
        #expect(item.metadata["title"] == .string("a"))

        let text = try await env.capture.capture(DocumentService.textOutput("Page text", from: first, page: 2))
        #expect(text.content == .text("Page text"))
        #expect(text.metadata["page"] == .number(3))
    }

    @Test func orphanedFilesAreRemovedAfterWorkspaceDelete() async throws {
        let env = TestEnvironment()
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory)
        let workspace = try await env.workspaces.create(name: "Temp", kind: .work)
        let kept = try await service.importData(Data([1]), filename: "keep.pdf", contentType: .pdf)
        let dropped = try await service.importData(Data([1]), filename: "drop.pdf", contentType: .pdf, workspaceID: workspace.id)

        try await env.workspaces.delete(workspace.id)
        // The test clock is in 2001 while files carry real dates, so a large
        // negative age makes every file count as old enough.
        let anyAge: TimeInterval = -1e10
        #expect(try await service.removeOrphanedFiles() == 0) // too new to touch
        #expect(try await service.removeOrphanedFiles(minimumAge: anyAge) == 1)
        #expect(FileManager.default.fileExists(atPath: service.fileURL(for: kept).path))
        #expect(!FileManager.default.fileExists(atPath: service.fileURL(for: dropped).path))
        #expect(try await service.removeOrphanedFiles(minimumAge: anyAge) == 0)
    }

    @Test func decodesUTF16WithByteOrderMark() async throws {
        let env = TestEnvironment()
        let directory = TemporaryDirectory.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = env.documents(in: directory)
        let utf16 = try #require("نص عربي".data(using: .utf16))
        let document = try await service.importData(utf16, filename: "u.txt", contentType: .plainText)
        #expect(try service.readText(of: document).text == "نص عربي")
    }
}

@Suite("Notes as a tool")
struct NoteToolTests {
    @Test func searchMatchesTitleAndBodyIgnoringDiacritics() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "Thesis", kind: .study)
        try await env.notes.create(title: "مُلَخَّص", body: "الفصل الأول", workspaceID: workspace.id)
        try await env.notes.create(title: "Groceries", body: "Milk and eggs")

        #expect(try await env.notes.search("ملخص").map(\.title) == ["مُلَخَّص"])
        #expect(try await env.notes.search("eggs").map(\.title) == ["Groceries"])
        #expect(try await env.notes.search("eggs", in: workspace.id).isEmpty)
        #expect(try await env.notes.search("  ").count == 2)
    }

    @Test func attachLinksSessionAndItem() async throws {
        let env = TestEnvironment()
        let workspace = try await env.workspaces.create(name: "Work", kind: .work)
        let session = try await env.sessions.start(in: workspace.id)
        let note = try await env.notes.create(title: "Agenda", body: "1. Budget")

        let item = try await env.capture.capture(NoteService.output(for: note), into: session.id)
        #expect(item.content == .text("Agenda\n\n1. Budget"))
        #expect(item.source == .notes)
        #expect(item.metadata["noteID"] == .string(note.id.description))

        let attached = try await env.notes.attach(note.id, to: session, itemID: item.id)
        #expect(attached.sessionID == session.id)
        #expect(attached.workspaceID == workspace.id)
        #expect(attached.linkedItemIDs == [item.id])
        // Attaching again does not duplicate the link.
        #expect(try await env.notes.attach(note.id, to: session, itemID: item.id).linkedItemIDs == [item.id])
    }
}

@Suite("Basic action suggester")
struct BasicActionSuggesterTests {
    @Test func suggestsByContentType() async throws {
        let url = try #require(URL(string: "https://example.com"))
        #expect(BasicActionSuggester.actions(for: .url(url)).first?.type == .openURL)
        let numberActions = BasicActionSuggester.actions(for: .text("1,250.75")).map(\.type)
        #expect(numberActions.contains(.calculate))
        #expect(numberActions.contains(.createNote))
        #expect(!BasicActionSuggester.actions(for: .text("12 apples")).map(\.type).contains(.calculate))
        #expect(BasicActionSuggester.actions(for: .text("hi")).first?.type == .saveToSession)
    }

    @Test func targetsTheItem() async throws {
        let env = TestEnvironment()
        let item = try await env.capture.capture(.text("42"), source: .manualEntry)
        let actions = await BasicActionSuggester().suggestActions(for: item)
        #expect(actions.allSatisfy { $0.targetItemID == item.id })
    }
}

@Suite("Capture target")
struct CaptureTargetTests {
    @Test func prefersTheWorkspaceSession() async throws {
        let env = TestEnvironment()
        let study = try await env.workspaces.create(name: "Study", kind: .study)
        let work = try await env.workspaces.create(name: "Work", kind: .work)
        #expect(try await env.sessions.captureTarget(preferring: study.id) == nil)

        let studySession = try await env.sessions.start(in: study.id)
        env.clock.advance(by: 5)
        let workSession = try await env.sessions.start(in: work.id)

        #expect(try await env.sessions.captureTarget(preferring: study.id)?.id == studySession.id)
        #expect(try await env.sessions.captureTarget(preferring: nil)?.id == workSession.id)
    }
}
