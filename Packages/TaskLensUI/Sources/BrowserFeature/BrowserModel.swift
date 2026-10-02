import Foundation
import Observation
import TLCoreServices
import TLDomain
import TLLocalization

/// One browser tab. Page state is reported by the web view.
public struct BrowserTab: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var url: URL?
    public var title: String
    public var canGoBack = false
    public var canGoForward = false
    public var isLoading = false
    public var progress: Double = 0

    public init(id: UUID = UUID(), url: URL? = nil, title: String = "") {
        self.id = id
        self.url = url
        self.title = title
    }
}

/// Navigation state reported by a tab's web view.
public struct BrowserPageState: Sendable, Equatable {
    public var url: URL?
    public var title: String?
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isLoading: Bool
    public var progress: Double

    public init(url: URL?, title: String?, canGoBack: Bool, canGoForward: Bool, isLoading: Bool, progress: Double) {
        self.url = url
        self.title = title
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.progress = progress
    }
}

/// Tabs and address bar. The web views themselves live in the view layer,
/// so this model is fully testable without WebKit.
@MainActor
@Observable
public final class BrowserModel: ContextProducing {
    public static let maximumTabs = 12

    public var workspaceID: WorkspaceID?
    public private(set) var tabs: [BrowserTab]
    public private(set) var selectedTabID: UUID
    public var addressText = ""
    public private(set) var savedURL: URL?
    public var errorMessage: String?

    private let toolCapture: ToolCaptureService
    /// Remembers the open page in the active session, for Resume.
    public var stateRecorder: ToolStateRecorder?
    @ObservationIgnored private var recordedURL: URL?

    public init(workspaceID: WorkspaceID? = nil, toolCapture: ToolCaptureService) {
        let tab = BrowserTab()
        self.workspaceID = workspaceID
        self.tabs = [tab]
        self.selectedTabID = tab.id
        self.toolCapture = toolCapture
    }

    public var selectedTab: BrowserTab {
        tabs.first(where: { $0.id == selectedTabID }) ?? tabs[0]
    }

    // MARK: Tabs

    @discardableResult
    public func newTab(url: URL? = nil) -> BrowserTab? {
        guard tabs.count < Self.maximumTabs else { return nil }
        let tab = BrowserTab(url: url)
        tabs.append(tab)
        select(tab.id)
        return tab
    }

    public func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        addressText = selectedTab.url?.absoluteString ?? ""
        savedURL = nil
    }

    /// Closes a tab. Closing the last tab leaves one empty tab.
    public func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            tabs = [BrowserTab()]
        }
        if selectedTabID == id || !tabs.contains(where: { $0.id == selectedTabID }) {
            select(tabs[min(index, tabs.count - 1)].id)
        }
    }

    // MARK: Navigation

    /// Validates the address field. Returns the URL the selected tab should load.
    public func submitAddress() -> URL? {
        guard let url = BrowserAddress.url(from: addressText) else {
            errorMessage = L10n.string(.errorValidationInvalidURL)
            return nil
        }
        update(selectedTabID) { $0.url = url; $0.isLoading = true }
        addressText = url.absoluteString
        savedURL = nil
        return url
    }

    /// Applies what the tab's web view reports.
    public func apply(_ state: BrowserPageState, to id: UUID) {
        update(id) { tab in
            if let url = state.url { tab.url = url }
            if let title = state.title { tab.title = title }
            tab.canGoBack = state.canGoBack
            tab.canGoForward = state.canGoForward
            tab.isLoading = state.isLoading
            tab.progress = state.progress
        }
        if id == selectedTabID, let url = state.url, url.absoluteString != addressText {
            addressText = url.absoluteString
        }
        if id == selectedTabID, !state.isLoading, let url = state.url, url != recordedURL, let stateRecorder {
            recordedURL = url
            let workspaceID = workspaceID
            Task { await stateRecorder.record(.browser, in: workspaceID, url: url) }
        }
    }

    private func update(_ id: UUID, _ change: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }

    // MARK: Context

    public var toolOutput: ToolOutput? {
        guard let url = selectedTab.url else { return nil }
        return BrowserAddress.output(for: url, title: selectedTab.title)
    }

    public func saveCurrentURL() async {
        guard let output = toolOutput, case .url(let url) = output.content else { return }
        do {
            try await toolCapture.save(output, preferring: workspaceID)
            savedURL = url
        } catch {
            errorMessage = L10n.message(for: error)
        }
    }

    public var isCurrentURLSaved: Bool {
        savedURL != nil && savedURL == selectedTab.url
    }
}
