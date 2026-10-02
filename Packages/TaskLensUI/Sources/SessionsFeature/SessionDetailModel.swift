import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

/// One session as a place to work: everything it holds, searchable and
/// sortable, with its action history and Resume.
@MainActor
@Observable
public final class SessionDetailModel {
    public let sessionID: SessionID
    public private(set) var session: Session?
    public private(set) var workspace: Workspace?
    /// Newest first, as stored.
    public private(set) var items: [ContextItem] = []
    public private(set) var actions: [ActionRecord] = []
    /// Set after Resume: recent context and the last tool position.
    public private(set) var resumption: SessionContentService.Resumption?
    public private(set) var hasLoaded = false
    public private(set) var isSaving = false
    /// Set after the session is deleted so the view can close.
    public private(set) var isDeleted = false
    public var draft = ""
    public var query = ""
    public var sort: SessionSort = .recent
    public var errorMessage: String?

    private let sessionService: SessionService
    private let contentService: SessionContentService
    private let captureService: CaptureService
    private var resumeOnLoad: Bool

    public static let recentActionLimit = 10

    /// `resume` makes the session active again when it loads (Resume).
    public init(
        sessionID: SessionID,
        sessionService: SessionService,
        contentService: SessionContentService,
        captureService: CaptureService,
        resume: Bool = false
    ) {
        self.sessionID = sessionID
        self.sessionService = sessionService
        self.contentService = contentService
        self.captureService = captureService
        self.resumeOnLoad = resume
    }

    public var canCapture: Bool { session.map { !$0.isEnded } ?? false }
    public var kind: SessionKind { session?.kind ?? .general }

    /// Items after search and sort.
    public var visibleItems: [ContextItem] {
        SessionContent.sorted(SessionContent.search(items, for: query), by: sort, sessionKind: kind)
    }

    /// Visible items grouped by kind, for sorting by type.
    public var groups: [(kind: SessionItemKind, items: [ContextItem])] {
        let order = SessionContent.typeOrder(for: kind)
        return Dictionary(grouping: visibleItems, by: SessionContent.kind(of:))
            .map { (kind: $0.key, items: $0.value) }
            .sorted { (order[$0.kind] ?? .max) < (order[$1.kind] ?? .max) }
    }

    public var counts: [SessionItemKind: Int] { SessionContent.counts(items) }
    public var recentActions: [ActionRecord] { Array(actions.prefix(Self.recentActionLimit)) }

    public func isImportant(_ item: ContextItem) -> Bool { SessionContent.isImportant(item) }

    // MARK: Loading

    public func load() async {
        do {
            if resumeOnLoad {
                resumeOnLoad = false
                let resumption = try await contentService.resume(sessionID)
                self.resumption = resumption
            }
            let overview = try await contentService.overview(of: sessionID)
            session = overview.session
            workspace = overview.workspace
            items = overview.items
            actions = overview.actions
        } catch {
            errorMessage = L10n.message(for: error)
        }
        hasLoaded = true
    }

    /// Saves the draft text into this session.
    public func captureDraft() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await captureService.capture(.text(draft), source: .manualEntry, into: sessionID)
            draft = ""
            await load()
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    // MARK: Lifecycle

    /// Resume: active again (even if it ended or was archived), with recent
    /// context and the last TaskLens tool position.
    public func resume() async {
        resumeOnLoad = true
        await load()
    }

    public func pause() async {
        await transition { try await $0.pause(self.sessionID) }
    }

    public func end() async {
        await transition { try await $0.end(self.sessionID) }
    }

    public func rename(to title: String) async {
        await transition { try await $0.rename(self.sessionID, to: title) }
    }

    /// Starts (or with nil, stops) a focus timer; the Live Activity counts it down.
    public func setFocus(minutes: Int?) async {
        await transition { try await $0.setFocus(self.sessionID, minutes: minutes) }
    }

    /// True while a focus timer is running.
    public func isFocusing(at now: Date = Date()) -> Bool {
        guard let end = session?.focusEndsAt else { return false }
        return end > now
    }

    public func toggleFavorite() async {
        let isFavorite = session?.isFavorite ?? false
        await transition { try await $0.setFavorite(self.sessionID, !isFavorite) }
    }

    public func archive() async {
        resumption = nil
        await transition { try await $0.archive(self.sessionID) }
    }

    public func unarchive() async {
        await transition { try await $0.unarchive(self.sessionID) }
    }

    public func delete() async {
        do {
            try await contentService.delete(sessionID)
            isDeleted = true
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    private func transition(_ change: (SessionService) async throws -> Session) async {
        do {
            session = try await change(sessionService)
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    // MARK: Items and actions

    public func toggleImportant(_ item: ContextItem) async {
        do {
            let updated = try await contentService.setImportant(item.id, !isImportant(item))
            if let index = items.firstIndex(where: { $0.id == updated.id }) { items[index] = updated }
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    /// Remembers an action the user ran on an item of this session.
    public func record(_ type: ActionType, outcome: ActionRecord.Outcome, detail: String?, itemID: ContextItemID?) async {
        do {
            let record = try await contentService.record(type, outcome: outcome, detail: detail, itemID: itemID, in: sessionID)
            actions.insert(record, at: 0)
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }
}
