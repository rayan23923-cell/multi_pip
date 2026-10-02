import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization
import UIKit

/// What TaskLens may know about the pasteboard without reading it.
///
/// `changeCount`, `hasStrings` and `hasURLs` do not show the iOS
/// "Allow Paste" prompt and reveal nothing about the content itself.
@MainActor
public protocol PasteboardProbing {
    var changeCount: Int { get }
    var hasContent: Bool { get }
}

@MainActor
public struct SystemPasteboardProbe: PasteboardProbing {
    public init() {}
    public var changeCount: Int { UIPasteboard.general.changeCount }
    public var hasContent: Bool { UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs }
}

/// Smart Clipboard. TaskLens only sees what the user explicitly pastes through
/// the system Paste button; it never reads the pasteboard on its own, and iOS
/// gives apps no way to watch it in the background. Each pasted entry runs
/// through the Context Engine and the rule-based Action Engine.
@MainActor
@Observable
public final class ClipboardModel {
    public private(set) var history: [ClipboardItem] = []
    public private(set) var hasLoaded = false
    public private(set) var captureTarget: Session?
    /// Something was copied since the last paste. Content is still unknown.
    public private(set) var hasNewContent = false
    /// Entry shown in the details sheet.
    public var selectedItemID: ClipboardItemID?
    public var errorMessage: String?

    /// A cache, filled while views render; not observed.
    @ObservationIgnored private var analyses: [ClipboardItemID: ContextAnalysis] = [:]
    private let clipboardService: ClipboardService
    private let sessionService: SessionService
    private let probe: any PasteboardProbing
    private let defaults: UserDefaults

    static let lastPastedChangeCountKey = "clipboard.lastPastedChangeCount"

    public init(
        clipboardService: ClipboardService,
        sessionService: SessionService,
        probe: any PasteboardProbing = SystemPasteboardProbe(),
        defaults: UserDefaults = .standard
    ) {
        self.clipboardService = clipboardService
        self.sessionService = sessionService
        self.probe = probe
        self.defaults = defaults
    }

    public func load() async {
        do {
            history = try await clipboardService.history()
            captureTarget = try await sessionService.activeSessions().first
        } catch {
            errorMessage = L10n.message(for: error)
        }
        let ids = Set(history.map(\.id))
        analyses = analyses.filter { ids.contains($0.key) }
        hasLoaded = true
    }

    /// Category, entities and actions for an entry. Computed once per entry.
    public func analysis(for item: ClipboardItem) -> ContextAnalysis {
        if let cached = analyses[item.id] { return cached }
        let analysis = RuleActionEngine.analyze(item.content)
        analyses[item.id] = analysis
        return analysis
    }

    public var selectedItem: ClipboardItem? {
        history.first { $0.id == selectedItemID }
    }

    /// Called with what the user pasted through the system Paste button.
    public func paste(_ strings: [String]) async {
        let values = strings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        markPasted()
        guard !values.isEmpty else { return }
        var recorded: [ClipboardItem] = []
        do {
            for value in values {
                recorded.append(try await clipboardService.record(ContentClassifier.classify(value),
                                                                  offeredTypes: ["public.utf8-plain-text"]))
            }
        } catch {
            errorMessage = L10n.message(for: error)
        }
        await load()
        if recorded.count == 1 {
            selectedItemID = recorded[0].id
        }
    }

    // MARK: Pasteboard hint

    public func refreshPasteboardHint() {
        let last = defaults.object(forKey: Self.lastPastedChangeCountKey) as? Int
        hasNewContent = probe.hasContent && probe.changeCount != last
    }

    public func dismissPasteboardHint() {
        markPasted()
    }

    private func markPasted() {
        defaults.set(probe.changeCount, forKey: Self.lastPastedChangeCountKey)
        hasNewContent = false
    }

    // MARK: Entries

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
