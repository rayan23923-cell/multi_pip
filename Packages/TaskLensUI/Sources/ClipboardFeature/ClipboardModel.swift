import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

/// Clipboard entry point. TaskLens only sees what the user explicitly pastes
/// through the system paste button; it never reads the pasteboard on its own.
@MainActor
@Observable
public final class ClipboardModel {
    public private(set) var history: [ClipboardItem] = []
    public private(set) var hasLoaded = false
    public private(set) var captureTarget: Session?
    public var errorMessage: String?

    private let clipboardService: ClipboardService
    private let sessionService: SessionService

    public init(clipboardService: ClipboardService, sessionService: SessionService) {
        self.clipboardService = clipboardService
        self.sessionService = sessionService
    }

    public func load() async {
        do {
            history = try await clipboardService.history()
            captureTarget = try await sessionService.activeSessions().first
        } catch {
            errorMessage = L10n.message(for: error)
        }
        hasLoaded = true
    }

    public func paste(_ strings: [String]) async {
        let values = strings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !values.isEmpty else { return }
        do {
            for value in values {
                try await clipboardService.record(ContentClassifier.classify(value), offeredTypes: ["public.utf8-plain-text"])
            }
        } catch {
            errorMessage = L10n.message(for: error)
        }
        await load()
    }

    /// Saves an entry into the active session, or the inbox.
    public func save(_ item: ClipboardItem) async {
        do {
            try await clipboardService.promote(item.id, to: captureTarget?.id)
        } catch {
            errorMessage = L10n.message(for: error)
        }
        await load()
    }

    public func delete(_ item: ClipboardItem) async {
        do {
            try await clipboardService.delete(item.id)
        } catch {
            errorMessage = L10n.message(for: error)
        }
        await load()
    }

    public func clear() async {
        do {
            try await clipboardService.clear()
        } catch {
            errorMessage = L10n.message(for: error)
        }
        await load()
    }
}
