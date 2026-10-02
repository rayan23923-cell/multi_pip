import ClipboardFeature
import CommandCenterFeature
import Foundation
import LensFeature
import SessionsFeature
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation
import TLLocalization
import WorkspacesFeature

@MainActor
struct Services {
    let repositories = Repositories.inMemory()
    let clock = ManualDateProvider(Date(timeIntervalSinceReferenceDate: 5_000))

    var workspaces: WorkspaceService {
        WorkspaceService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            contextItems: repositories.contextItems,
            documents: repositories.documents,
            notes: repositories.notes,
            actionRecords: repositories.actionRecords,
            clock: clock,
            logger: .disabled()
        )
    }

    var sessionContent: SessionContentService {
        SessionContentService(
            workspaces: repositories.workspaces,
            sessions: repositories.sessions,
            contextItems: repositories.contextItems,
            notes: repositories.notes,
            actionRecords: repositories.actionRecords,
            clock: clock,
            logger: .disabled()
        )
    }

    func sessionDetail(_ id: SessionID, resume: Bool = false) -> SessionDetailModel {
        SessionDetailModel(
            sessionID: id,
            sessionService: sessions,
            contentService: sessionContent,
            captureService: capture,
            resume: resume
        )
    }

    var sessions: SessionService {
        SessionService(workspaces: repositories.workspaces, sessions: repositories.sessions, clock: clock, logger: .disabled())
    }

    var capture: CaptureService {
        CaptureService(sessions: repositories.sessions, contextItems: repositories.contextItems, clock: clock, logger: .disabled())
    }

    var search: SearchService {
        SearchService(workspaces: repositories.workspaces, sessions: repositories.sessions, contextItems: repositories.contextItems)
    }

    var clipboard: ClipboardService {
        ClipboardService(clipboardItems: repositories.clipboardItems, capture: capture, clock: clock, logger: .disabled())
    }

    func commandCenter() -> CommandCenterModel {
        CommandCenterModel(workspaceService: workspaces, sessionService: sessions, captureService: capture, searchService: search)
    }
}

@MainActor
@Suite("Workspace list model")
struct WorkspaceListModelTests {
    @Test func createEditDeleteAndErrors() async throws {
        let services = Services()
        let model = WorkspaceListModel(service: services.workspaces)

        #expect(await model.create(WorkspaceDraft(name: "Study", kind: .study)))
        #expect(model.workspaces.map(\.name) == ["Study"])
        #expect(model.workspaces.first?.kind == .study)

        let id = try #require(model.workspaces.first?.id)
        var draft = WorkspaceDraft(try #require(model.workspaces.first))
        draft.name = "Thesis"
        #expect(await model.update(id, with: draft))
        #expect(model.workspaces.map(\.name) == ["Thesis"])

        #expect(await model.create(WorkspaceDraft(name: "  ")) == false)
        #expect(model.errorMessage == L10n.string(.errorValidationEmptyName))

        await model.delete(id)
        #expect(model.workspaces.isEmpty)
    }

    @Test func duplicateUsesLocalizedCopyName() async throws {
        let services = Services()
        let model = WorkspaceListModel(service: services.workspaces)
        await model.create(WorkspaceDraft(name: "Shop", kind: .shopping))
        let original = try #require(model.workspaces.first)

        await model.duplicate(original)

        #expect(model.workspaces.count == 2)
        #expect(model.workspaces[1].name == L10n.format(.workspaceCopyName, "Shop"))
        #expect(model.workspaces[1].kind == .shopping)
    }

    @Test func moveAndFavoritePersist() async throws {
        let services = Services()
        let model = WorkspaceListModel(service: services.workspaces)
        for name in ["A", "B", "C"] {
            await model.create(WorkspaceDraft(name: name))
        }

        await model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(model.workspaces.map(\.name) == ["C", "A", "B"])
        #expect(try await services.workspaces.list().map(\.name) == ["C", "A", "B"])

        await model.toggleFavorite(model.workspaces[1])
        #expect(model.workspaces[1].isFavorite)
        #expect(try await services.workspaces.favorites().map(\.name) == ["A"])
    }
}

@MainActor
@Suite("Workspace detail model")
struct WorkspaceDetailModelTests {
    @Test func loadRecordsOpenAndStartsDefaultSession() async throws {
        let services = Services()
        let workspace = try await services.workspaces.create(name: "Dev", kind: .developer)
        let model = WorkspaceDetailModel(
            workspaceID: workspace.id,
            workspaceService: services.workspaces,
            sessionService: services.sessions
        )

        await model.load()
        #expect(model.workspace?.lastOpenedAt == services.clock.now())

        let session = try #require(await model.startSession())
        #expect(session.kind == .developer)
        #expect(model.sessions.map(\.id) == [session.id])
    }

    @Test func favoriteDuplicateAndDelete() async throws {
        let services = Services()
        let workspace = try await services.workspaces.create(name: "W")
        let model = WorkspaceDetailModel(
            workspaceID: workspace.id,
            workspaceService: services.workspaces,
            sessionService: services.sessions
        )
        await model.load()

        await model.toggleFavorite()
        #expect(model.workspace?.isFavorite == true)

        let copy = try #require(await model.duplicate())
        #expect(copy.name == L10n.format(.workspaceCopyName, "W"))

        var draft = WorkspaceDraft(try #require(model.workspace))
        draft.color = .pink
        #expect(await model.update(with: draft))
        #expect(model.workspace?.color == .pink)

        await model.delete()
        #expect(model.isDeleted)
        #expect(try await services.workspaces.list().map(\.id) == [copy.id])
    }
}

@MainActor
@Suite("Command Center model")
struct CommandCenterModelTests {
    @Test func dashboardShowsSessionsWorkspacesAndItems() async throws {
        let services = Services()
        let model = services.commandCenter()
        await model.load()
        #expect(model.featuredWorkspaces.isEmpty)

        let study = try await services.workspaces.create(name: "Study", kind: .study)
        let work = try await services.workspaces.create(name: "Work", kind: .work)
        try await services.workspaces.setFavorite(work.id, true)
        let ended = try await services.sessions.start(in: study.id)
        try await services.sessions.end(ended.id)
        services.clock.advance(by: 1)
        let active = try await services.sessions.start(in: work.id)

        await model.load()
        #expect(model.featuredWorkspaces.map(\.id) == [work.id, study.id])
        #expect(model.activeSessions.map(\.id) == [active.id])
        #expect(model.recentSessions.map(\.id) == [ended.id])
        #expect(model.workspaceName(for: work.id) == "Work")

        model.draft = "https://apple.com"
        await model.captureDraft()
        #expect(model.recentItems.first?.type == .url)
        #expect(model.recentItems.first?.sessionID == active.id)
    }

    @Test func quickActionCreatesWorkspace() async throws {
        let services = Services()
        let model = services.commandCenter()
        let created = try #require(await model.createWorkspace(WorkspaceDraft(name: "Groceries", kind: .shopping)))
        #expect(created.kind == .shopping)
        #expect(model.workspaces.map(\.id) == [created.id])
    }

    @Test func searchUsesQuery() async throws {
        let services = Services()
        let model = services.commandCenter()
        let workspace = try await services.workspaces.create(name: "Physics")
        model.query = "phys"
        await model.search()
        #expect(model.isSearching)
        #expect(model.searchResults.workspaces.map(\.id) == [workspace.id])

        model.query = " "
        await model.search()
        #expect(!model.isSearching)
        #expect(model.searchResults.isEmpty)
    }

    @Test func featuredOrderPutsFavoritesThenRecentlyOpened() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let plain = Workspace(name: "Plain", sortOrder: 0, createdAt: date)
        let opened = Workspace(name: "Opened", sortOrder: 1, createdAt: date, lastOpenedAt: date.addingTimeInterval(5))
        let favorite = Workspace(name: "Fav", isFavorite: true, sortOrder: 2, createdAt: date)
        let featured = CommandCenterModel.featuredForTesting([plain, opened, favorite])
        #expect(featured.map(\.name) == ["Fav", "Opened", "Plain"])
    }
}

@MainActor
@Suite("Lens and Clipboard models")
struct LensAndClipboardModelTests {
    @Test func lensClassifiesAndSaves() async throws {
        let services = Services()
        let model = LensModel(captureService: services.capture, sessionService: services.sessions)

        model.input = "https://example.com/page"
        model.analyze()
        #expect(model.content?.itemType == .url)
        #expect(model.actions.first?.type == .openURL)
        #expect(Set(model.actions.map(\.type)) == [.openURL, .copy, .share, .saveToSession, .createNote, .search])

        await model.save()
        #expect(model.savedItem?.type == .url)
        #expect(try await services.capture.inboxItems().count == 1)

        model.paste(["", "plain words"])
        #expect(model.content == .text("plain words"))
        #expect(model.savedItem == nil)
        #expect(!model.actions.contains { $0.type == .openURL })
    }

    @Test func clipboardPasteSaveAndClear() async throws {
        let services = Services()
        let model = ClipboardModel(clipboardService: services.clipboard, sessionService: services.sessions)
        await model.load()
        #expect(model.history.isEmpty)

        await model.paste(["0770 123 4567", "  "])
        #expect(model.history.map(\.content) == [.text("0770 123 4567")])

        let entry = try #require(model.history.first)
        await model.save(entry)
        #expect(model.history.first?.promotedItemID != nil)
        #expect(try await services.capture.inboxItems().count == 1)

        await model.clear()
        #expect(model.history.isEmpty)
    }
}

@MainActor
@Suite("Session detail model")
struct SessionDetailModelTests {
    @Test func capturesAndEnds() async throws {
        let services = Services()
        let workspace = try await services.workspaces.create(name: "W")
        let session = try await services.sessions.start(in: workspace.id)
        let model = services.sessionDetail(session.id)

        await model.load()
        model.draft = "0770 123 4567"
        await model.captureDraft()
        #expect(model.draft.isEmpty)
        #expect(model.items.count == 1)

        await model.end()
        #expect(model.session?.isEnded == true)
        #expect(model.canCapture == false)
    }
}

@MainActor
@Suite("Smart session detail model")
struct SmartSessionDetailModelTests {
    @Test func renameFavoriteArchiveAndResume() async throws {
        let services = Services()
        let workspace = try await services.workspaces.create(name: "W")
        let session = try await services.sessions.start(in: workspace.id, kind: .shopping)
        let model = services.sessionDetail(session.id)
        await model.load()

        await model.rename(to: "Laptop")
        #expect(model.session?.title == "Laptop")
        await model.toggleFavorite()
        #expect(model.session?.isFavorite == true)
        await model.archive()
        #expect(model.session?.isArchived == true)
        #expect(model.canCapture == false)

        services.clock.advance(by: 30)
        await model.resume()
        #expect(model.session?.isActive == true)
        #expect(model.session?.isArchived == false)
        #expect(model.resumption != nil)
        #expect(model.canCapture)
    }

    @Test func searchSortAndImportance() async throws {
        let services = Services()
        let workspace = try await services.workspaces.create(name: "W")
        let session = try await services.sessions.start(in: workspace.id, kind: .research)
        let model = services.sessionDetail(session.id)
        await model.load()
        for text in ["مَدرسة", "Room 42", "What is entropy?"] {
            services.clock.advance(by: 1)
            model.draft = text
            await model.captureDraft()
        }
        #expect(model.items.count == 3)

        model.query = "مدرسة"
        #expect(model.visibleItems.map(\.content) == [.text("مَدرسة")])
        model.query = "٤٢"
        #expect(model.visibleItems.map(\.content) == [.text("Room 42")])
        model.query = ""

        model.sort = .type
        #expect(model.groups.map(\.kind) == [.question, .text])

        let oldest = try #require(model.items.last)
        await model.toggleImportant(oldest)
        model.sort = .importance
        #expect(model.visibleItems.first?.id == oldest.id)

        // Survives reloading.
        let reloaded = services.sessionDetail(session.id)
        await reloaded.load()
        #expect(reloaded.isImportant(try #require(reloaded.items.first { $0.id == oldest.id })))
    }

    @Test func actionHistoryAndDelete() async throws {
        let services = Services()
        let workspace = try await services.workspaces.create(name: "W")
        let session = try await services.sessions.start(in: workspace.id)
        let model = services.sessionDetail(session.id)
        await model.load()
        model.draft = "0770 123 4567"
        await model.captureDraft()
        let item = try #require(model.items.first)

        await model.record(.call, outcome: .handedOff, detail: "+9647701234567", itemID: item.id)
        #expect(model.recentActions.map(\.actionType) == [.call])

        let reloaded = services.sessionDetail(session.id)
        await reloaded.load()
        #expect(reloaded.actions.map(\.outcome) == [.handedOff])

        await model.delete()
        #expect(model.isDeleted)
        #expect(try await services.sessions.sessions(in: workspace.id).isEmpty)
    }

    @Test func resumeOnLoadReopensTheSession() async throws {
        let services = Services()
        let workspace = try await services.workspaces.create(name: "W")
        let session = try await services.sessions.start(in: workspace.id)
        try await services.sessions.end(session.id)

        let model = services.sessionDetail(session.id, resume: true)
        await model.load()
        #expect(model.session?.isActive == true)
        #expect(model.resumption?.session.id == session.id)
    }

    @Test func workspaceListsFavoritesFirstAndArchivedApart() async throws {
        let services = Services()
        let workspace = try await services.workspaces.create(name: "W")
        let model = WorkspaceDetailModel(workspaceID: workspace.id, workspaceService: services.workspaces, sessionService: services.sessions)
        await model.load()
        let first = try #require(await model.startSession())
        services.clock.advance(by: 1)
        let second = try #require(await model.startSession())
        services.clock.advance(by: 1)
        let third = try #require(await model.startSession())

        await model.toggleFavorite(try #require(model.sessions.first { $0.id == first.id }))
        await model.archive(try #require(model.sessions.first { $0.id == second.id }))
        #expect(model.currentSessions.map(\.id) == [first.id, third.id])
        #expect(model.archivedSessions.map(\.id) == [second.id])

        await model.unarchive(try #require(model.archivedSessions.first))
        #expect(model.archivedSessions.isEmpty)
    }
}

