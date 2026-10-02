import BrowserFeature
import CalculatorFeature
import DocumentsFeature
import Foundation
import ImageViewerFeature
import LensFeature
import NotesFeature
import Testing
import TextViewerFeature
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import TLLocalization
import TLNavigation
import UIKit
import UniformTypeIdentifiers

extension Services {
    var notes: NoteService { NoteService(notes: repositories.notes, clock: clock, logger: .disabled()) }
    var calculator: CalculatorService {
        CalculatorService(records: repositories.calculations, clock: clock, logger: .disabled())
    }
    var toolCapture: ToolCaptureService { ToolCaptureService(capture: capture, sessions: sessions) }

    func documents(in directory: URL) -> DocumentService {
        DocumentService(documents: repositories.documents, filesDirectory: directory, clock: clock, logger: .disabled())
    }

    /// A workspace with an active session, the usual target for "Save to Session".
    func activeSession(kind: WorkspaceKind = .study) async throws -> Session {
        let workspace = try await workspaces.create(name: "Thesis", kind: kind)
        return try await sessions.start(in: workspace.id)
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("TaskLensUITests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

/// Three-page PDF; "invoice" appears only on page 2.
private func samplePDF() -> Data {
    UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
        for page in 1...3 {
            context.beginPage()
            let text = page == 2 ? "Page \(page) invoice total" : "Page \(page) TaskLens"
            text.draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
    }
}

@MainActor
@Suite("Notes model")
struct NotesModelTests {
    @Test func createSearchPinAndDelete() async throws {
        let services = Services()
        let model = NotesModel(workspaceID: nil, noteService: services.notes, toolCapture: services.toolCapture)
        await model.load()
        #expect(model.hasLoaded && model.notes.isEmpty)

        let first = NoteEditorModel()
        first.title = "Budget"
        first.body = "Review on Monday"
        #expect(await model.save(first))
        services.clock.advance(by: 10)
        let second = NoteEditorModel()
        second.title = "مُلَخَّص"
        #expect(await model.save(second))
        #expect(model.notes.map(\.title) == ["مُلَخَّص", "Budget"])

        let budget = try #require(model.notes.first { $0.title == "Budget" })
        await model.togglePin(budget.id)
        #expect(model.pinnedNotes.map(\.title) == ["Budget"])
        #expect(model.notes.first?.title == "Budget")

        // Edit through the editor keeps the same note.
        let editor = NoteEditorModel(note: budget)
        editor.body = "Moved to Tuesday"
        #expect(await model.save(editor))
        #expect(model.notes.count == 2)
        #expect(model.notes.first { $0.id == budget.id }?.body == "Moved to Tuesday")

        model.query = "ملخص"
        await model.load()
        #expect(model.notes.map(\.title) == ["مُلَخَّص"])

        model.query = ""
        await model.delete(budget.id)
        #expect(model.notes.map(\.title) == ["مُلَخَّص"])

        #expect(await model.save(NoteEditorModel()) == false)
        #expect(model.errorMessage == L10n.string(.errorValidationEmptyContent))
    }

    @Test func attachSavesItemIntoSession() async throws {
        let services = Services()
        let session = try await services.activeSession()
        let model = NotesModel(workspaceID: session.workspaceID, noteService: services.notes, toolCapture: services.toolCapture)
        let editor = NoteEditorModel()
        editor.title = "Agenda"
        await model.save(editor)
        let note = try #require(model.notes.first)

        await model.loadAttachableSessions()
        #expect(model.attachableSessions.map(\.id) == [session.id])
        #expect(await model.attach(note.id, to: session))

        let items = try await services.capture.items(in: session.id)
        #expect(items.count == 1)
        #expect(items.first?.source == .notes)
        #expect(model.notes.first?.sessionID == session.id)
        #expect(model.notes.first?.linkedItemIDs == items.map(\.id))
    }

    @Test func editorProducesContext() {
        let editor = NoteEditorModel()
        #expect(editor.toolOutput == nil)
        editor.title = "Title"
        editor.body = "Body"
        #expect(editor.toolOutput?.content == .text("Title\n\nBody"))
        #expect(editor.toolOutput?.tool == .notes)
    }
}

@MainActor
@Suite("Calculator model")
struct CalculatorModelTests {
    @Test func calculatesRecordsAndSaves() async throws {
        let services = Services()
        let session = try await services.activeSession()
        let model = CalculatorModel(workspaceID: session.workspaceID, calculatorService: services.calculator, toolCapture: services.toolCapture)
        await model.load()

        for key: CalculatorEngine.Key in [.digit(1), .digit(2), .op(.add), .digit(3), .digit(0), .equals] {
            await model.press(key)
        }
        #expect(model.display == "42")
        #expect(model.history.map(\.expression) == ["12 + 30"])
        #expect(model.toolOutput?.content == .text("42"))
        #expect(model.toolOutput?.metadata["expression"] == .string("12 + 30"))

        await model.save()
        let items = try await services.capture.items(in: session.id)
        #expect(items.map(\.content) == [.text("42")])
        #expect(items.first?.source == .calculator)
    }

    @Test func percentHistoryReuseAndErrors() async throws {
        let services = Services()
        let model = CalculatorModel(workspaceID: nil, calculatorService: services.calculator, toolCapture: services.toolCapture)
        for key: CalculatorEngine.Key in [.digit(5), .digit(0), .op(.add), .digit(1), .digit(0), .percent, .equals] {
            await model.press(key)
        }
        #expect(model.display == "55")
        let record = try #require(model.history.first)

        for key: CalculatorEngine.Key in [.digit(1), .op(.divide), .digit(0), .equals] {
            await model.press(key)
        }
        #expect(model.display == nil)
        #expect(model.toolOutput == nil)

        model.use(record)
        #expect(model.display == "55")
        #expect(model.resultText == "55")

        await model.clearHistory()
        #expect(model.history.isEmpty)
    }
}

@MainActor
@Suite("Browser model")
struct BrowserModelTests {
    @Test func tabsAndAddresses() async throws {
        let services = Services()
        let model = BrowserModel(toolCapture: services.toolCapture)
        #expect(model.tabs.count == 1)
        #expect(model.toolOutput == nil)

        model.addressText = "not a site"
        #expect(model.submitAddress() == nil)
        #expect(model.errorMessage == L10n.string(.errorValidationInvalidURL))

        model.addressText = "example.com"
        let url = try #require(model.submitAddress())
        #expect(url.absoluteString == "https://example.com")
        #expect(model.selectedTab.url == url)

        let first = model.selectedTabID
        model.apply(BrowserPageState(
            url: URL(string: "https://example.com/page"), title: "Example", canGoBack: true,
            canGoForward: false, isLoading: false, progress: 1
        ), to: first)
        #expect(model.selectedTab.title == "Example")
        #expect(model.selectedTab.canGoBack)
        #expect(model.addressText == "https://example.com/page")

        let second = try #require(model.newTab())
        #expect(model.selectedTabID == second.id)
        #expect(model.addressText.isEmpty)
        model.select(first)
        #expect(model.addressText == "https://example.com/page")

        model.closeTab(first)
        #expect(model.tabs.map(\.id) == [second.id])
        model.closeTab(second.id)
        #expect(model.tabs.count == 1)
        #expect(model.selectedTab.url == nil)

        while model.newTab() != nil {}
        #expect(model.tabs.count == BrowserModel.maximumTabs)
    }

    @Test func savesURLToSession() async throws {
        let services = Services()
        let session = try await services.activeSession(kind: .shopping)
        let model = BrowserModel(workspaceID: session.workspaceID, toolCapture: services.toolCapture)
        model.addressText = "https://example.com/item"
        _ = model.submitAddress()
        model.apply(BrowserPageState(
            url: nil, title: "Item", canGoBack: false, canGoForward: false, isLoading: false, progress: 1
        ), to: model.selectedTabID)

        await model.saveCurrentURL()
        #expect(model.isCurrentURLSaved)
        let item = try #require(try await services.capture.items(in: session.id).first)
        #expect(item.content == .url(URL(string: "https://example.com/item")!))
        #expect(item.metadata["title"] == .string("Item"))
        #expect(item.source == .browser)
    }
}

@MainActor
@Suite("Document tools")
struct DocumentToolTests {
    @Test func libraryImportsAndDeletes() async throws {
        let services = Services()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = services.documents(in: directory.appendingPathComponent("Files"))
        let library = DocumentLibraryModel(workspaceID: nil, documentService: documents, sessionService: services.sessions)

        let source = directory.appendingPathComponent("Plan.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Plan".utf8).write(to: source)
        let imported = await library.importFiles([source])
        #expect(imported.map(\.title) == ["Plan"])
        #expect(await library.importData(samplePDF(), filename: "Report.pdf", contentType: .pdf)?.kind == .pdf)
        #expect(library.documents.count == 2)
        #expect(AppRoute.viewer(for: imported[0]) == .textDocument(imported[0].id))

        await library.delete(imported[0].id)
        #expect(library.documents.map(\.title) == ["Report"])

        #expect(await library.importData(Data([1]), filename: "x.bin", contentType: nil) == nil)
        #expect(library.errorMessage == L10n.string(.errorUnsupportedContent))
    }

    @Test func pdfPagesSearchExtractAndSave() async throws {
        let services = Services()
        let session = try await services.activeSession()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = services.documents(in: directory)
        let document = try await documents.importData(
            samplePDF(), filename: "Report.pdf", contentType: .pdf, workspaceID: session.workspaceID
        )
        let model = PDFViewerModel(documentID: document.id, documentService: documents, toolCapture: services.toolCapture)
        await model.load()

        #expect(model.pageCount == 3)
        #expect(model.currentPage == 0)
        model.nextPage()
        model.nextPage()
        model.nextPage()
        #expect(model.currentPage == 2)
        #expect(!model.canGoForward)
        model.goTo(page: 0)

        model.searchQuery = "INVOICE"
        model.search()
        #expect(model.matches.count == 1)
        #expect(model.currentPage == 1)

        #expect(model.extractCurrentPageText().contains("invoice"))
        await model.saveExtractedText()
        await model.saveDocument()

        let items = try await services.capture.items(in: session.id)
        #expect(Set(items.map(\.type)) == [.text, .pdf])
        #expect(items.allSatisfy { $0.source == .documentViewer })
        #expect(try await documents.document(id: document.id).pageCount == 3)
    }

    @Test func imageViewerLoadsAndSaves() async throws {
        let services = Services()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = services.documents(in: directory)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        let document = try await documents.importData(png, filename: "Photo.png", contentType: .png)
        let model = ImageViewerModel(documentID: document.id, documentService: documents, toolCapture: services.toolCapture)
        await model.load()

        #expect(model.image != nil)
        #expect(model.pixelSize == CGSize(width: 24, height: 16))
        #expect(model.toolOutput?.content.itemType == .image)
        await model.save()
        #expect(try await services.capture.inboxItems().first?.source == .imageViewer)
    }

    @Test func textViewerSearchesAndSaves() async throws {
        let services = Services()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = services.documents(in: directory)
        let document = try await documents.importData(
            Data("Budget review\nمُراجعة الميزانية\nbudget again".utf8), filename: "notes.txt", contentType: .plainText
        )
        let model = TextViewerModel(documentID: document.id, documentService: documents, toolCapture: services.toolCapture)
        await model.load()

        #expect(model.hasLoaded)
        #expect(!model.isTruncated)
        model.query = "budget"
        #expect(model.matchRanges.count == 2)
        model.query = "مراجعة"
        #expect(model.matchRanges.count == 1)

        await model.saveText()
        let item = try #require(try await services.capture.inboxItems().first)
        #expect(item.source == .textViewer)
        #expect(item.content == .text("Budget review\nمُراجعة الميزانية\nbudget again"))
    }
}

@MainActor
@Suite("Tools to actions")
struct ToolActionTests {
    @Test func lensAnalyzesContentSentByATool() {
        let services = Services()
        let model = LensModel(captureService: services.capture, sessionService: services.sessions, initialInput: "42")
        #expect(model.content == .text("42"))
        #expect(model.actions.map(\.type).contains(.saveToSession))
        #expect(model.actions.allSatisfy { LensModel.supportedActions.contains($0.type) })
    }

    @Test func everyToolHasAScreen() {
        let workspace = WorkspaceID()
        for tool in WorkspaceTool.allKnown {
            #expect(AppRoute.tool(tool, workspaceID: workspace) != nil, "No screen for \(tool.rawValue)")
        }
        #expect(AppRoute.tool("future", workspaceID: nil) == nil)
    }
}
