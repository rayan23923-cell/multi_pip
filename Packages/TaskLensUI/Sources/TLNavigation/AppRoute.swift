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
