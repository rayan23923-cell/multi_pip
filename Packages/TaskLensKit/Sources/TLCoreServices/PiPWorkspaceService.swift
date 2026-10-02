import Foundation
import TLDomain
import TLFoundation

/// The cards kept for Picture in Picture and its state across launches.
///
/// This is TaskLens's own data only. Picture in Picture itself is run by
/// AVKit in the app; this service never claims a window is showing.
public struct PiPWorkspaceService: Sendable {
    /// Cards kept at most; the oldest is dropped first.
    public static let maximumCards = 12

    private let cardStore: any Repository<PiPCard>
    private let presentationStore: any Repository<PiPPresentation>
    private let clock: any DateProviding
    private let logger: TLLogger

    public init(
        cards: any Repository<PiPCard>,
        presentation: any Repository<PiPPresentation>,
        clock: any DateProviding = SystemDateProvider(),
        logger: TLLogger = TLLogger(category: "pip")
    ) {
        self.cardStore = cards
        self.presentationStore = presentation
        self.clock = clock
        self.logger = logger
    }

    // MARK: Cards

    /// Cards in display order.
    public func cards() async throws -> [PiPCard] {
        try await cardStore.fetchAll().sorted { lhs, rhs in
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.description < rhs.id.description
        }
    }

    /// The card Picture in Picture shows: the selected one, or the first.
    public func currentCard() async throws -> PiPCard? {
        let cards = try await cards()
        let presentation = try await presentation()
        return cards.first { $0.id == presentation.currentCardID } ?? cards.first
    }

    /// Adds a card and shows it. The same note, page or item is updated in
    /// place rather than added twice.
    @discardableResult
    public func keep(_ card: PiPCard) async throws -> PiPCard {
        let now = clock.now()
        var cards = try await cards()
        var kept: PiPCard
        if let index = cards.firstIndex(where: { $0.origin.matches(card.origin) }) {
            kept = cards[index]
            kept.kind = card.kind
            kept.title = card.title
            kept.body = card.body
            kept.detail = card.detail
            kept.origin = card.origin
            kept.workspaceID = card.workspaceID ?? kept.workspaceID
            kept.updatedAt = now
            cards[index] = kept
        } else {
            kept = card
            kept.position = (cards.last?.position ?? -1) + 1
            cards.append(kept)
        }
        let overflow = cards.count - Self.maximumCards
        if overflow > 0 {
            let dropped = cards.filter { $0.id != kept.id }.prefix(overflow).map(\.id)
            try await cardStore.delete(ids: Array(dropped))
        }
        try await cardStore.upsert(kept)
        try await update { $0.currentCardID = kept.id }
        logger.info("Kept \(kept.kind.rawValue) card for Picture in Picture")
        return kept
    }

    public func remove(_ id: PiPCardID) async throws {
        let cards = try await cards()
        try await cardStore.delete(id: id)
        let presentation = try await presentation()
        if presentation.currentCardID == id {
            let index = cards.firstIndex { $0.id == id } ?? 0
            let remaining = cards.filter { $0.id != id }
            let next = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
            try await update { $0.currentCardID = next?.id }
        }
    }

    public func removeAll() async throws {
        try await cardStore.delete(ids: try await cardStore.fetchAll().map(\.id))
        try await update { $0.currentCardID = nil }
    }

    @discardableResult
    public func select(_ id: PiPCardID) async throws -> PiPCard {
        let card = try await cardStore.require(id: id)
        try await update { $0.currentCardID = id }
        return card
    }

    /// The next (`offset` > 0) or previous card, stopping at the ends.
    /// Used by the window's skip buttons.
    @discardableResult
    public func step(by offset: Int) async throws -> PiPCard? {
        let cards = try await cards()
        guard !cards.isEmpty else { return nil }
        let currentID = try await presentation().currentCardID
        let index = cards.firstIndex { $0.id == currentID } ?? 0
        let target = cards[min(max(index + offset, 0), cards.count - 1)]
        try await update { $0.currentCardID = target.id }
        return target
    }

    // MARK: Presentation

    public func presentation() async throws -> PiPPresentation {
        try await presentationStore.fetch(id: PiPPresentation.sharedID) ?? PiPPresentation()
    }

    @discardableResult
    public func markStarted() async throws -> PiPPresentation {
        let now = clock.now()
        return try await update {
            $0.isRunning = true
            $0.startedAt = now
            $0.stoppedAt = nil
            $0.stopReason = nil
        }
    }

    @discardableResult
    public func markStopped(_ reason: PiPPresentation.StopReason) async throws -> PiPPresentation {
        let now = clock.now()
        return try await update {
            $0.isRunning = false
            $0.stoppedAt = now
            $0.stopReason = reason
        }
    }

    /// Call once at launch. Picture in Picture never survives the app being
    /// closed, so a state still marked running means it ended with the app.
    @discardableResult
    public func reconcileAfterLaunch() async throws -> PiPPresentation {
        let presentation = try await presentation()
        guard presentation.isRunning else { return presentation }
        logger.info("Picture in Picture ended when the app was closed")
        return try await update {
            $0.isRunning = false
            $0.stopReason = .appClosed
        }
    }

    @discardableResult
    private func update(_ change: (inout PiPPresentation) -> Void) async throws -> PiPPresentation {
        var presentation = try await presentation()
        change(&presentation)
        try await presentationStore.upsert(presentation)
        return presentation
    }
}

/// Builds Picture in Picture cards from what tools and sessions produce.
public enum PiPCardBuilder {
    /// A card for a tool's current content. Nil when there is nothing to show.
    public static func card(from output: ToolOutput, workspaceID: WorkspaceID? = nil, at date: Date) -> PiPCard? {
        card(content: output.content, tool: output.tool, metadata: output.metadata, origin: PiPCard.Origin(), workspaceID: workspaceID, at: date)
    }

    /// A card for an item saved in a session.
    public static func card(from item: ContextItem, at date: Date) -> PiPCard? {
        let tool = item.metadata[ToolOutput.toolMetadataKey]?.stringValue.map(WorkspaceTool.init(rawValue:))
        let origin = PiPCard.Origin(itemID: item.id, sessionID: item.sessionID)
        return card(content: item.content, tool: tool, metadata: item.metadata, origin: origin, workspaceID: item.workspaceID, at: date)
    }

    static func card(
        content: ContextContent,
        tool: WorkspaceTool?,
        metadata: Metadata,
        origin base: PiPCard.Origin,
        workspaceID: WorkspaceID?,
        at date: Date
    ) -> PiPCard? {
        var origin = base
        if let id = metadata["noteID"]?.stringValue.flatMap(NoteID.init(uuidString:)) { origin.noteID = id }
        if let id = metadata["documentID"]?.stringValue.flatMap(DocumentID.init(uuidString:)) { origin.documentID = id }
        if case .number(let page)? = metadata["page"] { origin.page = max(Int(page) - 1, 0) }
        let title = metadata["title"]?.stringValue ?? ""

        switch content {
        case .file(let file):
            let name = title.isEmpty ? (file.originalFilename ?? "") : title
            return PiPCard(kind: .document, title: name, body: "", origin: origin, workspaceID: workspaceID, createdAt: date)
        case .url(let url):
            origin.url = url
            let name = title.isEmpty ? (url.host() ?? "") : title
            return PiPCard(kind: .context, title: name, body: url.absoluteString, origin: origin, workspaceID: workspaceID, createdAt: date)
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if tool == .notes {
                // Notes are "title\n\nbody" (NoteService.output).
                let parts = trimmed.components(separatedBy: "\n\n")
                guard parts.count > 1 else {
                    return PiPCard(kind: .note, title: "", body: trimmed, origin: origin, workspaceID: workspaceID, createdAt: date)
                }
                let body = parts.dropFirst().joined(separator: "\n\n")
                return PiPCard(kind: .note, title: parts[0], body: body, origin: origin, workspaceID: workspaceID, createdAt: date)
            }
            if tool == .calculator {
                let result = metadata["result"]?.stringValue ?? trimmed
                let expression = metadata["expression"]?.stringValue ?? ""
                return PiPCard(kind: .calculation, title: expression, body: "= \(result)", origin: origin, workspaceID: workspaceID, createdAt: date)
            }
            if tool == .documents {
                return PiPCard(kind: .document, title: title, body: trimmed, origin: origin, workspaceID: workspaceID, createdAt: date)
            }
            return PiPCard(kind: .context, title: title, body: trimmed, origin: origin, workspaceID: workspaceID, createdAt: date)
        }
    }
}
