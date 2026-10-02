import Foundation
import TLDomain
import TLFoundation

/// Platform adapter that reads the pasteboard. The iOS implementation lives in
/// the app target and must only be called in response to a user paste.
public protocol PasteboardReading: Sendable {
    @MainActor
    func readContent() -> (content: ContextContent, offeredTypes: [String])?
}

/// Keeps a bounded history of what the user pasted into TaskLens.
public struct ClipboardService: Sendable {
    public static let defaultHistoryLimit = 50

    private let clipboardItems: any Repository<ClipboardItem>
    private let capture: CaptureService
    private let clock: any DateProviding
    private let historyLimit: Int
    private let logger: TLLogger

    public init(
        clipboardItems: any Repository<ClipboardItem>,
        capture: CaptureService,
        clock: any DateProviding = SystemDateProvider(),
        historyLimit: Int = ClipboardService.defaultHistoryLimit,
        logger: TLLogger = TLLogger(category: "clipboard")
    ) {
        self.clipboardItems = clipboardItems
        self.capture = capture
        self.clock = clock
        self.historyLimit = max(historyLimit, 1)
        self.logger = logger
    }

    /// Newest first.
    public func history() async throws -> [ClipboardItem] {
        try await clipboardItems.fetchAll().sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Records a paste. Pasting the same content as the latest entry refreshes it
    /// instead of adding a duplicate.
    @discardableResult
    public func record(_ content: ContextContent, offeredTypes: [String] = []) async throws -> ClipboardItem {
        let content = try Validation.content(content)
        let now = clock.now()
        let existing = try await history()

        if var latest = existing.first, latest.content == content {
            latest = ClipboardItem(
                id: latest.id,
                content: latest.content,
                offeredTypes: offeredTypes.isEmpty ? latest.offeredTypes : offeredTypes,
                capturedAt: now,
                promotedItemID: latest.promotedItemID
            )
            try await clipboardItems.upsert(latest)
            return latest
        }

        let item = ClipboardItem(content: content, offeredTypes: offeredTypes, capturedAt: now)
        try await clipboardItems.upsert(item)

        let overflow = existing.count + 1 - historyLimit
        if overflow > 0 {
            let expired = existing.suffix(overflow).map(\.id)
            try await clipboardItems.delete(ids: expired)
            logger.debug("Trimmed \(expired.count) clipboard entries")
        }
        return item
    }

    /// Saves a clipboard entry as a context item (into a session or the inbox).
    @discardableResult
    public func promote(_ id: ClipboardItemID, to sessionID: SessionID?) async throws -> ContextItem {
        var entry = try await clipboardItems.require(id: id)
        let item = try await capture.capture(entry.content, source: .clipboard, into: sessionID)
        entry.promotedItemID = item.id
        try await clipboardItems.upsert(entry)
        return item
    }

    public func delete(_ id: ClipboardItemID) async throws {
        try await clipboardItems.delete(id: id)
    }

    public func clear() async throws {
        let ids = try await clipboardItems.fetchAll().map(\.id)
        try await clipboardItems.delete(ids: ids)
        logger.info("Cleared clipboard history (\(ids.count) entries)")
    }
}
