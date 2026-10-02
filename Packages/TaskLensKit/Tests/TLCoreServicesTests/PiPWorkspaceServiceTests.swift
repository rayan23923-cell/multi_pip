import Foundation
import Testing
import TLCoreServices
import TLData
import TLDomain
import TLFoundation

private let start = Date(timeIntervalSinceReferenceDate: 1_000)

private func noteCard(_ id: NoteID = NoteID(), body: String = "Body") -> PiPCard {
    PiPCard(kind: .note, title: "Title", body: body, origin: PiPCard.Origin(noteID: id), createdAt: start)
}

@Suite("Picture in Picture cards")
struct PiPCardBuilderTests {
    @Test func noteOutputSplitsTitleAndBody() throws {
        let note = Note(title: "Plan", body: "Buy milk\n\nCall Sam", createdAt: start)
        let card = try #require(PiPCardBuilder.card(from: NoteService.output(for: note), at: start))
        #expect(card.kind == .note)
        #expect(card.title == "Plan")
        #expect(card.body == "Buy milk\n\nCall Sam")
        #expect(card.origin.noteID == note.id)
    }

    @Test func untitledNoteKeepsItsBody() throws {
        let note = Note(body: "Only body", createdAt: start)
        let card = try #require(PiPCardBuilder.card(from: NoteService.output(for: note), at: start))
        #expect(card.title.isEmpty)
        #expect(card.body == "Only body")
    }

    @Test func calculationShowsExpressionAndResult() throws {
        let output = CalculatorService.output(for: 375, expression: "125×3")
        let card = try #require(PiPCardBuilder.card(from: output, at: start))
        #expect(card.kind == .calculation)
        #expect(card.title == "125×3")
        #expect(card.body == "= 375")
    }

    @Test func documentPageKeepsDocumentAndPage() throws {
        let document = Document(
            title: "Paper",
            file: FileReference(relativePath: "a.pdf", contentType: "com.adobe.pdf", kind: .pdf),
            createdAt: start
        )
        let card = try #require(PiPCardBuilder.card(from: DocumentService.textOutput("Abstract text", from: document, page: 2), at: start))
        #expect(card.kind == .document)
        #expect(card.title == "Paper")
        #expect(card.body == "Abstract text")
        #expect(card.origin.documentID == document.id)
        #expect(card.origin.page == 2)

        let whole = try #require(PiPCardBuilder.card(from: DocumentService.output(for: document), at: start))
        #expect(whole.kind == .document && whole.body.isEmpty && whole.origin.documentID == document.id)
    }

    @Test func linksAndSessionItemsBecomeContextCards() throws {
        let url = try #require(URL(string: "https://swift.org/docs"))
        let link = try #require(PiPCardBuilder.card(from: ToolOutput(tool: .browser, source: .browser, content: .url(url)), at: start))
        #expect(link.kind == .context && link.title == "swift.org" && link.origin.url == url)

        let item = ContextItem(sessionID: SessionID(), source: .manualEntry, content: .text("Gate 12"), createdAt: start)
        let card = try #require(PiPCardBuilder.card(from: item, at: start))
        #expect(card.kind == .context && card.body == "Gate 12")
        #expect(card.origin.itemID == item.id && card.origin.sessionID == item.sessionID)
    }

    @Test func emptyContentGivesNoCardAndLongTextIsCut() {
        #expect(PiPCardBuilder.card(from: ToolOutput(tool: .lens, source: .manualEntry, content: .text("  ")), at: start) == nil)
        let long = String(repeating: "a", count: 5_000)
        let card = PiPCardBuilder.card(from: ToolOutput(tool: .lens, source: .manualEntry, content: .text(long)), at: start)
        #expect(card?.body.count == PiPCard.maximumBodyLength)
    }
}

@Suite("Picture in Picture workspace")
struct PiPWorkspaceServiceTests {
    @Test func keepingShowsTheNewestCardAndUpdatesDuplicates() async throws {
        let env = TestEnvironment()
        let noteID = NoteID()
        let first = try await env.pip.keep(noteCard(noteID, body: "v1"))
        let second = try await env.pip.keep(noteCard())
        #expect(try await env.pip.currentCard()?.id == second.id)

        env.clock.advance(by: 10)
        let updated = try await env.pip.keep(noteCard(noteID, body: "v2"))
        #expect(updated.id == first.id)
        #expect(updated.body == "v2")
        #expect(updated.updatedAt == env.clock.now())
        #expect(try await env.pip.cards().map(\.id) == [first.id, second.id])
        #expect(try await env.pip.currentCard()?.id == first.id)
    }

    @Test func keepsAtMostTheLimitDroppingTheOldest() async throws {
        let env = TestEnvironment()
        var kept: [PiPCard] = []
        for _ in 0..<(PiPWorkspaceService.maximumCards + 2) {
            kept.append(try await env.pip.keep(noteCard()))
        }
        let cards = try await env.pip.cards()
        #expect(cards.count == PiPWorkspaceService.maximumCards)
        #expect(cards.map(\.id) == kept.suffix(PiPWorkspaceService.maximumCards).map(\.id))
    }

    @Test func steppingStopsAtTheEnds() async throws {
        let env = TestEnvironment()
        let a = try await env.pip.keep(noteCard())
        let b = try await env.pip.keep(noteCard())
        let c = try await env.pip.keep(noteCard())
        #expect(try await env.pip.step(by: 1)?.id == c.id)
        #expect(try await env.pip.step(by: -1)?.id == b.id)
        #expect(try await env.pip.step(by: -5)?.id == a.id)
        try await env.pip.select(c.id)
        #expect(try await env.pip.currentCard()?.id == c.id)
        #expect(try await TestEnvironment().pip.step(by: 1) == nil)
    }

    @Test func removingTheShownCardShowsItsNeighbour() async throws {
        let env = TestEnvironment()
        let a = try await env.pip.keep(noteCard())
        let b = try await env.pip.keep(noteCard())
        let c = try await env.pip.keep(noteCard())
        try await env.pip.select(b.id)
        try await env.pip.remove(b.id)
        #expect(try await env.pip.currentCard()?.id == c.id)
        try await env.pip.remove(c.id)
        #expect(try await env.pip.currentCard()?.id == a.id)
        try await env.pip.removeAll()
        #expect(try await env.pip.cards().isEmpty)
        #expect(try await env.pip.presentation().currentCardID == nil)
    }

    @Test func startStopAndAppClosedAreRecorded() async throws {
        let env = TestEnvironment()
        #expect(try await env.pip.presentation().isRunning == false)
        let started = try await env.pip.markStarted()
        #expect(started.isRunning && started.startedAt == env.clock.now())

        env.clock.advance(by: 30)
        let stopped = try await env.pip.markStopped(.interrupted)
        #expect(!stopped.isRunning && stopped.stopReason == .interrupted && stopped.stoppedAt == env.clock.now())

        // Running at launch means the app was closed while the window was open.
        try await env.pip.markStarted()
        let reconciled = try await env.pip.reconcileAfterLaunch()
        #expect(!reconciled.isRunning && reconciled.stopReason == .appClosed)
        #expect(try await env.pip.reconcileAfterLaunch().stopReason == .appClosed)
    }

    @Test func cardsAndStateSurviveARelaunch() async throws {
        let location = StoreLocation(rootURL: TemporaryDirectory.make())
        let clock = ManualDateProvider(start)
        let first = try Repositories.fileBacked(at: location, logger: .disabled())
        let service = PiPWorkspaceService(cards: first.pipCards, presentation: first.pipPresentation, clock: clock, logger: .disabled())
        let a = try await service.keep(noteCard(body: "keep me"))
        let b = try await service.keep(PiPCard(kind: .calculation, title: "2+2", body: "= 4", createdAt: start))
        try await service.select(a.id)
        try await service.markStarted()

        let second = try Repositories.fileBacked(at: location, logger: .disabled())
        let relaunched = PiPWorkspaceService(cards: second.pipCards, presentation: second.pipPresentation, clock: clock, logger: .disabled())
        #expect(try await relaunched.cards().map(\.id) == [a.id, b.id])
        #expect(try await relaunched.currentCard()?.body == "keep me")
        #expect(try await relaunched.reconcileAfterLaunch().stopReason == .appClosed)
        let third = try Repositories.fileBacked(at: location, logger: .disabled())
        #expect(try await third.pipPresentation.fetch(id: PiPPresentation.sharedID)?.isRunning == false)
    }
}
