import Foundation
import Observation
import TLDomain

/// Top-level tabs.
public enum AppTab: String, Hashable, CaseIterable, Sendable {
    case commandCenter
    case workspaces
    case settings
}

/// Every pushable destination. Features push values; the app decides which
/// view renders each route, so features never import each other.
public enum AppRoute: Hashable, Sendable {
    case workspace(WorkspaceID)
    case session(SessionID)
    case lens
    case clipboard
    /// Lens pre-filled with content another tool sent to the Action Engine.
    case lensInput(String)
    /// Tools. The workspace, when given, scopes lists and picks the session to save to.
    case notes(WorkspaceID?)
    case calculator(WorkspaceID?)
    /// Calculator starting from a value the Action Engine found (a price, a number).
    case calculatorInput(Decimal)
    case browser(WorkspaceID?)
    case documents(WorkspaceID?)
    /// Viewers, chosen by document kind.
    case pdf(DocumentID)
    case image(DocumentID)
    case textDocument(DocumentID)
}

extension AppRoute {
    /// The viewer route for a document.
    public static func viewer(for document: Document) -> AppRoute {
        switch document.kind {
        case .pdf, .document: .pdf(document.id)
        case .image: .image(document.id)
        case .text: .textDocument(document.id)
        }
    }

    /// The screen for a workspace tool.
    public static func tool(_ tool: WorkspaceTool, workspaceID: WorkspaceID?) -> AppRoute? {
        switch tool {
        case .lens: .lens
        case .clipboard: .clipboard
        case .notes: .notes(workspaceID)
        case .calculator: .calculator(workspaceID)
        case .browser: .browser(workspaceID)
        case .documents: .documents(workspaceID)
        default: nil
        }
    }
}

/// Owns tab selection and one navigation stack per tab.
@MainActor
@Observable
public final class AppRouter {
    public var selectedTab: AppTab
    public var commandCenterPath: [AppRoute] = []
    public var workspacesPath: [AppRoute] = []
    public var settingsPath: [AppRoute] = []

    public init(selectedTab: AppTab = .commandCenter) {
        self.selectedTab = selectedTab
    }

    /// Pushes a route on the currently selected tab.
    public func push(_ route: AppRoute) {
        append(route, to: selectedTab)
    }

    /// Switches tab and shows `route` on top of that tab's root (deep links, intents).
    public func open(_ route: AppRoute, in tab: AppTab) {
        selectedTab = tab
        setPath([route], for: tab)
    }

    public func popToRoot(_ tab: AppTab? = nil) {
        setPath([], for: tab ?? selectedTab)
    }

    public func path(for tab: AppTab) -> [AppRoute] {
        switch tab {
        case .commandCenter: commandCenterPath
        case .workspaces: workspacesPath
        case .settings: settingsPath
        }
    }

    private func append(_ route: AppRoute, to tab: AppTab) {
        setPath(path(for: tab) + [route], for: tab)
    }

    private func setPath(_ path: [AppRoute], for tab: AppTab) {
        switch tab {
        case .commandCenter: commandCenterPath = path
        case .workspaces: workspacesPath = path
        case .settings: settingsPath = path
        }
    }
}
